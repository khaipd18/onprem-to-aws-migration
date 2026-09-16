"""Middleware dùng chung cho cả Web tier và App tier."""
from __future__ import annotations

import time

from fastapi import Request
from fastapi.responses import JSONResponse

from . import db
from .logging import get_logger, log_event, set_correlation_id

log = get_logger("http")

# ALB tự sinh header này. Web tier đọc rồi truyền tiếp xuống App tier để cả
# chuỗi request dùng CHUNG một correlation id (ràng buộc #8).
TRACE_HEADER = "X-Amzn-Trace-Id"


def install(app) -> None:
    @app.middleware("http")
    async def correlate_and_log(request: Request, call_next):
        cid = set_correlation_id(request.headers.get(TRACE_HEADER))
        started = time.perf_counter()
        try:
            response = await call_next(request)
        except db.DatabaseUnavailable as exc:
            # Không bao giờ để lỗi DB biến thành 200. Trả 503 để ALB/health check
            # và client đều biết giao dịch CHƯA được ghi nhận (ràng buộc #5).
            log_event(log, "http.database_unavailable", path=request.url.path,
                      error=str(exc))
            response = JSONResponse(
                status_code=503,
                content={"error": "database_unavailable",
                         "message": "Không xác nhận được giao dịch lúc này. "
                                    "Vui lòng thử lại; đơn của bạn chưa được ghi nhận."},
            )
        except Exception as exc:  # noqa: BLE001
            log.exception("unhandled error on %s", request.url.path)
            response = JSONResponse(
                status_code=500,
                content={"error": "internal_error", "message": str(exc)},
            )

        elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
        response.headers[TRACE_HEADER] = cid
        # Không log health check để khỏi ngập log group (ALB gọi mỗi 10 giây).
        if request.url.path not in ("/health", "/ready"):
            log_event(log, "http.request", method=request.method,
                      path=request.url.path, status=response.status_code,
                      duration_ms=elapsed_ms)
        return response
