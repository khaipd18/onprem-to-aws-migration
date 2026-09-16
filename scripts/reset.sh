#!/usr/bin/env bash
# Xoá sạch dữ liệu nghiệp vụ và seed lại. Dùng trước khi quay video demo.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ORDERS="${ORDERS:-5000}"
head1 "reset dữ liệu"
$COMPOSE --profile tools run --rm tools /work/db/seed.py --orders "$ORDERS" --truncate
docker exec abc-queue-db psql -U abcapp -d abcqueue -c \
  "TRUNCATE order_queue, order_queue_dlq, order_accept RESTART IDENTITY" >/dev/null
say "đã xoá hàng đợi và accept store"
say "xong"
