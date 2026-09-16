"""Connection pool tới PostgreSQL.

Ba "role" pool riêng biệt:
  primary — RDS (qua RDS Proxy) — đọc/ghi nghiệp vụ.
  replica — RDS read replica — CHỈ dành cho job báo cáo (ràng buộc #10).
  queue   — PostgreSQL sidecar chứa hàng đợi + accept store khi QUEUE_DRIVER=pg.
            Trên AWS thay bằng SQS + DynamoDB nên pool này không được mở.

Điểm quan trọng cho ràng buộc #5 (DB mất kết nối 3 phút):
  * Pool KHÔNG được làm sập process khi DB chết. Pool tự thử kết nối lại ở nền;
    lúc DB chết `pool.connection()` ném PoolTimeout, ta bắt và trả 503 —
    KHÔNG BAO GIỜ trả 200 "thành công".
  * Trên AWS, DSN primary trỏ tới RDS Proxy chứ không trỏ thẳng RDS. Proxy giữ
    client connection xuyên suốt failover và tự nối lại backend, nên app tự
    hoạt động trở lại mà không cần restart thủ công.
"""
from __future__ import annotations

import contextlib
from typing import Iterator

import psycopg
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool, PoolTimeout

from .config import config
from .logging import get_logger

log = get_logger(__name__)

PRIMARY = "primary"
REPLICA = "replica"
QUEUE = "queue"


class DatabaseUnavailable(RuntimeError):
    """DB không phục vụ được ngay lúc này. Caller PHẢI trả 503, không được trả 200."""


_pools: dict[str, ConnectionPool] = {}


def _resolve(role: str) -> str:
    if role == REPLICA and not config.has_replica():
        return PRIMARY
    return role


def get_pool(role: str = PRIMARY) -> ConnectionPool:
    role = _resolve(role)
    if role not in _pools:
        _pools[role] = ConnectionPool(
            conninfo=config.dsn(role),
            min_size=config.DB_POOL_MIN,
            max_size=config.DB_POOL_MAX,
            # Không chặn startup nếu DB chưa sẵn sàng: instance vẫn boot được,
            # /health báo unhealthy và ALB tự loại khỏi target group.
            open=True,
            check=ConnectionPool.check_connection,
            timeout=config.DB_CONNECT_TIMEOUT,
            max_lifetime=1800,
            reconnect_timeout=0,   # thử lại vô hạn ở nền, không tự đóng pool
            name=role,
            kwargs={"row_factory": dict_row, "autocommit": False},
        )
    return _pools[role]


@contextlib.contextmanager
def connection(role: str = PRIMARY) -> Iterator[psycopg.Connection]:
    """Mượn connection. Ném DatabaseUnavailable nếu không lấy được trong timeout."""
    try:
        with get_pool(role).connection(timeout=config.DB_CONNECT_TIMEOUT) as conn:
            yield conn
    except (PoolTimeout, psycopg.OperationalError) as exc:
        raise DatabaseUnavailable(f"[{role}] {exc}") from exc


@contextlib.contextmanager
def transaction(role: str = PRIMARY) -> Iterator[psycopg.Cursor]:
    """Một transaction: commit khi thoát sạch, rollback khi có exception."""
    with connection(role) as conn:
        with conn.transaction():
            with conn.cursor() as cur:
                yield cur


def healthy(role: str = PRIMARY) -> tuple[bool, str]:
    """Kiểm tra sâu tới tận database, phục vụ GET /health.

    Không phải endpoint của ALB target group — ALB gọi /ready. Xem docstring
    của /health trong app/appapi/main.py.
    """
    try:
        with connection(role) as conn, conn.cursor() as cur:
            cur.execute("SELECT 1 AS ok")
            cur.fetchone()
        return True, "ok"
    except DatabaseUnavailable as exc:
        return False, f"database unavailable: {exc}"
    except Exception as exc:  # noqa: BLE001
        return False, f"database error: {exc}"


def close_pools() -> None:
    for pool in _pools.values():
        with contextlib.suppress(Exception):
            pool.close()
    _pools.clear()
