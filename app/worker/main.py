"""Worker — tiêu thụ hàng đợi và ghi đơn vào PostgreSQL.

Đây là thành phần chịu trách nhiệm cho ràng buộc #5. Quy tắc bất di bất dịch:

    CHỈ xoá message khỏi hàng đợi SAU KHI transaction đã commit thành công.

Từ đó suy ra toàn bộ hành vi mong muốn:
  * DB chết -> commit fail -> KHÔNG xoá message -> message quay lại sau
    visibility timeout -> đơn vẫn PENDING, không ai được báo "thành công".
  * DB hồi -> worker (vẫn đang chạy, không cần restart) drain hàng đợi ->
    mọi đơn đã nhận đều được ghi -> không mất giao dịch.
  * Message bị giao lại 2 lần -> ON CONFLICT DO NOTHING trên idempotency_key
    -> không tạo đơn trùng.
  * Lỗi vĩnh viễn (sai SKU, sai khách hàng) -> không retry vô hạn, đẩy DLQ sau
    MAX_RECEIVE_COUNT lần, có alarm CloudWatch trên DLQ.

Chạy như một process riêng cùng ASG với App tier (systemd unit riêng).
"""
from __future__ import annotations

import json
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from common import db, orders                                     # noqa: E402
from common.config import config                                  # noqa: E402
from common.logging import (get_correlation_id, get_logger,        # noqa: E402
                            log_event, set_correlation_id, setup_logging)
from common.queue import Message, get_queue                       # noqa: E402

setup_logging()
log = get_logger("worker")

_running = True


def _stop(signum, _frame):
    """Shutdown êm: xử lý nốt batch hiện tại rồi thoát.

    Cần thiết cho ASG scale-in và rolling deploy — không được cắt ngang một
    message đang xử lý dở.
    """
    global _running
    _running = False
    log_event(log, "worker.shutdown_requested", signal=signum)


def handle(msg: Message) -> None:
    """Xử lý một message. Ném exception = không xoá message."""
    body = msg.body
    set_correlation_id(body.get("correlation_id"))
    order_id = body.get("order_id")

    try:
        persisted_id, created = orders.persist_order(body)
    except db.DatabaseUnavailable as exc:
        # Lỗi TẠM THỜI. Trả message về hàng đợi để thử lại; đơn phải sống sót
        # qua sự cố DB.
        #
        # Giãn dần theo số lần đã nhận. Worker KHÔNG quyết được việc vào DLQ —
        # SQS tự đẩy khi receive_count vượt maxReceiveCount. Trả về với delay
        # cố định 5 giây thì 5 lần thử chỉ trải trong 25 giây, nên một sự cố DB
        # dài hơn thế là đơn rơi DLQ dù không có gì sai với nó.
        # Đo thật ngày 2026-09-12: sự cố 90 giây đẩy 1/5 đơn sang DLQ.
        #
        # Giãn 60s, 120s, 180s, 240s cho tổng khoảng 10 phút, phủ được kịch bản
        # 3 phút của yêu cầu.
        delay = min(60 * max(msg.receive_count, 1), 600)
        log_event(log, "worker.db_unavailable", order_id=order_id,
                  receive_count=msg.receive_count, retry_in=delay, error=str(exc))
        get_queue().release(msg, delay_seconds=delay)
        return
    except orders.OrderError as exc:
        # Lỗi VĨNH VIỄN (dữ liệu sai) — retry bao nhiêu lần cũng thế.
        log_event(log, "worker.permanent_failure", order_id=order_id,
                  receive_count=msg.receive_count, error=str(exc))
        if msg.receive_count >= config.MAX_RECEIVE_COUNT:
            get_queue().to_dlq(msg, str(exc))
            _mark_failed(order_id, str(exc))
        else:
            get_queue().release(msg, delay_seconds=10)
        return

    # Commit đã xong -> giờ mới được xoá message.
    get_queue().delete(msg)
    log_event(log, "worker.processed", order_id=persisted_id, created=created,
              receive_count=msg.receive_count)


def _mark_failed(order_id: str | None, reason: str) -> None:
    """Ghi vết một đơn hỏng vĩnh viễn để vận hành truy được (ràng buộc #8)."""
    if not order_id:
        return
    try:
        with db.transaction() as cur:
            cur.execute(
                """INSERT INTO order_events (order_id, event, tier, detail, correlation_id)
                   VALUES (%s, 'FAILED', 'worker', %s, %s)""",
                (order_id, json.dumps({"reason": reason}), get_correlation_id()),
            )
    except db.DatabaseUnavailable:
        log_event(log, "worker.mark_failed_skipped", order_id=order_id)


def run() -> None:
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    queue = get_queue()
    log_event(log, "worker.started", queue_driver=config.QUEUE_DRIVER,
              batch=config.WORKER_BATCH, db_host=config.DB_HOST)

    idle_loops = 0
    while _running:
        try:
            messages = queue.receive(config.WORKER_BATCH, config.WORKER_POLL_SECONDS)
        except Exception as exc:  # noqa: BLE001
            # Hàng đợi không truy cập được. Chờ rồi thử lại — không thoát process,
            # vì thoát nghĩa là cần người vào restart tay (vi phạm #5).
            log_event(log, "worker.receive_failed", error=str(exc))
            time.sleep(config.WORKER_POLL_SECONDS)
            continue

        if not messages:
            idle_loops += 1
            if idle_loops % 60 == 0:
                log_event(log, "worker.idle", loops=idle_loops)
            # Driver pg không có long polling, phải tự ngủ.
            if config.QUEUE_DRIVER != "sqs":
                time.sleep(1)
            continue

        idle_loops = 0
        for msg in messages:
            if not _running:
                break
            try:
                handle(msg)
            except Exception as exc:  # noqa: BLE001
                log.exception("lỗi ngoài dự kiến khi xử lý message")
                try:
                    queue.release(msg, delay_seconds=10)
                except Exception:  # noqa: BLE001
                    log_event(log, "worker.release_failed", error=str(exc))

    db.close_pools()
    log_event(log, "worker.stopped")


if __name__ == "__main__":
    run()
