"""Web tier — chỉ chạy ở môi trường local.

Trên AWS không còn tầng này: giao diện là SPA tĩnh nằm trên S3, CloudFront
phục vụ trang và chuyển /api/* thẳng xuống ALB. Ở local, tiến trình này đóng
đúng vai CloudFront để bộ test kiểm chứng cùng một hợp đồng mà trình duyệt sẽ
thấy trên AWS.

Dù ở đâu thì nguyên tắc vẫn giữ: tầng này KHÔNG kết nối database, mọi thứ đi
qua App tier bằng HTTP.
"""
from __future__ import annotations

import hashlib
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import httpx                                                     # noqa: E402
from fastapi import FastAPI, Request, Response                    # noqa: E402
from fastapi.responses import HTMLResponse, JSONResponse          # noqa: E402
from fastapi.staticfiles import StaticFiles                       # noqa: E402

from common import http as http_mw                                # noqa: E402
from common.config import config                                  # noqa: E402
from common.logging import (get_correlation_id, get_logger,       # noqa: E402
                            log_event, setup_logging)

setup_logging()
log = get_logger("web")

app = FastAPI(title="ABC Sales — Web tier", version="1.0.0")
http_mw.install(app)

_client = httpx.AsyncClient(base_url=config.APP_TIER_URL, timeout=config.HTTP_TIMEOUT)

HERE = os.path.dirname(os.path.abspath(__file__))
UI_PATH = os.path.join(HERE, "ui.html")
STATIC_DIR = os.path.join(HERE, "static")

# Ở local, Web tier đóng đúng vai CloudFront trên AWS: phục vụ vỏ trang và
# /static/*, còn /api/* thì chuyển tiếp xuống App tier. Nhờ vậy bộ test chạy ở
# local kiểm chứng đúng hợp đồng mà trình duyệt sẽ thấy trên AWS.
if os.path.isdir(STATIC_DIR):
    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/health")
async def health(response: Response):
    """Health check cho ALB public.

    Web tier khoẻ nghĩa là gọi được App tier. Nếu App tier chết hết, Web tier
    cũng phải báo unhealthy — tránh việc ALB vẫn gửi traffic vào một tier chỉ
    biết trả 502.
    """
    try:
        upstream = await _client.get("/ready", timeout=3)
        ok = upstream.status_code == 200
    except Exception as exc:  # noqa: BLE001
        ok, upstream_detail = False, str(exc)
    else:
        upstream_detail = f"app tier http {upstream.status_code}"
    response.status_code = 200 if ok else 503
    return {"status": "ok" if ok else "unhealthy", "tier": "web",
            "instance": config.INSTANCE_ID, "upstream": upstream_detail}


@app.get("/ready")
def ready():
    return {"status": "ok", "instance": config.INSTANCE_ID}


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    """Trả vỏ trang.

    Vỏ trang là cùng một chuỗi byte ở mọi request nên đặt ETag cho nó: lần tải
    thứ hai trở đi trình duyệt hỏi bằng If-None-Match và nhận 304 rỗng. Rẻ hơn
    mọi lớp cache đặt ở phía server, và không tốn thêm dịch vụ nào.

    Cache-Control là no-cache chứ không phải no-store: trình duyệt vẫn giữ bản
    sao, chỉ hỏi lại xem còn mới không. Không đặt max-age vì đây là điểm vào
    của ứng dụng — deploy bản mới mà trang còn cache cũ thì người dùng chạy
    mã cũ mà không biết.
    """
    with open(UI_PATH, encoding="utf-8") as fh:
        html = fh.read()

    etag = '"%s"' % hashlib.sha256(html.encode()).hexdigest()[:32]
    headers = {"ETag": etag, "Cache-Control": "no-cache"}

    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers=headers)

    return HTMLResponse(html, headers=headers)


@app.api_route("/api/{path:path}",
               methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy(path: str, request: Request):
    """Chuyển tiếp xuống App tier, mang theo correlation id.

    Web tier tự sinh Idempotency-Key nếu client không gửi, để mọi đơn tạo từ UI
    đều được bảo vệ chống trùng — người dùng bấm 2 lần trên nút "Tạo đơn" chỉ ra
    đúng 1 đơn (ràng buộc #3).
    """
    raw = await request.body()

    headers = {
        http_mw.TRACE_HEADER: get_correlation_id(),
        "Content-Type": request.headers.get("content-type", "application/json"),
    }
    if request.method == "POST" and path.rstrip("/") == "orders":
        headers["Idempotency-Key"] = (
            request.headers.get("Idempotency-Key") or str(uuid.uuid4())
        )

    try:
        upstream = await _client.request(
            request.method, f"/{path}", content=raw,
            params=dict(request.query_params), headers=headers,
        )
    except httpx.HTTPError as exc:
        log_event(log, "web.upstream_error", path=path, error=str(exc))
        return JSONResponse(
            status_code=503,
            content={"error": "app_tier_unavailable",
                     "message": "Không kết nối được tới tầng xử lý. "
                                "Đơn của bạn CHƯA được ghi nhận."},
        )

    return Response(
        content=upstream.content,
        status_code=upstream.status_code,
        media_type=upstream.headers.get("content-type", "application/json"),
    )


@app.on_event("startup")
def _startup():
    log_event(log, "service.started", app_tier=config.APP_TIER_URL)
