"""Cấu hình lấy từ biến môi trường.

Trên AWS: giá trị nhạy cảm (DB credential) đến từ Secrets Manager, giá trị
không nhạy cảm (endpoint, feature flag) đến từ SSM Parameter Store — user-data
export chúng ra env trước khi chạy service. Ở local thì lấy từ docker-compose.
"""
import os


def _bool(name: str, default: bool = False) -> bool:
    return os.getenv(name, str(default)).strip().lower() in ("1", "true", "yes", "on")


def _int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, "") or default)
    except ValueError:
        return default


class Config:
    # --- danh tính service, đi vào mọi dòng log ---------------------------
    TIER = os.getenv("TIER", "app")                      # web | app | worker | job
    ENV = os.getenv("APP_ENV", "local")
    INSTANCE_ID = os.getenv("INSTANCE_ID") or os.uname().nodename

    # --- database ---------------------------------------------------------
    # Trên AWS, DB_HOST trỏ tới RDS Proxy chứ KHÔNG trỏ thẳng RDS. Đây là điều
    # kiện để ràng buộc #5 đạt được mà không cần restart app khi failover.
    DB_HOST = os.getenv("DB_HOST", "localhost")
    DB_PORT = _int("DB_PORT", 5432)
    DB_NAME = os.getenv("DB_NAME", "abcsales")
    DB_USER = os.getenv("DB_USER", "abcapp")
    DB_PASSWORD = os.getenv("DB_PASSWORD", "abcapp")
    DB_SSLMODE = os.getenv("DB_SSLMODE", "prefer")
    DB_CONNECT_TIMEOUT = _int("DB_CONNECT_TIMEOUT", 5)
    DB_POOL_MIN = _int("DB_POOL_MIN", 1)
    DB_POOL_MAX = _int("DB_POOL_MAX", 10)

    # Read replica — ràng buộc #10: job báo cáo chạy ở đây, không đụng OLTP.
    # Bỏ trống => report chạy trên primary (ghi rõ ran_on='primary' trong report_runs).
    DB_REPLICA_HOST = os.getenv("DB_REPLICA_HOST", "")
    DB_REPLICA_PORT = _int("DB_REPLICA_PORT", 5432)
    # Thời gian tối đa chờ replica replay tới mốc chốt trước khi chạy báo cáo.
    # Xem _wait_for_replica_catchup() để biết vì sao đây là điều kiện bắt buộc.
    REPLICA_CATCHUP_TIMEOUT = _int("REPLICA_CATCHUP_TIMEOUT", 30)

    # --- sidecar DB cho queue + accept store (chỉ dùng khi driver = pg) ----
    # PHẢI là một PostgreSQL TÁCH RIÊNG khỏi DB nghiệp vụ. Trên AWS, SQS và
    # DynamoDB độc lập hoàn toàn với RDS; nếu ở local ta nhét queue chung DB
    # với orders thì khi chặn RDS (test B4) queue chết theo và kịch bản mất ý
    # nghĩa. Tách container riêng để mô phỏng đúng ranh giới đó.
    QUEUE_DB_HOST = os.getenv("QUEUE_DB_HOST", "") or os.getenv("DB_HOST", "localhost")
    QUEUE_DB_PORT = _int("QUEUE_DB_PORT", 5432)
    QUEUE_DB_NAME = os.getenv("QUEUE_DB_NAME", "abcqueue")
    QUEUE_DB_USER = os.getenv("QUEUE_DB_USER", "abcapp")
    QUEUE_DB_PASSWORD = os.getenv("QUEUE_DB_PASSWORD", "abcapp")

    # --- queue ------------------------------------------------------------
    QUEUE_DRIVER = os.getenv("QUEUE_DRIVER", "pg")        # pg | sqs
    SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL", "")
    SQS_DLQ_URL = os.getenv("SQS_DLQ_URL", "")
    VISIBILITY_TIMEOUT = _int("VISIBILITY_TIMEOUT", 180)  # >= 6x thời gian xử lý
    MAX_RECEIVE_COUNT = _int("MAX_RECEIVE_COUNT", 5)      # vượt ngưỡng -> DLQ

    # --- accept store -----------------------------------------------------
    ACCEPT_STORE_DRIVER = os.getenv("ACCEPT_STORE_DRIVER", "pg")   # pg | dynamodb
    DDB_ACCEPT_TABLE = os.getenv("DDB_ACCEPT_TABLE", "abc-order-accept")

    # --- CORS -------------------------------------------------------------
    # Trên AWS, CloudFront phục vụ cả giao diện lẫn /api/*, nên trình duyệt gọi
    # CÙNG MỘT origin và không cần CORS. Biến này chỉ dùng cho trường hợp mở
    # trang từ nơi khác — chạy giao diện ở local mà gọi thẳng ALB chẳng hạn.
    # Bỏ trống => không bật CORS, và đó là mặc định đúng.
    ALLOWED_ORIGINS = [
        o.strip() for o in os.getenv("ALLOWED_ORIGINS", "").split(",") if o.strip()
    ]

    # --- tier chaining ----------------------------------------------------
    # Web tier gọi App tier qua ALB internal.
    APP_TIER_URL = os.getenv("APP_TIER_URL", "http://localhost:8081")
    HTTP_TIMEOUT = _int("HTTP_TIMEOUT", 10)

    # --- worker -----------------------------------------------------------
    WORKER_BATCH = _int("WORKER_BATCH", 10)
    WORKER_POLL_SECONDS = _int("WORKER_POLL_SECONDS", 5)

    # --- chế độ legacy ----------------------------------------------------
    # LEGACY_MODE=true => App tier ghi thẳng DB đồng bộ, không qua hàng đợi.
    # Đây là hành vi của hệ thống on-premise hiện tại, dùng làm nguồn migration
    # và làm mốc so sánh "trước / sau" khi demo ràng buộc #5.
    LEGACY_MODE = _bool("LEGACY_MODE", False)

    AWS_REGION = os.getenv("AWS_REGION", "ap-southeast-1")

    @classmethod
    def dsn(cls, role: str = "primary") -> str:
        """role: primary | replica | queue."""
        if role == "replica" and cls.DB_REPLICA_HOST:
            host, port = cls.DB_REPLICA_HOST, cls.DB_REPLICA_PORT
            name, user, pwd = cls.DB_NAME, cls.DB_USER, cls.DB_PASSWORD
        elif role == "queue":
            host, port = cls.QUEUE_DB_HOST, cls.QUEUE_DB_PORT
            name, user, pwd = cls.QUEUE_DB_NAME, cls.QUEUE_DB_USER, cls.QUEUE_DB_PASSWORD
        else:
            host, port = cls.DB_HOST, cls.DB_PORT
            name, user, pwd = cls.DB_NAME, cls.DB_USER, cls.DB_PASSWORD
        # make_conninfo tu thoat dau nhay va khoang trang trong mat khau. Noi
        # chuoi bang tay se hong am tham neu mat khau chua nhung ky tu do.
        from psycopg.conninfo import make_conninfo

        return make_conninfo(
            host=host, port=port, dbname=name, user=user, password=pwd,
            sslmode=cls.DB_SSLMODE, connect_timeout=cls.DB_CONNECT_TIMEOUT,
        )

    @classmethod
    def has_replica(cls) -> bool:
        return bool(cls.DB_REPLICA_HOST)


config = Config()
