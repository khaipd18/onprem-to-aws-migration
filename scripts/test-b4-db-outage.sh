#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Test B4 — Ràng buộc #5: Application mất kết nối PostgreSQL trong 3 phút.
#
# Yêu cầu yêu cầu, nguyên văn:
#   "hệ thống không được thông báo thành công cho giao dịch chưa được ghi nhận.
#    Khi kết nối phục hồi, ứng dụng phải tự hoạt động trở lại, không cần khởi
#    động lại thủ công, không mất giao dịch đã xác nhận và không tạo đơn trùng."
#
# Cách gây sự cố ở local: ngắt container database khỏi network Docker. Tương
# đương với việc gỡ rule 5432 trên security group sg-rds khi chạy trên AWS —
# kết nối treo rồi timeout, chứ không phải DB tự tắt sạch sẽ.
#
# Bốn điều được kiểm chứng:
#   1. Trong lúc sự cố, KHÔNG đơn nào được báo CONFIRMED.
#   2. Sau khi hồi phục, MỌI đơn đã nhận đều trở thành CONFIRMED (không mất).
#   3. Mỗi Idempotency-Key vẫn chỉ ứng với đúng 1 đơn (không trùng).
#   4. Không ai restart app/worker — kiểm chứng bằng thời điểm khởi động container.
# ---------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
start_evidence b4-db-outage

OUTAGE_SECONDS="${OUTAGE_SECONDS:-180}"
ORDERS_DURING="${ORDERS_DURING:-20}"
NETWORK="${NETWORK:-abc-sales_default}"
DB_CONTAINER=abc-db

started_app=$(docker inspect -f '{{.State.StartedAt}}' abc-sales-app-1)
started_worker=$(docker inspect -f '{{.State.StartedAt}}' abc-sales-worker-1)

head1 "B4 — chuẩn bị"
say "sự cố kéo dài ${OUTAGE_SECONDS}s, gửi $ORDERS_DURING đơn trong lúc đó"
before_total=$(psql_q "SELECT count(*) FROM orders")
say "số đơn trước sự cố: $before_total"

KEYS_FILE=$(mktemp); IDS_FILE=$(mktemp); CODES_FILE=$(mktemp)

head1 "T+0 — NGẮT kết nối tới database"
docker network disconnect "$NETWORK" "$DB_CONTAINER"
OUTAGE_START=$(date +%s)
say "$(ts) đã ngắt $DB_CONTAINER khỏi network $NETWORK"

head1 "Trong lúc sự cố — gửi đơn và quan sát phản hồi"
interval=$(( OUTAGE_SECONDS / ORDERS_DURING )); [ "$interval" -lt 1 ] && interval=1
for i in $(seq 1 "$ORDERS_DURING"); do
  key="outage-$(uuid)"
  resp=$(curl -s -m 15 -w '\n%{http_code}' -X POST "$WEB_URL/api/orders" \
     -H 'Content-Type: application/json' -H "Idempotency-Key: $key" \
     -d '{"customer_code":"CUST-0003","items":[{"sku":"PMP-001","quantity":1}]}')
  code=$(echo "$resp" | tail -1)
  oid=$(echo "$resp" | head -1 | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("order_id",""))
except Exception: print("")' 2>/dev/null)
  status=$(echo "$resp" | head -1 | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("status",""))
except Exception: print("")' 2>/dev/null)
  echo "$key" >> "$KEYS_FILE"; echo "$code" >> "$CODES_FILE"
  [ -n "$oid" ] && echo "$oid" >> "$IDS_FILE"
  printf '  +%03ds  HTTP %s  status=%-9s order=%s\n' \
    "$(( $(date +%s) - OUTAGE_START ))" "$code" "${status:-–}" "${oid:0:8}"
  sleep "$interval"
done | tee -a "$EVIDENCE_FILE"

elapsed=$(( $(date +%s) - OUTAGE_START ))
[ "$elapsed" -lt "$OUTAGE_SECONDS" ] && sleep $(( OUTAGE_SECONDS - elapsed ))

head1 "Kiểm chứng #1 — trong sự cố, không có đơn nào CONFIRMED"
confirmed_during=0
while read -r oid; do
  [ -z "$oid" ] && continue
  st=$(order_status "$oid")
  [ "$st" = "CONFIRMED" ] && confirmed_during=$((confirmed_during+1))
done < "$IDS_FILE"
check "số đơn được báo CONFIRMED trong lúc DB chết" "$confirmed_during" "0"

qdepth=$(curl -s -m 5 "$APP_URL/ops/queue" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("visible","?"))
except Exception: print("?")')
say "hàng đợi đang giữ $qdepth message chưa xử lý được"

head1 "T+${OUTAGE_SECONDS}s — KHÔI PHỤC kết nối database"
# --alias db là BẮT BUỘC: docker network connect không tự khôi phục network
# alias mà compose đã đặt, nên nếu thiếu cờ này thì hostname "db" sẽ không còn
# phân giải được, và read replica sẽ vĩnh viễn không nối lại được primary.
docker network connect --alias db "$NETWORK" "$DB_CONTAINER"
RECOVER_AT=$(date +%s)
say "$(ts) đã nối lại $DB_CONTAINER"
say "KHÔNG restart app/worker — hệ thống phải tự hồi phục"

head1 "Kiểm tra DNS đã khôi phục"
if docker exec abc-sales-app-1 python3 -c "import socket;socket.gethostbyname('db')" 2>/dev/null; then
  say "hostname 'db' phân giải được — kết nối mới sẽ thành công"
else
  printf '  %sFAIL%s  hostname "db" không phân giải được sau khi nối lại mạng\n' "$C_ERR" "$C_0"
  FAIL_COUNT=$((FAIL_COUNT+1))
fi

head1 "Chờ hệ thống tự drain hàng đợi"
accepted=$(grep -c . "$IDS_FILE")
drained=0
for i in $(seq 1 180); do
  ok=0
  while read -r oid; do
    [ -z "$oid" ] && continue
    [ "$(order_status "$oid")" = "CONFIRMED" ] && ok=$((ok+1))
  done < "$IDS_FILE"
  drained=$ok
  printf '\r  +%03ds sau khi nối lại: %d/%d đơn đã CONFIRMED  ' \
     "$(( $(date +%s) - RECOVER_AT ))" "$ok" "$accepted"
  [ "$ok" -ge "$accepted" ] && break
  sleep 3
done
echo
RECOVERY_SECONDS=$(( $(date +%s) - RECOVER_AT ))

# Đo chính xác hơn: lấy confirmed_at muộn nhất trong số các đơn của đợt này rồi
# trừ đi thời điểm nối lại mạng. Vòng poll ở trên có độ phân giải 3 giây nên
# con số của nó chỉ là cận trên.
RECOVER_ISO=$(date -u -d "@$RECOVER_AT" +%Y-%m-%dT%H:%M:%SZ)
DRAIN_SECONDS=$(psql_q "SELECT round(extract(epoch FROM (max(confirmed_at) - timestamptz '$RECOVER_ISO'))::numeric, 1)
                          FROM orders WHERE idempotency_key LIKE 'outage-%'")
say "thời gian tự hồi phục: ${RECOVERY_SECONDS}s theo vòng poll (3s/lần)"
say "đo từ confirmed_at trong DB: đơn cuối cùng được ghi ${DRAIN_SECONDS}s sau khi nối lại mạng"

head1 "Kiểm chứng #2..4"
check "mọi đơn đã tiếp nhận đều CONFIRMED (không mất)" "$drained" "$accepted"

dup=$(psql_q "SELECT coalesce(count(*),0) FROM (
        SELECT idempotency_key FROM orders WHERE idempotency_key LIKE 'outage-%'
        GROUP BY idempotency_key HAVING count(*) > 1) d")
check "số Idempotency-Key bị tạo trùng đơn" "$dup" "0"

now_app=$(docker inspect -f '{{.State.StartedAt}}' abc-sales-app-1)
now_worker=$(docker inspect -f '{{.State.StartedAt}}' abc-sales-worker-1)
check "App tier KHÔNG bị restart"  "$now_app"    "$started_app"
check "Worker  KHÔNG bị restart"   "$now_worker" "$started_worker"

after_total=$(psql_q "SELECT count(*) FROM orders")
say "số đơn sau sự cố: $after_total (trước: $before_total, chênh: $((after_total-before_total)))"

{ echo "--- $(ts) B4 ---"
  echo "outage_seconds=$OUTAGE_SECONDS accepted=$accepted confirmed_during_outage=$confirmed_during"
  echo "recovery_seconds=$RECOVERY_SECONDS drain_seconds_đo_từ_db=$DRAIN_SECONDS drained=$drained duplicates=$dup"
  echo "app_started_at trước=$started_app sau=$now_app"
  echo "worker_started_at trước=$started_worker sau=$now_worker"
  echo "mã HTTP nhận được trong sự cố:"; sort "$CODES_FILE" | uniq -c
} >> "$EVIDENCE_FILE"
rm -f "$KEYS_FILE" "$IDS_FILE" "$CODES_FILE"

summary
