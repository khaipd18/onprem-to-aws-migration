#!/usr/bin/env python3
"""Sinh dữ liệu nghiệp vụ cho ABC Manufacturing.

Yêu cầu cho phép "thu nhỏ dung lượng dữ liệu thực hành nhưng phải giữ đầy đủ các
hành vi". Vì vậy ở đây giữ nguyên cấu trúc thật (3 chi nhánh, 5 phòng ban,
khách hàng, sản phẩm, đơn có nhiều dòng hàng) nhưng số dòng nhỏ lại để full
load DMS chạy trong vài phút thay vì vài giờ.

    python3 db/seed.py --orders 5000
    python3 db/seed.py --orders 200000 --batch 5000     # dựng ~2GB cho load test

Mặc định nối tới DB nghiệp vụ qua biến môi trường DB_HOST/DB_PORT/... giống app.
"""
from __future__ import annotations

import argparse
import os
import random
import sys
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import psycopg
from psycopg.rows import dict_row

BRANCHES = ["HQ", "BR-HCM", "BR-DN"]
DEPARTMENTS = ["sales", "purchasing", "production", "finance", "hr"]

CUSTOMER_NAMES = [
    "Cơ khí Thành Đạt", "Nhựa Tân Phú", "Điện máy Hoà Bình", "Thép Việt Nhật",
    "Bao bì Minh Long", "Cao su Đồng Nai", "Xây dựng An Phát", "Vật tư Sài Gòn",
    "Kim khí Đại Việt", "Hoá chất Bình Minh", "Gỗ Trường Thành", "Dệt may Phong Phú",
    "Linh kiện Á Châu", "Thiết bị Nam Việt", "Vòng bi Hải Âu", "Sơn Đại Dương",
    "Ống thép Hưng Yên", "Khuôn mẫu Tân Tiến", "Máy CNC Việt Đức", "Phụ tùng Thăng Long",
]

PRODUCT_LINES = [
    ("BRG", "Vòng bi công nghiệp", 850_000, 4_200_000),
    ("MTR", "Động cơ điện 3 pha", 6_500_000, 32_000_000),
    ("VLV", "Van công nghiệp", 1_200_000, 9_800_000),
    ("PMP", "Bơm ly tâm", 4_800_000, 26_000_000),
    ("GBX", "Hộp giảm tốc", 7_200_000, 41_000_000),
    ("BLT", "Dây đai truyền động", 320_000, 2_600_000),
    ("SNS", "Cảm biến áp suất", 1_500_000, 7_400_000),
    ("PLC", "Bộ điều khiển PLC", 9_800_000, 58_000_000),
]

STATUS_WEIGHTS = [("CONFIRMED", 0.93), ("CANCELLED", 0.05), ("FAILED", 0.02)]


def connect() -> psycopg.Connection:
    dsn = (
        f"host={os.getenv('DB_HOST', 'localhost')} "
        f"port={os.getenv('DB_PORT', '5432')} "
        f"dbname={os.getenv('DB_NAME', 'abcsales')} "
        f"user={os.getenv('DB_USER', 'abcapp')} "
        f"password={os.getenv('DB_PASSWORD', 'abcapp')}"
    )
    return psycopg.connect(dsn, row_factory=dict_row, autocommit=False)


def seed_master(conn: psycopg.Connection, n_customers: int) -> tuple[list, list]:
    with conn.cursor() as cur:
        for i in range(n_customers):
            base = CUSTOMER_NAMES[i % len(CUSTOMER_NAMES)]
            suffix = f" {i // len(CUSTOMER_NAMES) + 1}" if i >= len(CUSTOMER_NAMES) else ""
            cur.execute(
                """INSERT INTO customers (code, name, branch, department)
                   VALUES (%s, %s, %s, %s) ON CONFLICT (code) DO NOTHING""",
                (f"CUST-{i + 1:04d}", f"Công ty {base}{suffix}",
                 BRANCHES[i % len(BRANCHES)], DEPARTMENTS[i % len(DEPARTMENTS)]),
            )

        for prefix, name, lo, hi in PRODUCT_LINES:
            for variant in range(1, 7):
                cur.execute(
                    """INSERT INTO products (sku, name, unit_price)
                       VALUES (%s, %s, %s) ON CONFLICT (sku) DO NOTHING""",
                    (f"{prefix}-{variant:03d}", f"{name} model {variant}",
                     Decimal(random.randint(lo, hi)).quantize(Decimal("1"))),
                )

        cur.execute("SELECT id, code FROM customers ORDER BY id")
        customers = cur.fetchall()
        cur.execute("SELECT id, sku, unit_price FROM products ORDER BY id")
        products = cur.fetchall()
    conn.commit()
    return customers, products


def pick_status() -> str:
    roll, acc = random.random(), 0.0
    for status, weight in STATUS_WEIGHTS:
        acc += weight
        if roll < acc:
            return status
    return "CONFIRMED"


def seed_orders(conn, customers, products, count, days_back, batch) -> int:
    now = datetime.now(timezone.utc)
    written = 0

    with conn.cursor() as cur:
        for start in range(0, count, batch):
            chunk = min(batch, count - start)
            order_rows, item_rows = [], []

            for _ in range(chunk):
                order_id = uuid.uuid4()
                customer = random.choice(customers)
                status = pick_status()
                # Phân bố lệch về những ngày gần đây, giống dữ liệu bán hàng thật.
                age_days = days_back * (random.random() ** 1.7)
                created = now - timedelta(days=age_days,
                                          seconds=random.randint(0, 86399))

                total = Decimal(0)
                for _line in range(random.randint(1, 5)):
                    product = random.choice(products)
                    qty = random.randint(1, 20)
                    price = Decimal(str(product["unit_price"]))
                    total += price * qty
                    item_rows.append((order_id, product["id"], qty, price))

                order_rows.append((
                    order_id,
                    "SO-" + order_id.hex[:12].upper(),
                    customer["id"],
                    status,
                    total,
                    f"seed-{order_id}",                  # idempotency key duy nhất
                    1,
                    f"Root=1-{int(created.timestamp()):08x}-{order_id.hex[:24]}",
                    "onprem",                            # dữ liệu lịch sử = từ on-prem
                    created,
                    created,
                    created if status == "CONFIRMED" else None,
                ))

            cur.executemany(
                """INSERT INTO orders (id, order_no, customer_id, status, total_amount,
                                       idempotency_key, version, correlation_id,
                                       source_system, created_at, updated_at, confirmed_at)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                   ON CONFLICT (idempotency_key) DO NOTHING""",
                order_rows,
            )
            cur.executemany(
                """INSERT INTO order_items (order_id, product_id, quantity, unit_price)
                   VALUES (%s,%s,%s,%s)""",
                item_rows,
            )
            conn.commit()
            written += chunk
            print(f"  ... {written:,}/{count:,} đơn", flush=True)

    return written


def main() -> int:
    ap = argparse.ArgumentParser(description="Sinh dữ liệu demo cho ABC Manufacturing")
    ap.add_argument("--orders", type=int, default=5000, help="số đơn cần tạo")
    ap.add_argument("--customers", type=int, default=60)
    ap.add_argument("--days-back", type=int, default=180,
                    help="dải thời gian tạo đơn, tính ngược từ hôm nay")
    ap.add_argument("--batch", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=42, help="cố định để tái lập được")
    ap.add_argument("--truncate", action="store_true",
                    help="xoá sạch dữ liệu cũ trước khi seed")
    args = ap.parse_args()

    random.seed(args.seed)

    with connect() as conn:
        if args.truncate:
            with conn.cursor() as cur:
                cur.execute("TRUNCATE order_items, order_events, orders, "
                            "report_runs RESTART IDENTITY CASCADE")
                cur.execute("TRUNCATE customers, products RESTART IDENTITY CASCADE")
            conn.commit()
            print("đã xoá dữ liệu cũ")

        print("seed master data...")
        customers, products = seed_master(conn, args.customers)
        print(f"  {len(customers)} khách hàng, {len(products)} sản phẩm")

        print(f"seed {args.orders:,} đơn hàng...")
        seed_orders(conn, customers, products, args.orders, args.days_back, args.batch)

        with conn.cursor() as cur:
            cur.execute("""SELECT status, count(*) AS n, sum(total_amount) AS amount
                             FROM orders GROUP BY status ORDER BY status""")
            print("\nkết quả:")
            for row in cur.fetchall():
                print(f"  {row['status']:<10} {row['n']:>8,}  "
                      f"{Decimal(row['amount'] or 0):>20,.0f} ₫")
            cur.execute("SELECT pg_size_pretty(pg_database_size(current_database())) AS s")
            print(f"\ndung lượng database: {cur.fetchone()['s']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
