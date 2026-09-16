#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Chạy toàn bộ ma trận test và xuất một báo cáo tổng hợp.
#
#   bash scripts/test-all.sh              # bộ nhanh (~4 phút), bỏ qua B4 180s
#   FULL=1 bash scripts/test-all.sh       # bộ đầy đủ, B4 chạy đủ 3 phút
#
# Mọi bằng chứng ghi vào evidence/. Đây là thứ nộp kèm báo cáo cuối kỳ.
# ---------------------------------------------------------------------------
set -uo pipefail
source "$(dirname "$0")/lib.sh"

FULL="${FULL:-0}"
mkdir -p "$EVIDENCE_DIR"
REPORT="$EVIDENCE_DIR/test-report-$(date -u +%Y%m%dT%H%M%SZ).txt"

TOTAL_PASS=0; TOTAL_FAIL=0; RESULTS=""

run_test() {   # run_test <mã> <mô tả> <script> [env...]
  local id="$1" desc="$2" script="$3"; shift 3
  head1 "$id — $desc"
  local out
  out=$(env "$@" bash "$ROOT/scripts/$script" 2>&1)
  echo "$out"
  echo "===== $id — $desc =====" >> "$REPORT"
  echo "$out" | sed 's/\x1b\[[0-9;]*m//g' >> "$REPORT"
  echo >> "$REPORT"
  # Đọc từ dòng TESTRESULT do summary() in ra, không đếm chuỗi "PASS"/"FAIL"
  # trong output — dòng tổng kết của mỗi test cũng chứa hai chữ đó.
  local line p f
  line=$(echo "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -o 'TESTRESULT pass=[0-9]* fail=[0-9]*' | tail -1)
  p=$(echo "$line" | sed -n 's/.*pass=\([0-9]*\).*/\1/p'); p=${p:-0}
  f=$(echo "$line" | sed -n 's/.*fail=\([0-9]*\).*/\1/p'); f=${f:-1}
  TOTAL_PASS=$((TOTAL_PASS + p)); TOTAL_FAIL=$((TOTAL_FAIL + f))
  RESULTS="$RESULTS$(printf '  %-4s %-54s %s' "$id" "$desc" \
    "$([ "$f" -eq 0 ] && echo "ĐẠT ($p/$p)" || echo "KHÔNG ĐẠT ($f/$((p+f)))")")\n"
}

echo "Báo cáo kiểm thử — $(ts)" > "$REPORT"
echo "Môi trường: local docker compose" >> "$REPORT"
echo >> "$REPORT"

# A1 và A5 cần profile onprem. Bỏ qua thay vì tính là trượt, để bộ test vẫn
# chạy được khi chỉ dựng phía AWS.
if docker ps --format '{{.Names}}' | grep -qx abc-onprem-db; then
  run_test A1 "Cutover có giao dịch đang chạy (ràng buộc #2)" test-a1-migration-cutover.sh
else
  say "bỏ qua A1 — chưa dựng profile onprem"
  RESULTS="$RESULTS$(printf '  %-4s %-54s %s' A1 "Cutover có giao dịch đang chạy (ràng buộc #2)" "BỎ QUA")\n"
fi

if docker ps --format '{{.Names}}' | grep -qx abc-onprem-files; then
  run_test A5 "Phân quyền File Server theo phòng ban (ràng buộc #7)" test-a5-fileshare-perms.sh
else
  say "bỏ qua A5 — chưa dựng profile onprem"
  RESULTS="$RESULTS$(printf '  %-4s %-54s %s' A5 "Phân quyền File Server theo phòng ban (ràng buộc #7)" "BỎ QUA")\n"
fi

run_test A2 "Không tạo đơn trùng khi gửi lại (ràng buộc #3)" test-a2-idempotency.sh
run_test A3 "Không âm thầm ghi đè khi cùng sửa (ràng buộc #3)" test-a3-concurrent-update.sh
run_test B8 "Báo cáo nhất quán + p95 khi chạy song song (#10)" test-b8-report-consistency.sh

if [ "$FULL" = "1" ]; then
  run_test B4 "DB mất kết nối 3 phút, tự hồi phục (#5)" test-b4-db-outage.sh \
    OUTAGE_SECONDS=180 ORDERS_DURING=12
else
  run_test B4 "DB mất kết nối 60s, tự hồi phục (#5, bản rút gọn)" test-b4-db-outage.sh \
    OUTAGE_SECONDS=60 ORDERS_DURING=6
  say "chạy FULL=1 để test đủ 180 giây như yêu cầu yêu cầu"
fi

head1 "TỔNG HỢP"
printf "$RESULTS"
printf '\n  Tổng: %d PASS, %d FAIL\n' "$TOTAL_PASS" "$TOTAL_FAIL"
printf '  Báo cáo đầy đủ: %s\n' "${REPORT#"$ROOT"/}"
{ echo "===== TỔNG HỢP ====="; printf "$RESULTS"
  printf '\nTổng: %d PASS, %d FAIL\n' "$TOTAL_PASS" "$TOTAL_FAIL"; } >> "$REPORT"

[ "$TOTAL_FAIL" -eq 0 ]
