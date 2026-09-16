"""Nghiệp vụ đơn hàng — dùng chung cho App tier, Worker và job báo cáo.

Bản đồ tới các ràng buộc của yêu cầu:

  #3 không tạo đơn trùng      -> accept-store (tuyến 1) + UNIQUE idempotency_key (tuyến 2)
  #3 không âm thầm ghi đè     -> cột version + UPDATE ... WHERE version = $expected
  #3/#5 xác định được trạng thái -> PENDING/CONFIRMED/FAILED + GET /orders/{id}
  #5 không báo thành công khống -> accept_order() trả 202 PENDING, chỉ worker mới CONFIRMED
  #8 truy vết                 -> order_events + correlation_id trên mọi dòng log
  #10 báo cáo nhất quán       -> REPEATABLE READ trên replica + mốc chốt cutoff
"""
from __future__ import annotations

import hashlib
import json
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal

from . import db
from .config import config
from .logging import get_correlation_id, get_logger, log_event
from .queue import get_queue
from .store import AcceptRecord, DuplicateRequest, get_accept_store

log = get_logger(__name__)


class OrderError(Exception):
    """Lỗi nghiệp vụ có thể trả về client (4xx)."""

    def __init__(self, message: str, status_code: int = 400):
        super().__init__(message)
        self.status_code = status_code


class VersionConflict(OrderError):
    """Ràng buộc #3: ai đó đã sửa đơn này trước. KHÔNG ghi đè, trả 409."""

    def __init__(self, order_id: str, current_version: int):
        super().__init__(
            f"order {order_id} đã được cập nhật bởi request khác "
            f"(version hiện tại = {current_version})",
            status_code=409,
        )
        self.current_version = current_version


@dataclass
class AcceptResult:
    order_id: str
    status: str
    deduplicated: bool     # True = đây là lần gửi lại, không tạo đơn mới


# --------------------------------------------------------------------------
# 1. Nhận đơn (App tier)
# --------------------------------------------------------------------------
def accept_order(payload: dict, idempotency_key: str) -> AcceptResult:
    """Nhận yêu cầu tạo đơn và đẩy vào hàng đợi.

    KHÔNG ghi vào bảng orders ở đây, và KHÔNG trả "thành công". Hợp đồng với
    client là 202 Accepted + order_id + status=PENDING. Chỉ khi worker commit
    xong thì đơn mới chuyển CONFIRMED. Đây chính là điều ràng buộc #5 kiểm tra:
    "không được thông báo thành công cho giao dịch chưa được ghi nhận".
    """
    _validate_payload(payload)
    correlation_id = get_correlation_id()
    order_id = str(uuid.uuid4())

    if config.LEGACY_MODE:
        return _accept_order_legacy(order_id, payload, idempotency_key)

    store = get_accept_store()
    try:
        store.put_if_absent(
            AcceptRecord(
                idempotency_key=idempotency_key,
                order_id=order_id,
                correlation_id=correlation_id,
                payload=payload,
            )
        )
    except DuplicateRequest as dup:
        # Lần gửi lại. Trả đúng order_id của lần đầu -> client không tạo đơn thứ 2.
        log_event(log, "order.deduped", order_id=dup.order_id,
                  idempotency_key=idempotency_key)
        return AcceptResult(order_id=dup.order_id, status=get_status(dup.order_id),
                            deduplicated=True)

    get_queue().send(
        {"order_id": order_id, "idempotency_key": idempotency_key, **payload},
        dedup_id=idempotency_key,                       # cửa sổ khử trùng lặp FIFO
        group_id=f"order-{payload['customer_code']}",   # song song hoá theo khách hàng
        correlation_id=correlation_id,
    )
    log_event(log, "order.accepted", order_id=order_id,
              idempotency_key=idempotency_key,
              customer_code=payload["customer_code"])
    return AcceptResult(order_id=order_id, status="PENDING", deduplicated=False)


def _accept_order_legacy(order_id: str, payload: dict,
                         idempotency_key: str) -> AcceptResult:
    """Hành vi của hệ thống ON-PREMISE hiện tại: ghi thẳng DB, đồng bộ.

    Giữ lại có chủ đích để làm mốc so sánh khi demo. Cách này KHÔNG đạt ràng
    buộc #5: DB chết thì request lỗi ngay, đơn biến mất, người dùng phải tự
    thao tác lại — và nếu họ bấm lại nhiều lần, chỉ còn UNIQUE constraint đỡ.
    Kiến trúc trên AWS thay bằng đường accept -> queue -> worker.
    """
    body = {"order_id": order_id, "idempotency_key": idempotency_key, **payload}
    persisted_id, created = persist_order(body)
    return AcceptResult(order_id=persisted_id, status="CONFIRMED",
                        deduplicated=not created)


def _validate_payload(payload: dict) -> None:
    if not payload.get("customer_code"):
        raise OrderError("thiếu customer_code")
    items = payload.get("items") or []
    if not items:
        raise OrderError("đơn hàng phải có ít nhất 1 dòng hàng")
    for item in items:
        if not item.get("sku"):
            raise OrderError("dòng hàng thiếu sku")
        if int(item.get("quantity", 0)) <= 0:
            raise OrderError("quantity phải > 0")


# --------------------------------------------------------------------------
# 2. Ghi đơn vào DB (Worker) — điểm duy nhất tạo ra trạng thái CONFIRMED
# --------------------------------------------------------------------------
def persist_order(body: dict) -> tuple[str, bool]:
    """Ghi đơn vào PostgreSQL trong MỘT transaction.

    Trả (order_id, created). created=False nghĩa là đơn đã tồn tại — message bị
    giao lại lần 2 (SQS at-least-once). Đây là lý do phải ON CONFLICT DO NOTHING:
    giao lại bao nhiêu lần cũng chỉ ra đúng 1 đơn.

    Ném DatabaseUnavailable nếu DB chết -> caller KHÔNG xoá message khỏi hàng đợi
    -> message quay lại sau visibility timeout -> đơn giữ nguyên PENDING.
    """
    order_id = body["order_id"]
    idempotency_key = body["idempotency_key"]
    correlation_id = body.get("correlation_id") or get_correlation_id()

    with db.transaction() as cur:
        cur.execute("SELECT id FROM customers WHERE code = %s",
                    (body["customer_code"],))
        customer = cur.fetchone()
        if customer is None:
            raise OrderError(f"không tìm thấy khách hàng {body['customer_code']}", 422)

        skus = [i["sku"] for i in body["items"]]
        cur.execute("SELECT id, sku, unit_price FROM products WHERE sku = ANY(%s)",
                    (skus,))
        products = {r["sku"]: r for r in cur.fetchall()}
        missing = [s for s in skus if s not in products]
        if missing:
            raise OrderError(f"không tìm thấy sản phẩm: {', '.join(missing)}", 422)

        total = sum(
            Decimal(str(products[i["sku"]]["unit_price"])) * int(i["quantity"])
            for i in body["items"]
        )

        # ON CONFLICT DO NOTHING trên UNIQUE(idempotency_key): tuyến phòng thủ
        # cuối cùng chống đơn trùng, kể cả khi accept-store bị bỏ qua.
        cur.execute(
            """
            INSERT INTO orders (id, order_no, customer_id, status, total_amount,
                                idempotency_key, version, correlation_id,
                                source_system, confirmed_at)
            VALUES (%s, %s, %s, 'CONFIRMED', %s, %s, 1, %s, %s, now())
            ON CONFLICT (idempotency_key) DO NOTHING
            RETURNING id
            """,
            (order_id, _order_no(order_id), customer["id"], total,
             idempotency_key, correlation_id,
             "onprem" if config.LEGACY_MODE else "aws"),
        )
        inserted = cur.fetchone()
        if inserted is None:
            cur.execute("SELECT id FROM orders WHERE idempotency_key = %s",
                        (idempotency_key,))
            existing = cur.fetchone()
            log_event(log, "order.duplicate_delivery",
                      order_id=str(existing["id"]), idempotency_key=idempotency_key)
            return str(existing["id"]), False

        for item in body["items"]:
            product = products[item["sku"]]
            cur.execute(
                """INSERT INTO order_items (order_id, product_id, quantity, unit_price)
                   VALUES (%s, %s, %s, %s)""",
                (order_id, product["id"], int(item["quantity"]),
                 product["unit_price"]),
            )

        _record_event(cur, order_id, "PERSISTED", "worker",
                      {"total_amount": str(total), "items": len(body["items"])},
                      correlation_id)

    log_event(log, "order.confirmed", order_id=order_id, total_amount=str(total))
    return order_id, True


def _order_no(order_id: str) -> str:
    return "SO-" + order_id.replace("-", "")[:12].upper()


def _record_event(cur, order_id: str, event: str, tier: str, detail: dict,
                  correlation_id: str) -> None:
    cur.execute(
        """INSERT INTO order_events (order_id, event, tier, detail, correlation_id)
           VALUES (%s, %s, %s, %s, %s)""",
        (order_id, event, tier, json.dumps(detail, default=str), correlation_id),
    )


# --------------------------------------------------------------------------
# 3. Đọc trạng thái
# --------------------------------------------------------------------------
def get_status(order_id: str) -> str:
    """Trạng thái rút gọn, an toàn khi DB đang chết."""
    try:
        order = get_order(order_id)
    except db.DatabaseUnavailable:
        return "UNKNOWN"
    return order["status"] if order else "PENDING"


def get_order(order_id: str) -> dict | None:
    """Đọc đơn đầy đủ.

    Nếu bảng orders chưa có dòng nào nhưng accept-store đã ghi nhận, trả về
    trạng thái PENDING với persisted=False. Nhờ vậy trong lúc RDS chết, client
    poll vẫn nhận được câu trả lời THẬT ("chưa ghi nhận") thay vì 404 gây hiểu
    nhầm là đơn không tồn tại.
    """
    row = None
    try:
        with db.connection() as conn, conn.cursor() as cur:
            cur.execute(
                """
                SELECT o.id, o.order_no, o.status, o.total_amount, o.version,
                       o.correlation_id, o.source_system, o.created_at,
                       o.updated_at, o.confirmed_at,
                       c.code AS customer_code, c.name AS customer_name
                  FROM orders o JOIN customers c ON c.id = o.customer_id
                 WHERE o.id = %s
                """,
                (order_id,),
            )
            row = cur.fetchone()
            if row is not None:
                cur.execute(
                    """SELECT p.sku, p.name, i.quantity, i.unit_price, i.line_total
                         FROM order_items i JOIN products p ON p.id = i.product_id
                        WHERE i.order_id = %s ORDER BY i.id""",
                    (order_id,),
                )
                row["items"] = cur.fetchall()
                row["persisted"] = True
    except db.DatabaseUnavailable:
        row = None   # rơi xuống accept-store bên dưới

    if row is not None:
        return row

    accepted = get_accept_store().get_by_order_id(order_id)
    if accepted is None:
        return None
    return {
        "id": order_id,
        "order_no": None,
        "status": "PENDING",
        "persisted": False,
        "note": "Đơn đã được tiếp nhận nhưng CHƯA ghi nhận vào database. "
                "Vui lòng poll lại; đây chưa phải là giao dịch thành công.",
        "correlation_id": accepted.correlation_id,
        "items": accepted.payload.get("items", []),
    }


def list_orders(limit: int = 50, status: str | None = None) -> list[dict]:
    sql = """SELECT o.id, o.order_no, o.status, o.total_amount, o.version,
                    o.source_system, o.created_at, c.code AS customer_code
               FROM orders o JOIN customers c ON c.id = o.customer_id"""
    params: list = []
    if status:
        sql += " WHERE o.status = %s"
        params.append(status)
    sql += " ORDER BY o.created_at DESC LIMIT %s"
    params.append(limit)
    with db.connection() as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def get_order_trace(order_id: str) -> list[dict]:
    """Ràng buộc #8: hành trình đầy đủ của 1 giao dịch qua các tier."""
    with db.connection() as conn, conn.cursor() as cur:
        cur.execute(
            """SELECT event, tier, detail, correlation_id, created_at
                 FROM order_events WHERE order_id = %s ORDER BY created_at, id""",
            (order_id,),
        )
        return cur.fetchall()


# --------------------------------------------------------------------------
# 4. Cập nhật đơn — optimistic locking
# --------------------------------------------------------------------------
def update_order(order_id: str, expected_version: int, changes: dict) -> dict:
    """Cập nhật đơn, chỉ khi version đúng như client đang thấy.

    Ràng buộc #3 "không âm thầm ghi đè khi nhiều người cùng cập nhật":
    hai người cùng mở đơn version=3, người A lưu trước -> version thành 4.
    Người B lưu sau vẫn gửi version=3 -> UPDATE khớp 0 dòng -> trả 409 kèm
    version hiện tại, thay đổi của A được giữ nguyên.
    """
    correlation_id = get_correlation_id()
    # Chi nhung truong that su co cot trong bang orders moi duoc phep. Nhan mot
    # truong roi khong ghi xuong DB la am tham lam mat du lieu, dung thu rang
    # buoc #3 cam.
    allowed = {"status"}
    fields = {k: v for k, v in changes.items() if k in allowed and v is not None}
    if not fields:
        raise OrderError("không có trường hợp lệ để cập nhật")
    if "status" in fields and fields["status"] not in (
        "PENDING", "CONFIRMED", "FAILED", "CANCELLED"
    ):
        raise OrderError(f"status không hợp lệ: {fields['status']}")

    with db.transaction() as cur:
        cur.execute(
            """
            UPDATE orders
               SET status     = COALESCE(%s, status),
                   version    = version + 1,
                   updated_at = now()
             WHERE id = %s AND version = %s
            RETURNING id, order_no, status, total_amount, version, updated_at
            """,
            (fields.get("status"), order_id, expected_version),
        )
        updated = cur.fetchone()

        if updated is None:
            cur.execute("SELECT version FROM orders WHERE id = %s", (order_id,))
            current = cur.fetchone()
            if current is None:
                raise OrderError(f"không tìm thấy đơn {order_id}", 404)
            _record_event(cur, order_id, "CONFLICT", "app",
                          {"expected_version": expected_version,
                           "current_version": current["version"],
                           "attempted": fields},
                          correlation_id)
            log_event(log, "order.version_conflict", order_id=order_id,
                      expected_version=expected_version,
                      current_version=current["version"])
            raise VersionConflict(order_id, current["version"])

        _record_event(cur, order_id, "UPDATED", "app", fields, correlation_id)

    log_event(log, "order.updated", order_id=order_id,
              new_version=updated["version"], changes=fields)
    return updated


# --------------------------------------------------------------------------
# 5. Báo cáo — ràng buộc #10
# --------------------------------------------------------------------------
def _wait_for_replica_catchup(conn, cutoff: datetime, timeout: float) -> dict:
    """Chờ read replica replay xong mọi giao dịch commit trước mốc chốt.

    ĐÂY LÀ ĐIỀU KIỆN BẮT BUỘC, không phải tối ưu hoá. Read replica là bất đồng
    bộ: tại thời điểm ta chốt mốc T trên primary, replica có thể còn chậm vài
    giây. Chạy báo cáo ngay lúc đó thì `created_at < T` trên replica trả về ÍT
    đơn hơn thực tế — tức là báo cáo THIẾU đơn, đúng thứ ràng buộc #10 cấm.

    Cách kiểm tra: `pg_last_xact_replay_timestamp()` trên standby cho biết
    timestamp commit của giao dịch cuối cùng đã replay. Khi giá trị này vượt
    qua mốc chốt, mọi thứ commit trước mốc chốt chắc chắn đã có mặt.

    Trên AWS còn có metric CloudWatch `ReplicaLag` để đặt alarm cho việc này.

    Trả về dict mô tả quá trình chờ, để ghi vào báo cáo làm bằng chứng.
    """
    deadline = time.monotonic() + timeout
    waited = 0.0
    info = {"waited_seconds": 0.0, "caught_up": False, "replay_timestamp": None}

    while True:
        with conn.cursor() as cur:
            cur.execute(
                """SELECT pg_is_in_recovery() AS in_recovery,
                          pg_last_xact_replay_timestamp() AS replay_ts,
                          pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn()
                              AS fully_applied"""
            )
            row = cur.fetchone()
        conn.rollback()

        # Không phải standby (đang chạy trên primary) -> không có độ trễ nào.
        if not row["in_recovery"]:
            info.update(caught_up=True, replay_timestamp=None, on_primary=True)
            return info

        replay_ts = row["replay_ts"]
        info["replay_timestamp"] = replay_ts.isoformat() if replay_ts else None

        if replay_ts is not None and replay_ts >= cutoff:
            info["caught_up"] = True
            return info

        # Hệ thống đang không có ghi: replica đã áp dụng hết WAL nhận được và
        # không còn gì để chờ. Coi như đã bắt kịp.
        if row["fully_applied"] and waited >= 1.0:
            info["caught_up"] = True
            info["note"] = "replica đã áp dụng hết WAL nhận được (không có ghi mới)"
            return info

        if time.monotonic() >= deadline:
            info["caught_up"] = False
            info["waited_seconds"] = round(waited, 2)
            return info

        time.sleep(0.25)
        waited += 0.25
        info["waited_seconds"] = round(waited, 2)


def daily_report(cutoff: datetime | None = None, persist_run: bool = True) -> dict:
    """Tổng hợp báo cáo tại một MỐC CHỐT xác định, chạy trên read replica.

    Hai điều kiện để "không thiếu, không đếm trùng":

    1. REPEATABLE READ — mọi câu query trong job nhìn cùng một snapshot. Không
       có REPEATABLE READ thì query đếm số đơn và query tính doanh thu chạy
       cách nhau vài giây sẽ nhìn 2 tập dữ liệu khác nhau.
    2. Mốc chốt tường minh `created_at < cutoff` — đơn tạo sau mốc chốt thuộc
       kỳ báo cáo sau, không lẫn vào kỳ này.

    Chạy trên replica để tải báo cáo không đụng vào OLTP (giữ p95 <= 2s cho
    việc tạo/cập nhật đơn theo ràng buộc #4).
    """
    cutoff = cutoff or datetime.now(timezone.utc)
    correlation_id = get_correlation_id()
    ran_on = "replica" if config.has_replica() else "primary"

    with db.connection(db.REPLICA) as conn:
        conn.rollback()   # đảm bảo chưa có transaction đang mở

        catchup = _wait_for_replica_catchup(conn, cutoff, config.REPLICA_CATCHUP_TIMEOUT)
        if not catchup["caught_up"]:
            # Thà báo lỗi rõ ràng còn hơn xuất một báo cáo thiếu đơn mà không ai
            # biết. Vận hành sẽ thấy alarm ReplicaLag và xử lý.
            raise OrderError(
                f"read replica chưa replay tới mốc chốt sau "
                f"{catchup['waited_seconds']}s (replay tới "
                f"{catchup['replay_timestamp']}, cần >= {cutoff.isoformat()}). "
                f"Không xuất báo cáo để tránh thiếu đơn.",
                status_code=503,
            )

        with conn.cursor() as cur:
            cur.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")

            cur.execute(
                """SELECT count(*) AS order_count,
                          coalesce(sum(total_amount), 0) AS total_amount
                     FROM orders
                    WHERE status = 'CONFIRMED' AND created_at < %s""",
                (cutoff,),
            )
            totals = cur.fetchone()

            cur.execute(
                """SELECT c.branch,
                          count(*) AS order_count,
                          coalesce(sum(o.total_amount), 0) AS total_amount
                     FROM orders o JOIN customers c ON c.id = o.customer_id
                    WHERE o.status = 'CONFIRMED' AND o.created_at < %s
                    GROUP BY c.branch ORDER BY c.branch""",
                (cutoff,),
            )
            by_branch = cur.fetchall()

            cur.execute(
                """SELECT p.sku, p.name,
                          sum(i.quantity)   AS quantity,
                          sum(i.line_total) AS revenue
                     FROM order_items i
                     JOIN orders o   ON o.id = i.order_id
                     JOIN products p ON p.id = i.product_id
                    WHERE o.status = 'CONFIRMED' AND o.created_at < %s
                    GROUP BY p.sku, p.name
                    ORDER BY revenue DESC LIMIT 10""",
                (cutoff,),
            )
            top_products = cur.fetchall()

            # Bằng chứng cho "nhất quán": cùng cutoff -> cùng checksum, bất kể
            # chạy lúc nào, chạy song song bao nhiêu job.
            cur.execute(
                """SELECT coalesce(md5(string_agg(id::text, ',' ORDER BY id)), '')
                          AS fingerprint
                     FROM orders
                    WHERE status = 'CONFIRMED' AND created_at < %s""",
                (cutoff,),
            )
            fingerprint = cur.fetchone()["fingerprint"]
        conn.rollback()   # kết thúc snapshot, không giữ transaction dài trên replica

    checksum = hashlib.sha256(
        f"{totals['order_count']}|{totals['total_amount']}|{fingerprint}".encode()
    ).hexdigest()[:32]

    result = {
        "report_name": "daily_sales",
        "cutoff_at": cutoff.isoformat(),
        "ran_on": ran_on,
        "replica_catchup": catchup,
        "order_count": int(totals["order_count"]),
        "total_amount": str(totals["total_amount"]),
        "by_branch": by_branch,
        "top_products": top_products,
        "checksum": checksum,
    }

    if persist_run:
        try:
            with db.transaction() as cur:
                cur.execute(
                    """INSERT INTO report_runs (report_name, cutoff_at, finished_at,
                                                ran_on, order_count, total_amount,
                                                checksum, correlation_id)
                       VALUES (%s, %s, now(), %s, %s, %s, %s, %s) RETURNING id""",
                    ("daily_sales", cutoff, ran_on, result["order_count"],
                     totals["total_amount"], checksum, correlation_id),
                )
                result["run_id"] = cur.fetchone()["id"]
        except db.DatabaseUnavailable:
            result["run_id"] = None

    log_event(log, "report.completed", cutoff=cutoff.isoformat(),
              order_count=result["order_count"], checksum=checksum, ran_on=ran_on)
    return result
