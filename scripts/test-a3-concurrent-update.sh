#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Test A3 — Ràng buộc #3: nhiều người cùng sửa 1 đơn, không âm thầm ghi đè.
#
# Kịch bản: 2 nhân viên cùng mở 1 đơn (cùng thấy version = N), cùng bấm lưu.
# Tiêu chí đạt: đúng 1 request thành công, request còn lại nhận HTTP 409,
#               và thay đổi của người thắng được giữ nguyên.
# ---------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
start_evidence a3-concurrent-update

head1 "A3 — chuẩn bị một đơn CONFIRMED"
OID=$(create_order)
wait_status "$OID" CONFIRMED 60 || { echo "đơn không CONFIRMED kịp"; exit 1; }
VER=$(psql_q "SELECT version FROM orders WHERE id='$OID'")
say "đơn $OID đang ở version=$VER — cả 2 user đều thấy version này"

head1 "A3a — hai request tuần tự, cùng version cũ"
r1=$(curl -s -w '\n%{http_code}' -X PUT "$WEB_URL/api/orders/$OID" \
     -H 'Content-Type: application/json' -d "{\"version\":$VER,\"status\":\"CANCELLED\"}")
r2=$(curl -s -w '\n%{http_code}' -X PUT "$WEB_URL/api/orders/$OID" \
     -H 'Content-Type: application/json' -d "{\"version\":$VER,\"status\":\"CONFIRMED\"}")
c1=$(echo "$r1" | tail -1); c2=$(echo "$r2" | tail -1)
say "user A -> HTTP $c1"; say "user B -> HTTP $c2"

final=$(psql_q "SELECT status FROM orders WHERE id='$OID'")
fver=$(psql_q "SELECT version FROM orders WHERE id='$OID'")

check "user A (lưu trước) thành công"     "$c1"    "200"
check "user B (version cũ) bị từ chối"    "$c2"    "409"
check "trạng thái cuối là của user A"     "$final" "CANCELLED"
check "version chỉ tăng đúng 1 lần"       "$fver"  "$((VER+1))"

head1 "A3b — 10 request ĐỒNG THỜI, tất cả dùng cùng version"
OID2=$(create_order)
wait_status "$OID2" CONFIRMED 60 || { echo "đơn 2 không CONFIRMED kịp"; exit 1; }
VER2=$(psql_q "SELECT version FROM orders WHERE id='$OID2'")
tmp=$(mktemp -d)
for i in $(seq 1 10); do
  ( curl -s -o /dev/null -w '%{http_code}\n' -X PUT "$WEB_URL/api/orders/$OID2" \
      -H 'Content-Type: application/json' \
      -d "{\"version\":$VER2,\"status\":\"CANCELLED\"}" > "$tmp/$i" ) &
done
wait
ok=$(grep -lc '^200$' "$tmp"/* 2>/dev/null | wc -l)
conflict=$(grep -h '^409$' "$tmp"/* 2>/dev/null | wc -l)
say "kết quả: $(cat "$tmp"/* | sort | uniq -c | tr '\n' ' ')"
check "đúng 1 request được ghi"            "$ok"       "1"
check "9 request còn lại nhận 409"         "$conflict" "9"
check "version chỉ tăng 1 sau 10 request"  "$(psql_q "SELECT version FROM orders WHERE id='$OID2'")" "$((VER2+1))"
rm -rf "$tmp"

{ echo "--- $(ts) A3 ---"
  echo "order_1=$OID version_trước=$VER  A=$c1 B=$c2 trạng_thái_cuối=$final version_cuối=$fver"
  echo "order_2=$OID2 song_song=10 thành_công=$ok conflict=$conflict"
  psql_q "SELECT event,tier,detail FROM order_events WHERE order_id='$OID2' ORDER BY id"
} >> "$EVIDENCE_FILE"

summary
