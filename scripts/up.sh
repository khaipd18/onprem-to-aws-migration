#!/usr/bin/env bash
# Dựng toàn bộ môi trường local và seed dữ liệu. Idempotent — chạy lại được.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ORDERS="${ORDERS:-5000}"
WITH_ONPREM="${WITH_ONPREM:-0}"

head1 "1/4 — build & khởi động môi trường đích (giống AWS)"
$COMPOSE up -d --build

head1 "2/4 — chờ các service healthy"
for i in $(seq 1 60); do
  ready=$($COMPOSE ps --format '{{.Service}} {{.Health}}' 2>/dev/null \
          | grep -c 'healthy' || true)
  printf '\r  %d/5 service healthy  ' "$ready"
  [ "$ready" -ge 5 ] && break
  sleep 3
done
echo
$COMPOSE ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'

head1 "3/4 — seed $ORDERS đơn hàng"
existing=$(psql_q "SELECT count(*) FROM orders" 2>/dev/null || echo 0)
if [ "${existing:-0}" -gt 0 ]; then
  say "database đã có $existing đơn — bỏ qua seed (dùng scripts/reset.sh để làm lại)"
else
  $COMPOSE --profile tools run --rm tools /work/db/seed.py --orders "$ORDERS"
fi

if [ "$WITH_ONPREM" = "1" ]; then
  head1 "4/4 — khởi động môi trường NGUỒN (on-premise)"
  $COMPOSE --profile onprem up -d
  say "chờ on-prem DB..."
  for i in $(seq 1 30); do
    docker exec abc-onprem-db pg_isready -U abcapp -d abcsales >/dev/null 2>&1 && break
    sleep 2
  done
  DB_HOST=onprem-db $COMPOSE --profile tools run --rm \
    -e DB_HOST=onprem-db tools /work/db/seed.py --orders "$ORDERS"
  bash "$ROOT/scripts/make-fileshare.sh"
else
  head1 "4/4 — bỏ qua môi trường on-premise"
  say "chạy lại với WITH_ONPREM=1 nếu cần diễn tập cutover"
fi

head1 "Sẵn sàng"
cat <<EOF
  Web (người dùng cuối) : http://localhost:8080
  App tier (API)        : http://localhost:8081/docs
  PostgreSQL primary    : localhost:5432   (abcapp/abcapp, db abcsales)
  PostgreSQL replica    : localhost:5433   (chỉ đọc)
  Queue/accept store    : localhost:5434   (db abcqueue)
EOF
[ "$WITH_ONPREM" = "1" ] && cat <<EOF
  --- môi trường NGUỒN ---
  Web on-prem           : http://localhost:18080
  App on-prem (legacy)  : http://localhost:18081
  PostgreSQL on-prem    : localhost:15432
  File server (POSIX)   : docker exec -u sales_user abc-onprem-files ls /share
EOF
echo
echo "  Chạy toàn bộ test:  bash scripts/test-all.sh"
