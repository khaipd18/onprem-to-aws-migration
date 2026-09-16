"""Structured logging + correlation ID.

Ràng buộc #8 yêu cầu "truy vết được một giao dịch qua các thành phần". Cách rẻ
nhất, không cần X-Ray: ALB tự sinh header `X-Amzn-Trace-Id`; mọi tier đọc nó,
gắn vào MỌI dòng log dưới field `correlation_id`, và truyền tiếp xuống tier sau
(qua HTTP header và qua message attribute của SQS).

Khi cần điều tra, CloudWatch Logs Insights:

    fields @timestamp, tier, level, event, order_id, @message
    | filter correlation_id = "Root=1-abc..."
    | sort @timestamp asc

Log ra stdout dạng JSON một dòng; CloudWatch Agent gom stdout -> log group.
"""
import contextvars
import json
import logging
import sys
import time
import uuid

from .config import config

_correlation_id: contextvars.ContextVar[str] = contextvars.ContextVar(
    "correlation_id", default="-"
)


def new_correlation_id() -> str:
    """Sinh ID theo đúng format ALB để log on-prem và log AWS trộn được với nhau."""
    return f"Root=1-{int(time.time()):08x}-{uuid.uuid4().hex[:24]}"


def set_correlation_id(value: str | None) -> str:
    cid = (value or "").strip() or new_correlation_id()
    _correlation_id.set(cid)
    return cid


def get_correlation_id() -> str:
    return _correlation_id.get()


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created))
            + f".{int(record.msecs):03d}Z",
            "level": record.levelname,
            "tier": config.TIER,
            "instance": config.INSTANCE_ID,
            "correlation_id": get_correlation_id(),
            "logger": record.name,
            "msg": record.getMessage(),
        }
        # Field phụ truyền qua logger.info("...", extra={"extra": {...}})
        extra = getattr(record, "extra", None)
        if isinstance(extra, dict):
            payload.update(extra)
        if record.exc_info:
            payload["error"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False, default=str)


def setup_logging(level: str = "INFO") -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level)
    # uvicorn access log dư thừa: ta tự log request ở middleware với đủ field hơn
    logging.getLogger("uvicorn.access").disabled = True
    logging.getLogger("uvicorn.error").handlers[:] = [handler]


def get_logger(name: str) -> logging.Logger:
    return logging.getLogger(name)


def log_event(logger: logging.Logger, event: str, **fields) -> None:
    """Log một sự kiện nghiệp vụ. `event` là tên chuẩn hoá để filter trong Insights."""
    logger.info(event, extra={"extra": {"event": event, **fields}})
