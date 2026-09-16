-- ============================================================================
-- Sidecar store — hàng đợi + accept store cho môi trường LOCAL/DEMO.
--
-- Chạy trên một PostgreSQL container TÁCH RIÊNG khỏi DB nghiệp vụ. Lý do:
-- trên AWS, SQS và DynamoDB là dịch vụ độc lập với RDS. Nếu ở local ta để
-- hàng đợi nằm chung DB với bảng orders thì khi chặn RDS để chạy test B4
-- ("DB mất kết nối 3 phút") hàng đợi cũng chết theo, và kịch bản không còn
-- chứng minh được điều gì.
--
-- Khi lên AWS: QUEUE_DRIVER=sqs + ACCEPT_STORE_DRIVER=dynamodb, file này
-- không được dùng tới.
-- ============================================================================

-- ------------------------------------------------------------- accept-store
-- Ràng buộc #3 + #5. Ghi nhận "đã nhận yêu cầu" NGAY tại App tier, trước khi
-- đơn được persist. Hai việc:
--   1. Khử trùng lặp theo idempotency_key kể cả khi RDS đang chết.
--   2. Cho phép GET /orders/{id} trả PENDING (thay vì 404) trong lúc worker
--      chưa kịp ghi -> client biết trạng thái thật, không bị báo thành công khống.
-- Trên AWS, driver mặc định là DynamoDB on-demand (tách khỏi RDS). Bảng này là
-- driver "pg" dùng cho môi trường local/demo.
CREATE TABLE IF NOT EXISTS order_accept (
    idempotency_key TEXT        PRIMARY KEY,
    order_id        UUID        NOT NULL,
    correlation_id  TEXT,
    payload         JSONB       NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '24 hours'
);

CREATE INDEX IF NOT EXISTS idx_order_accept_order ON order_accept (order_id);

-- ------------------------------------------------------------ queue (local)
-- Driver hàng đợi cho môi trường local, mô phỏng ngữ nghĩa SQS FIFO:
-- visibility timeout, dedup window, message group, receive count -> DLQ.
-- Trên AWS thay bằng SQS FIFO thật (QUEUE_DRIVER=sqs), bảng này không dùng đến.
CREATE TABLE IF NOT EXISTS order_queue (
    msg_id         BIGSERIAL   PRIMARY KEY,
    dedup_id       TEXT        NOT NULL UNIQUE,
    group_id       TEXT        NOT NULL,
    body           JSONB       NOT NULL,
    receive_count  INT         NOT NULL DEFAULT 0,
    visible_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_order_queue_visible ON order_queue (visible_at, msg_id);

CREATE TABLE IF NOT EXISTS order_queue_dlq (
    msg_id        BIGINT      PRIMARY KEY,
    dedup_id      TEXT        NOT NULL,
    group_id      TEXT        NOT NULL,
    body          JSONB       NOT NULL,
    receive_count INT         NOT NULL,
    last_error    TEXT,
    moved_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
