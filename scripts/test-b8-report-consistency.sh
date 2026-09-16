#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Test B8 — Ràng buộc #10: job tổng hợp báo cáo chạy song song với tải giao dịch.
#
# Yêu cầu yêu cầu:
#   "việc tạo và cập nhật đơn hàng vẫn phải đáp ứng ngưỡng hiệu năng tại mục 4.
#    Báo cáo phải nhất quán với dữ liệu tại thời điểm chốt đã xác định, không
#    thiếu hoặc đếm trùng đơn hàng."
#
# Kịch bản:
#   - Chốt mốc T (cutoff).
#   - Chạy N job báo cáo song song, đồng thời bơm đơn mới liên tục.
#   - Mọi job phải trả về CÙNG order_count và CÙNG checksum, vì cùng cutoff.
#   - Đơn tạo SAU cutoff không được lọt vào báo cáo.
#   - Đo p95 của việc tạo đơn trong lúc job báo cáo đang chạy.
# ---------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
start_evidence b8-report-consistency

JOBS="${JOBS:-5}"
LOAD_ORDERS="${LOAD_ORDERS:-40}"

head1 "B8 — chốt mốc báo cáo"
CUTOFF=$(psql_q "SELECT now()")
CUTOFF_ISO=$(psql_q "SELECT to_char(now(), 'YYYY-MM-DD\"T\"HH24:MI:SS.USOF')")
say "cutoff = $CUTOFF_ISO"
baseline=$(psql_q "SELECT count(*) FROM orders WHERE status='CONFIRMED' AND created_at < timestamptz '$CUTOFF_ISO'")
say "số đơn CONFIRMED trước mốc chốt: $baseline"

head1 "Bơm $LOAD_ORDERS đơn mới trong lúc báo cáo chạy"
LOAD_LOG=$(mktemp)
(
  for i in $(seq 1 "$LOAD_ORDERS"); do
    curl -s -o /dev/null -w '%{time_total}\n' -X POST "$WEB_URL/api/orders" \
      -H 'Content-Type: application/json' -H "Idempotency-Key: b8-$(uuid)" \
      -d '{"customer_code":"CUST-0004","items":[{"sku":"GBX-001","quantity":1}]}' \
      >> "$LOAD_LOG"
    sleep 0.2
  done
) &
LOAD_PID=$!

head1 "Chạy $JOBS job báo cáo SONG SONG, cùng cutoff"
TMP=$(mktemp -d)
for j in $(seq 1 "$JOBS"); do
  ( curl -s --get "$APP_URL/reports/daily" --data-urlencode "cutoff=$CUTOFF_ISO" \
      > "$TMP/job-$j.json" ) &
done
wait "$LOAD_PID" 2>/dev/null
wait

for j in $(seq 1 "$JOBS"); do
  python3 - "$TMP/job-$j.json" "$j" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  job {sys.argv[2]}: order_count={d['order_count']:>6}  "
      f"total={float(d['total_amount']):>18,.0f}  checksum={d['checksum']}  "
      f"ran_on={d['ran_on']}")
PY
done | tee -a "$EVIDENCE_FILE"

head1 "Kiểm chứng"
counts=$(for j in $(seq 1 "$JOBS"); do
  python3 -c "import json,sys;print(json.load(open('$TMP/job-$j.json'))['order_count'])"; done | sort -u | wc -l)
sums=$(for j in $(seq 1 "$JOBS"); do
  python3 -c "import json,sys;print(json.load(open('$TMP/job-$j.json'))['checksum'])"; done | sort -u | wc -l)
ran_on=$(python3 -c "import json;print(json.load(open('$TMP/job-1.json'))['ran_on'])")
reported=$(python3 -c "import json;print(json.load(open('$TMP/job-1.json'))['order_count'])")

check "$JOBS job trả về cùng order_count"          "$counts" "1"
check "$JOBS job trả về cùng checksum"             "$sums"   "1"
check "báo cáo khớp số liệu tại mốc chốt"          "$reported" "$baseline"
check "báo cáo chạy trên read replica"             "$ran_on" "replica"

head1 "Hiệu năng tạo đơn TRONG LÚC báo cáo chạy (ràng buộc #4: p95 <= 2s)"
python3 - "$LOAD_LOG" <<'PY' | tee -a "$EVIDENCE_FILE"
import sys, statistics
vals = sorted(float(x) for x in open(sys.argv[1]) if x.strip())
if not vals:
    print("  không có số liệu"); raise SystemExit
p = lambda q: vals[min(int(len(vals) * q), len(vals) - 1)]
print(f"  n={len(vals)}  p50={p(.50)*1000:.0f}ms  p95={p(.95)*1000:.0f}ms  "
      f"p99={p(.99)*1000:.0f}ms  max={vals[-1]*1000:.0f}ms")
print(f"  NGƯỠNG p95 <= 2000ms -> {'ĐẠT' if p(.95) <= 2.0 else 'KHÔNG ĐẠT'}")
PY
p95_ok=$(python3 - "$LOAD_LOG" <<'PY'
import sys
vals = sorted(float(x) for x in open(sys.argv[1]) if x.strip())
print("yes" if vals and vals[min(int(len(vals)*.95), len(vals)-1)] <= 2.0 else "no")
PY
)
check "p95 tạo đơn <= 2s khi có job báo cáo" "$p95_ok" "yes"

head1 "Đơn tạo SAU mốc chốt không được lọt vào báo cáo"
after=$(psql_q "SELECT count(*) FROM orders WHERE idempotency_key LIKE 'b8-%' AND created_at >= timestamptz '$CUTOFF_ISO'")
say "đã tạo $after đơn sau mốc chốt; báo cáo vẫn giữ nguyên $reported đơn"
check "báo cáo không nhiễm dữ liệu sau cutoff" "$reported" "$baseline"

{ echo "--- $(ts) B8 ---"
  echo "cutoff=$CUTOFF_ISO baseline=$baseline reported=$reported jobs=$JOBS ran_on=$ran_on"
  echo "đơn tạo sau cutoff=$after  distinct_counts=$counts distinct_checksums=$sums"
} >> "$EVIDENCE_FILE"
rm -rf "$TMP" "$LOAD_LOG"

summary
