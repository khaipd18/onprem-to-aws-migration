"""Accept-store — nơi ghi nhận "đã nhận yêu cầu" trước khi đơn được persist.

Giải quyết 2 vấn đề của ràng buộc #3 và #5:

1. Khử trùng lặp SỚM. Client bấm gửi lại 5 lần với cùng `Idempotency-Key`
   thì lần 2..5 bị chặn ngay tại App tier, không tạo thêm message vào hàng đợi.
   (UNIQUE constraint trên orders.idempotency_key vẫn giữ nguyên làm tuyến sau.)

2. Trả lời được câu "đơn của tôi đang ở đâu?" khi RDS chết. Vì bản ghi accept
   nằm ngoài RDS (DynamoDB), GET /orders/{id} vẫn trả PENDING thay vì 404 hay
   500 — client biết đơn CHƯA thành công, đúng yêu cầu "không thông báo thành
   công cho giao dịch chưa được ghi nhận".

Driver:
  pg        — bảng order_accept, dùng cho local/demo.
  dynamodb  — on-demand, PutItem có ConditionExpression, TTL 24h. Dùng trên AWS.
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass

from .config import config
from .logging import get_logger

log = get_logger(__name__)


class DuplicateRequest(Exception):
    """Idempotency-Key đã tồn tại. Mang theo order_id của lần nhận ĐẦU TIÊN."""

    def __init__(self, order_id: str):
        super().__init__(f"duplicate idempotency key -> {order_id}")
        self.order_id = order_id


@dataclass
class AcceptRecord:
    idempotency_key: str
    order_id: str
    correlation_id: str
    payload: dict


class AcceptStore:
    def put_if_absent(self, rec: AcceptRecord) -> None:
        raise NotImplementedError

    def get_by_order_id(self, order_id: str) -> AcceptRecord | None:
        raise NotImplementedError


class PgAcceptStore(AcceptStore):
    def put_if_absent(self, rec: AcceptRecord) -> None:
        from . import db

        with db.transaction(db.QUEUE) as cur:
            cur.execute(
                """
                INSERT INTO order_accept (idempotency_key, order_id, correlation_id, payload)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (idempotency_key) DO NOTHING
                RETURNING order_id
                """,
                (rec.idempotency_key, rec.order_id, rec.correlation_id,
                 json.dumps(rec.payload)),
            )
            row = cur.fetchone()
            if row is None:
                cur.execute(
                    "SELECT order_id FROM order_accept WHERE idempotency_key = %s",
                    (rec.idempotency_key,),
                )
                existing = cur.fetchone()
                raise DuplicateRequest(str(existing["order_id"]))

    def get_by_order_id(self, order_id: str) -> AcceptRecord | None:
        from . import db

        with db.connection(db.QUEUE) as conn, conn.cursor() as cur:
            cur.execute(
                """SELECT idempotency_key, order_id, correlation_id, payload
                     FROM order_accept WHERE order_id = %s""",
                (order_id,),
            )
            row = cur.fetchone()
        if not row:
            return None
        return AcceptRecord(
            idempotency_key=row["idempotency_key"],
            order_id=str(row["order_id"]),
            correlation_id=row["correlation_id"] or "",
            payload=row["payload"],
        )


class DynamoAcceptStore(AcceptStore):
    def __init__(self) -> None:
        import boto3

        self._table = boto3.resource(
            "dynamodb", region_name=config.AWS_REGION
        ).Table(config.DDB_ACCEPT_TABLE)

    def put_if_absent(self, rec: AcceptRecord) -> None:
        from botocore.exceptions import ClientError

        try:
            self._table.put_item(
                Item={
                    "idempotency_key": rec.idempotency_key,
                    "order_id": rec.order_id,
                    "correlation_id": rec.correlation_id,
                    "payload": json.dumps(rec.payload),
                    "created_at": int(time.time()),
                    "expires_at": int(time.time()) + 86400,   # TTL attribute
                },
                ConditionExpression="attribute_not_exists(idempotency_key)",
            )
        except ClientError as exc:
            if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise
            existing = self._table.get_item(
                Key={"idempotency_key": rec.idempotency_key}
            ).get("Item") or {}
            raise DuplicateRequest(str(existing.get("order_id", ""))) from exc

    def get_by_order_id(self, order_id: str) -> AcceptRecord | None:
        # GSI order_id-index được tạo trong Terraform module/messaging.
        resp = self._table.query(
            IndexName="order_id-index",
            KeyConditionExpression="order_id = :oid",
            ExpressionAttributeValues={":oid": order_id},
            Limit=1,
        )
        items = resp.get("Items") or []
        if not items:
            return None
        item = items[0]
        return AcceptRecord(
            idempotency_key=item["idempotency_key"],
            order_id=item["order_id"],
            correlation_id=item.get("correlation_id", ""),
            payload=json.loads(item.get("payload", "{}")),
        )


_store: AcceptStore | None = None


def get_accept_store() -> AcceptStore:
    global _store
    if _store is None:
        _store = (
            DynamoAcceptStore()
            if config.ACCEPT_STORE_DRIVER == "dynamodb"
            else PgAcceptStore()
        )
        log.info("accept store initialised: %s", config.ACCEPT_STORE_DRIVER)
    return _store
