"""Hàng đợi bền giữa App tier và Worker.

Vì sao phải có hàng đợi (ràng buộc #5):
  API nhận đơn -> đẩy vào hàng đợi -> trả 202 Accepted (KHÔNG phải 200 "thành
  công"). Worker mới là bên commit vào DB. Khi DB chết 3 phút, worker không
  commit được, message quay lại hàng đợi sau visibility timeout, đơn giữ nguyên
  PENDING. DB hồi -> worker drain hàng đợi -> không mất, không trùng, không cần
  ai restart tay.

Driver:
  pg   — bảng order_queue, mô phỏng FIFO: dedup theo dedup_id (UNIQUE),
         visibility timeout, receive_count -> DLQ. Dùng cho local/demo.
  sqs  — SQS FIFO thật. MessageGroupId = order-{customer_id} để song song hoá
         theo khách hàng; MessageDeduplicationId = idempotency key.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field

from .config import config
from .logging import get_logger

log = get_logger(__name__)


@dataclass
class Message:
    receipt: str                 # handle để xoá / trả lại message
    body: dict
    dedup_id: str
    group_id: str
    receive_count: int = 1
    attributes: dict = field(default_factory=dict)


class Queue:
    def send(self, body: dict, *, dedup_id: str, group_id: str,
             correlation_id: str = "") -> None:
        raise NotImplementedError

    def receive(self, max_messages: int, wait_seconds: int) -> list[Message]:
        raise NotImplementedError

    def delete(self, msg: Message) -> None:
        raise NotImplementedError

    def release(self, msg: Message, *, delay_seconds: int = 0) -> None:
        """Trả message về hàng đợi ngay (không đợi hết visibility timeout)."""
        raise NotImplementedError

    def to_dlq(self, msg: Message, error: str) -> None:
        raise NotImplementedError

    def depth(self) -> dict:
        raise NotImplementedError


class PgQueue(Queue):
    def send(self, body, *, dedup_id, group_id, correlation_id=""):
        from . import db

        payload = dict(body, correlation_id=correlation_id)
        with db.transaction(db.QUEUE) as cur:
            # ON CONFLICT DO NOTHING = cửa sổ khử trùng lặp của FIFO.
            cur.execute(
                """
                INSERT INTO order_queue (dedup_id, group_id, body)
                VALUES (%s, %s, %s)
                ON CONFLICT (dedup_id) DO NOTHING
                """,
                (dedup_id, group_id, json.dumps(payload)),
            )

    def receive(self, max_messages, wait_seconds):
        from . import db

        # FOR UPDATE SKIP LOCKED cho phép nhiều worker cùng poll mà không giẫm nhau.
        with db.transaction(db.QUEUE) as cur:
            cur.execute(
                """
                WITH picked AS (
                    SELECT msg_id FROM order_queue
                     WHERE visible_at <= now()
                     ORDER BY msg_id
                     LIMIT %s
                     FOR UPDATE SKIP LOCKED
                )
                UPDATE order_queue q
                   SET receive_count = q.receive_count + 1,
                       visible_at    = now() + (%s || ' seconds')::interval
                  FROM picked
                 WHERE q.msg_id = picked.msg_id
                RETURNING q.msg_id, q.dedup_id, q.group_id, q.body, q.receive_count
                """,
                (max_messages, config.VISIBILITY_TIMEOUT),
            )
            rows = cur.fetchall()
        return [
            Message(
                receipt=str(r["msg_id"]),
                body=r["body"],
                dedup_id=r["dedup_id"],
                group_id=r["group_id"],
                receive_count=r["receive_count"],
            )
            for r in rows
        ]

    def delete(self, msg):
        from . import db

        with db.transaction(db.QUEUE) as cur:
            cur.execute("DELETE FROM order_queue WHERE msg_id = %s", (int(msg.receipt),))

    def release(self, msg, *, delay_seconds=0):
        from . import db

        with db.transaction(db.QUEUE) as cur:
            cur.execute(
                "UPDATE order_queue SET visible_at = now() + (%s || ' seconds')::interval "
                "WHERE msg_id = %s",
                (delay_seconds, int(msg.receipt)),
            )

    def to_dlq(self, msg, error):
        from . import db

        with db.transaction(db.QUEUE) as cur:
            cur.execute(
                """
                INSERT INTO order_queue_dlq (msg_id, dedup_id, group_id, body,
                                             receive_count, last_error)
                VALUES (%s, %s, %s, %s, %s, %s)
                ON CONFLICT (msg_id) DO NOTHING
                """,
                (int(msg.receipt), msg.dedup_id, msg.group_id,
                 json.dumps(msg.body), msg.receive_count, error[:2000]),
            )
            cur.execute("DELETE FROM order_queue WHERE msg_id = %s", (int(msg.receipt),))

    def depth(self):
        from . import db

        with db.connection(db.QUEUE) as conn, conn.cursor() as cur:
            cur.execute(
                """SELECT (SELECT count(*) FROM order_queue)     AS visible,
                          (SELECT count(*) FROM order_queue_dlq) AS dlq,
                          (SELECT coalesce(extract(epoch FROM now() - min(created_at)), 0)
                             FROM order_queue)                   AS oldest_age_seconds"""
            )
            return dict(cur.fetchone())


class SqsQueue(Queue):
    def __init__(self) -> None:
        import boto3

        self._sqs = boto3.client("sqs", region_name=config.AWS_REGION)

    def send(self, body, *, dedup_id, group_id, correlation_id=""):
        self._sqs.send_message(
            QueueUrl=config.SQS_QUEUE_URL,
            MessageBody=json.dumps(dict(body, correlation_id=correlation_id)),
            MessageGroupId=group_id,
            MessageDeduplicationId=dedup_id,
            MessageAttributes={
                "correlation_id": {"DataType": "String",
                                   "StringValue": correlation_id or "-"}
            },
        )

    def receive(self, max_messages, wait_seconds):
        resp = self._sqs.receive_message(
            QueueUrl=config.SQS_QUEUE_URL,
            MaxNumberOfMessages=min(max_messages, 10),
            WaitTimeSeconds=min(wait_seconds, 20),      # long polling
            VisibilityTimeout=config.VISIBILITY_TIMEOUT,
            MessageSystemAttributeNames=["ApproximateReceiveCount", "MessageGroupId",
                                         "MessageDeduplicationId"],
            MessageAttributeNames=["All"],
        )
        out = []
        for m in resp.get("Messages", []):
            attrs = m.get("Attributes", {})
            out.append(
                Message(
                    receipt=m["ReceiptHandle"],
                    body=json.loads(m["Body"]),
                    dedup_id=attrs.get("MessageDeduplicationId", ""),
                    group_id=attrs.get("MessageGroupId", ""),
                    receive_count=int(attrs.get("ApproximateReceiveCount", 1)),
                )
            )
        return out

    def delete(self, msg):
        self._sqs.delete_message(QueueUrl=config.SQS_QUEUE_URL,
                                 ReceiptHandle=msg.receipt)

    def release(self, msg, *, delay_seconds=0):
        self._sqs.change_message_visibility(
            QueueUrl=config.SQS_QUEUE_URL,
            ReceiptHandle=msg.receipt,
            VisibilityTimeout=delay_seconds,
        )

    def to_dlq(self, msg, error):
        # Với SQS thật, redrive policy (maxReceiveCount=5) tự đẩy sang DLQ.
        # Không xoá message ở đây — để SQS đếm nốt và tự chuyển.
        log.warning("message sẽ được SQS tự redrive sang DLQ: %s", error[:200])

    def depth(self):
        attrs = self._sqs.get_queue_attributes(
            QueueUrl=config.SQS_QUEUE_URL,
            AttributeNames=["ApproximateNumberOfMessages"],
        )["Attributes"]
        out = {"visible": int(attrs.get("ApproximateNumberOfMessages", 0)), "dlq": 0}
        if config.SQS_DLQ_URL:
            dlq = self._sqs.get_queue_attributes(
                QueueUrl=config.SQS_DLQ_URL,
                AttributeNames=["ApproximateNumberOfMessages"],
            )["Attributes"]
            out["dlq"] = int(dlq.get("ApproximateNumberOfMessages", 0))
        return out


_queue: Queue | None = None


def get_queue() -> Queue:
    global _queue
    if _queue is None:
        _queue = SqsQueue() if config.QUEUE_DRIVER == "sqs" else PgQueue()
        log.info("queue driver initialised: %s", config.QUEUE_DRIVER)
    return _queue
