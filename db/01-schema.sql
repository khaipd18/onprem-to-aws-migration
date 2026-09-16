-- ============================================================================
-- ABC Manufacturing — Sales B2B schema
-- Dùng CHUNG cho cả on-premise (nguồn) và AWS RDS (đích) để DMS full-load +
-- CDC map 1-1 giữa 2 bên. Mọi thay đổi schema phải áp dụng cả 2 phía.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------- master data
CREATE TABLE IF NOT EXISTS customers (
    id          BIGSERIAL PRIMARY KEY,
    code        TEXT        NOT NULL UNIQUE,
    name        TEXT        NOT NULL,
    branch      TEXT        NOT NULL,          -- HQ | BR-HCM | BR-DN
    department  TEXT        NOT NULL,          -- khớp với phòng ban trên File Server
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS products (
    id          BIGSERIAL PRIMARY KEY,
    sku         TEXT        NOT NULL UNIQUE,
    name        TEXT        NOT NULL,
    unit_price  NUMERIC(14,2) NOT NULL CHECK (unit_price >= 0),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- --------------------------------------------------------------------- orders
-- status: PENDING -> CONFIRMED | FAILED
--   PENDING   = đã nhận yêu cầu, CHƯA ghi nhận thành công
--   CONFIRMED = đã commit vào DB, là trạng thái duy nhất được coi là "thành công"
--   FAILED    = xử lý thất bại vĩnh viễn (đã vào DLQ), không tính doanh thu
CREATE TABLE IF NOT EXISTS orders (
    id               UUID          PRIMARY KEY,
    order_no         TEXT          NOT NULL UNIQUE,
    customer_id      BIGINT        NOT NULL REFERENCES customers(id),
    status           TEXT          NOT NULL DEFAULT 'PENDING'
                                   CHECK (status IN ('PENDING','CONFIRMED','FAILED','CANCELLED')),
    total_amount     NUMERIC(14,2) NOT NULL DEFAULT 0,

    -- Ràng buộc #3: chống tạo đơn trùng khi client gửi lại.
    -- Tuyến phòng thủ CUỐI CÙNG ở tầng DB; tuyến đầu là accept-store (xem order_accept).
    idempotency_key  TEXT          NOT NULL UNIQUE,

    -- Ràng buộc #3: chống âm thầm ghi đè khi nhiều người cùng sửa (optimistic locking).
    -- Mọi UPDATE bắt buộc kèm "WHERE version = $expected".
    version          INT           NOT NULL DEFAULT 1,

    -- Ràng buộc #8: truy vết 1 giao dịch xuyên các tier.
    correlation_id   TEXT,
    source_system    TEXT          NOT NULL DEFAULT 'aws',   -- onprem | aws
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    confirmed_at     TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders (created_at);
CREATE INDEX IF NOT EXISTS idx_orders_status     ON orders (status);
CREATE INDEX IF NOT EXISTS idx_orders_customer   ON orders (customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_corr       ON orders (correlation_id);

CREATE TABLE IF NOT EXISTS order_items (
    id          BIGSERIAL     PRIMARY KEY,
    order_id    UUID          NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    product_id  BIGINT        NOT NULL REFERENCES products(id),
    quantity    INT           NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(14,2) NOT NULL,
    line_total  NUMERIC(14,2) GENERATED ALWAYS AS (quantity * unit_price) STORED
);

CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items (order_id);

-- Ràng buộc #8: nhật ký hành trình của từng đơn, phục vụ "xác định trạng thái
-- và phạm vi ảnh hưởng khi có lỗi".
CREATE TABLE IF NOT EXISTS order_events (
    id             BIGSERIAL   PRIMARY KEY,
    order_id       UUID        NOT NULL,
    event          TEXT        NOT NULL,   -- ACCEPTED|DEDUPED|PERSISTED|UPDATED|CONFLICT|FAILED|RESTORED
    tier           TEXT        NOT NULL,   -- web|app|worker|job
    detail         JSONB       NOT NULL DEFAULT '{}'::jsonb,
    correlation_id TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_order_events_order ON order_events (order_id, created_at);
CREATE INDEX IF NOT EXISTS idx_order_events_corr  ON order_events (correlation_id);

-- ------------------------------------------------------------------ reports
-- Ràng buộc #10: báo cáo phải nhất quán với dữ liệu tại "thời điểm chốt".
-- cutoff_at là mốc chốt; checksum để chứng minh 2 lần chạy cùng cutoff ra
-- cùng kết quả (không thiếu, không đếm trùng).
CREATE TABLE IF NOT EXISTS report_runs (
    id            BIGSERIAL     PRIMARY KEY,
    report_name   TEXT          NOT NULL,
    cutoff_at     TIMESTAMPTZ   NOT NULL,
    started_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    finished_at   TIMESTAMPTZ,
    ran_on        TEXT          NOT NULL DEFAULT 'replica',  -- replica | primary
    order_count   BIGINT,
    total_amount  NUMERIC(18,2),
    checksum      TEXT,
    correlation_id TEXT
);
