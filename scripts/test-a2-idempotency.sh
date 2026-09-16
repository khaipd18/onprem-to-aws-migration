#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Test A2 — Ràng buộc #3: gửi lại cùng Idempotency-Key không tạo đơn trùng.
#
# Kịch bản: người dùng bấm "Gửi đơn", mạng chậm, họ bấm thêm 4 lần nữa.
# Tiêu chí đạt: đúng 1 đơn được tạo; các lần sau trả về cùng order_id.
# ---------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
start_evidence a2-idempotency

REPEAT="${REPEAT:-5}"
KEY="$(uuid)"
BODY='{"customer_code":"CUST-0002","items":[{"sku":"MTR-001","quantity":4},{"sku":"VLV-002","quantity":2}]}'

head1 "A2 — gửi lại $REPEAT lần cùng Idempotency-Key"
say "Idempotency-Key = $KEY"

# Ghi ra file thay vì pipe sang tee: pipe khiến vòng lặp chạy trong subshell
# và mọi biến gán bên trong sẽ mất khi vòng lặp kết thúc.
IDS_FILE=$(mktemp)
for i in $(seq 1 "$REPEAT"); do
  resp=$(curl -s -w '\n%{http_code}' -X POST "$WEB_URL/api/orders" \
    -H 'Content-Type: application/json' -H "Idempotency-Key: $KEY" -d "$BODY")
  code=$(echo "$resp" | tail -1)
  oid=$(echo "$resp" | head -1 | python3 -c 'import sys,json;print(json.load(sys.stdin).get("order_id",""))')
  dedup=$(echo "$resp" | head -1 | python3 -c 'import sys,json;print(json.load(sys.stdin).get("deduplicated"))')
  line=$(printf '  lần %d: HTTP %s  order_id=%s  deduplicated=%s' "$i" "$code" "${oid:0:8}" "$dedup")
  echo "$line"; echo "$line" >> "$EVIDENCE_FILE"
  echo "$oid" >> "$IDS_FILE"
done

sleep 3
distinct=$(sort -u "$IDS_FILE" | grep -c .)
rm -f "$IDS_FILE"
in_db=$(psql_q "SELECT count(*) FROM orders WHERE idempotency_key='$KEY'")
accepted=$(docker exec abc-queue-db psql -U abcapp -d abcqueue -tAc \
           "SELECT count(*) FROM order_accept WHERE idempotency_key='$KEY'")

head1 "Kiểm chứng"
check "số order_id khác nhau trả về client" "$distinct" "1"
check "số dòng trong bảng orders"            "$in_db"    "1"
check "số bản ghi trong accept store"        "$accepted" "1"

{ echo "--- $(ts) A2 ---"
  echo "key=$KEY distinct_ids=$distinct rows_in_orders=$in_db accept_rows=$accepted"
  psql_q "SELECT id,order_no,status,version,total_amount FROM orders WHERE idempotency_key='$KEY'"
} >> "$EVIDENCE_FILE"

summary
