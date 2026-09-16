"""App tier — toàn bộ business logic và là tầng DUY NHẤT được nói chuyện với DB.

Nằm ở private subnet, chỉ nhận traffic từ ALB public (chuỗi security group:
0.0.0.0/0 hoặc prefix list CloudFront -> sg-alb-public -> sg-app). Không có
đường vào từ internet, đường ra chỉ một chiều qua NAT.
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi import FastAPI, Header, Request, Response          # noqa: E402
from fastapi.responses import JSONResponse                      # noqa: E402
from pydantic import BaseModel, Field                           # noqa: E402

from common import db, http, orders                             # noqa: E402
from common.config import config                                # noqa: E402
from common.logging import get_logger, log_event, setup_logging  # noqa: E402
from common.queue import get_queue                              # noqa: E402

setup_logging()
log = get_logger("appapi")

app = FastAPI(title="ABC Sales — App tier", version="1.0.0")


@app.middleware("http")
async def strip_api_prefix(request: Request, call_next):
    """Bóc tiền tố /api trước khi định tuyến.

    Trình duyệt luôn gọi /api/orders. Ở local, Web tier chuyển tiếp xuống đây
    thành /orders. Trên AWS thì CloudFront chuyển thẳng cả đường dẫn /api/orders
    tới ALB — CloudFront không bóc tiền tố được, và origin_path thì chỉ THÊM
    chứ không bớt.

    Bóc ở đây giữ cho hai môi trường nhận cùng một hợp đồng, và không phải sửa
    tiền tố ở từng route.

    /health và /ready KHÔNG đi qua đường này: ALB gọi thẳng, không qua CloudFront.
    """
    path = request.scope.get("path", "")
    if path.startswith("/api/"):
        request.scope["path"] = path[4:]
        raw = request.scope.get("raw_path")
        if raw:
            request.scope["raw_path"] = raw[4:]
    return await call_next(request)


# Chỉ bật CORS khi giao diện được phục vụ từ origin khác. Trên AWS, CloudFront
# phục vụ cả giao diện lẫn /api/* nên cùng origin và khối này không kích hoạt.
if config.ALLOWED_ORIGINS:
    from fastapi.middleware.cors import CORSMiddleware

    app.add_middleware(
        CORSMiddleware,
        allow_origins=config.ALLOWED_ORIGINS,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        allow_headers=["Content-Type", "Idempotency-Key", http.TRACE_HEADER],
        expose_headers=[http.TRACE_HEADER],
        max_age=600,
    )

http.install(app)


class OrderItemIn(BaseModel):
    sku: str
    quantity: int = Field(gt=0)


class OrderIn(BaseModel):
    customer_code: str
    items: list[OrderItemIn]


class OrderUpdateIn(BaseModel):
    version: int = Field(ge=1)
    status: str | None = None


# ---------------------------------------------------------------- health
@app.get("/health")
def health(response: Response):
    """Kiểm tra sâu: có chạm tới database thật.

    KHÔNG dùng cho target group của ALB. Nếu ALB kiểm tra endpoint này thì lúc
    RDS chết 3 phút, mọi instance đều rớt health check, ALB rút sạch target và
    ASG (health_check_type = ELB) terminate rồi tạo máy mới — máy mới cũng
    hỏng y hệt. Ràng buộc #5 yêu cầu ngược lại: tiến trình phải sống, trả 503
    trung thực và tự hồi phục khi DB quay lại.

    Dùng cho: chẩn đoán bằng tay, healthcheck của docker compose ở local, và
    làm nguồn cho alarm. Target group trong deploy/terraform/modules/compute
    trỏ vào /ready.
    """
    ok, detail = db.healthy()
    response.status_code = 200 if ok else 503
    return {"status": "ok" if ok else "unhealthy", "tier": config.TIER,
            "instance": config.INSTANCE_ID, "detail": detail,
            "legacy_mode": config.LEGACY_MODE}


@app.get("/ready")
def ready():
    """Endpoint mà target group của ALB thật sự gọi.

    Cố tình KHÔNG chạm database: câu hỏi ở đây là "tiến trình này còn nhận được
    request không", không phải "hệ thống có khoẻ toàn diện không". Xem lý do
    đầy đủ ở deploy/terraform/modules/compute/README.md.
    """
    return {"status": "ok", "instance": config.INSTANCE_ID}


# ---------------------------------------------------------------- orders
@app.post("/orders", status_code=202)
def create_order(
    payload: OrderIn,
    response: Response,
    idempotency_key: str = Header(alias="Idempotency-Key"),
):
    """Nhận đơn.

    Trả 202 Accepted — CỐ Ý không phải 200/201. Đơn mới chỉ ở trạng thái PENDING;
    client phải poll GET /orders/{id} để biết đã CONFIRMED hay chưa. Đây là
    điểm cốt lõi của ràng buộc #5.

    Gửi lại cùng Idempotency-Key trả về đúng order_id cũ với 200 thay vì 202,
    và không tạo thêm đơn nào (ràng buộc #3).
    """
    try:
        result = orders.accept_order(payload.model_dump(), idempotency_key)
    except orders.OrderError as exc:
        return JSONResponse(status_code=exc.status_code,
                            content={"error": "invalid_request", "message": str(exc)})

    if result.deduplicated:
        response.status_code = 200
    elif config.LEGACY_MODE:
        response.status_code = 201

    return {
        "order_id": result.order_id,
        "status": result.status,
        "deduplicated": result.deduplicated,
        "message": "Đơn đã được tiếp nhận. Poll GET /orders/{id} để biết kết quả."
                   if result.status == "PENDING" else "Đơn đã được ghi nhận.",
    }


@app.get("/orders")
def list_orders(limit: int = 50, status: str | None = None):
    return {"orders": orders.list_orders(limit=limit, status=status)}


@app.get("/orders/{order_id}")
def get_order(order_id: str):
    order = orders.get_order(order_id)
    if order is None:
        return JSONResponse(status_code=404,
                            content={"error": "not_found",
                                     "message": f"không tìm thấy đơn {order_id}"})
    return order


@app.put("/orders/{order_id}")
def update_order(order_id: str, payload: OrderUpdateIn):
    """Cập nhật đơn với optimistic locking.

    409 Conflict khi version client gửi lên không còn là version hiện tại —
    thay đổi của người lưu trước KHÔNG bị ghi đè (ràng buộc #3).
    """
    try:
        return orders.update_order(order_id, payload.version,
                                   payload.model_dump(exclude={"version"}))
    except orders.VersionConflict as exc:
        return JSONResponse(
            status_code=409,
            content={"error": "version_conflict", "message": str(exc),
                     "current_version": exc.current_version,
                     "hint": "Tải lại đơn để lấy version mới rồi gửi lại thay đổi."},
        )
    except orders.OrderError as exc:
        return JSONResponse(status_code=exc.status_code,
                            content={"error": "invalid_request", "message": str(exc)})


@app.get("/orders/{order_id}/trace")
def trace_order(order_id: str):
    """Ràng buộc #8: hành trình của 1 giao dịch qua các tier."""
    return {"order_id": order_id, "events": orders.get_order_trace(order_id)}


# ---------------------------------------------------------------- reports
@app.get("/reports/daily")
def daily_report(cutoff: str | None = None):
    """Ràng buộc #10. Chạy trên read replica, REPEATABLE READ, có mốc chốt.

    Gọi 2 lần cùng `cutoff` phải ra cùng `checksum` — đó là bằng chứng báo cáo
    nhất quán, không thiếu, không đếm trùng.
    """
    at = datetime.fromisoformat(cutoff) if cutoff else datetime.now(timezone.utc)
    if at.tzinfo is None:
        at = at.replace(tzinfo=timezone.utc)
    return orders.daily_report(cutoff=at)


# ---------------------------------------------------------------- ops
@app.get("/ops/customers")
def list_customers():
    with db.connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT code, name, branch, department FROM customers ORDER BY code")
        return {"customers": cur.fetchall()}


@app.get("/ops/products")
def list_products():
    with db.connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT sku, name, unit_price FROM products ORDER BY sku")
        return {"products": cur.fetchall()}


@app.get("/ops/queue")
def queue_depth():
    """Độ sâu hàng đợi + DLQ. Dùng để chứng minh drain sau sự cố DB (test B4)."""
    try:
        return get_queue().depth()
    except Exception as exc:  # noqa: BLE001
        return JSONResponse(status_code=503,
                            content={"error": "queue_unavailable", "message": str(exc)})


@app.get("/ops/info")
def info():
    return {
        "tier": config.TIER, "env": config.ENV, "instance": config.INSTANCE_ID,
        "legacy_mode": config.LEGACY_MODE, "queue_driver": config.QUEUE_DRIVER,
        "accept_store": config.ACCEPT_STORE_DRIVER,
        "db_host": config.DB_HOST, "replica": config.has_replica(),
    }


@app.on_event("startup")
def _startup():
    log_event(log, "service.started", queue_driver=config.QUEUE_DRIVER,
              legacy_mode=config.LEGACY_MODE, db_host=config.DB_HOST)


@app.on_event("shutdown")
def _shutdown():
    db.close_pools()
