#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# TEST A1 — chuyển đổi có giao dịch đang chạy   (ràng buộc #2)
#
# Yêu cầu:
#   "Chuyển đổi với giao dịch đang chạy: downtime không quá 15 phút, không mất
#    giao dịch đã xác nhận và không tạo đơn trùng."
#
# Kịch bản: dựng logical replication từ PostgreSQL nguồn sang đích, vừa chạy
# vừa sinh đơn liên tục ở nguồn, rồi cutover và BẤM GIỜ khoảng ngừng.
#
# Vì sao dùng logical replication gốc chứ không dùng DMS: nguồn và đích đều là
# PostgreSQL nên đây là đường đơn giản hơn, và nó chạy được ngay cả khi chưa
# được cấp quyền dms:*. Cơ chế giống hệt DMS (full load + CDC), nên số đo ở
# đây vẫn đại diện được.
#
#   ./scripts/test-a1-migration-cutover.sh
#   WRITERS=4 DURATION=60 ./scripts/test-a1-migration-cutover.sh
# ---------------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SRC=${SRC:-abc-onprem-db}
DST=${DST:-abc-db}
SRC_APP=${SRC_APP:-http://localhost:18081}
DST_APP=${DST_APP:-http://localhost:8080}
WRITERS=${WRITERS:-3}
DURATION=${DURATION:-45}
DOWNTIME_BUDGET=${DOWNTIME_BUDGET:-900}     # 15 phút, theo yêu cầu

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$ROOT/evidence/a1-migration-cutover-$STAMP.log"
mkdir -p "$(dirname "$LOG")"

psrc() { docker exec "$SRC" psql -U abcapp -d abcsales -tAc "$1" 2>&1; }
pdst() { docker exec "$DST" psql -U abcapp -d abcsales -tAc "$1" 2>&1; }
now()  { date -u +%s.%N; }

cleanup() {
  [ -n "${WRITER_PIDS:-}" ] && kill $WRITER_PIDS 2>/dev/null
  pdst "DROP SUBSCRIPTION IF EXISTS abc_sub" >/dev/null 2>&1
  psrc "DROP PUBLICATION IF EXISTS abc_pub"  >/dev/null 2>&1
}
trap cleanup EXIT

exec > >(tee "$LOG") 2>&1

echo "====================================================================="
echo " TEST A1 — chuyen doi co giao dich dang chay   (rang buoc #2)"
echo " thoi diem : $STAMP"
echo " nguon     : $SRC        dich : $DST"
echo " ngan sach downtime: ${DOWNTIME_BUDGET}s"
echo "====================================================================="

for c in "$SRC" "$DST"; do
  docker ps --format '{{.Names}}' | grep -qx "$c" || {
    echo "container $c chua chay."
    echo "chay: docker compose -f deploy/local/docker-compose.yml --profile onprem up -d"
    exit 1
  }
done

echo
echo "--- 1. Don o nguon truoc khi bat dau -------------------------------"
SRC_BEFORE=$(psrc "select count(*) from orders where status='CONFIRMED'")
echo "  nguon co $SRC_BEFORE don CONFIRMED"

echo
echo "--- 2. Don dep dich va dung replication -----------------------------"
cleanup
pdst "TRUNCATE order_events, order_items, orders, products, customers RESTART IDENTITY CASCADE" >/dev/null
echo "  da xoa du lieu cu o dich"

psrc "CREATE PUBLICATION abc_pub FOR TABLE customers, products, orders, order_items, order_events" >/dev/null
echo "  da tao publication o nguon"

pdst "CREATE SUBSCRIPTION abc_sub
      CONNECTION 'host=$SRC port=5432 dbname=abcsales user=abcapp password=abcapp'
      PUBLICATION abc_pub WITH (copy_data = true, streaming = on)" >/dev/null
echo "  da tao subscription o dich — dang full load"

echo
echo "--- 3. Cho full load xong -------------------------------------------"
for i in $(seq 1 60); do
  ST=$(pdst "select srsubstate from pg_subscription_rel r
             join pg_subscription s on s.oid = r.srsubid
             where s.subname='abc_sub' and srsubstate <> 'r'" | tr -d '\n')
  [ -z "$ST" ] && break
  sleep 1
done
DST_AFTER_LOAD=$(pdst "select count(*) from orders")
echo "  full load xong sau ${i}s, dich co $DST_AFTER_LOAD don"

echo
echo "--- 4. Sinh don lien tuc o nguon trong ${DURATION}s ------------------"
WRITER_LOG=$(mktemp)
WRITER_PIDS=""
for w in $(seq 1 "$WRITERS"); do
  (
    END=$(( $(date +%s) + DURATION ))
    n=0
    while [ "$(date +%s)" -lt "$END" ]; do
      n=$((n+1))
      code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$SRC_APP/orders" \
        -H 'Content-Type: application/json' \
        -H "Idempotency-Key: cutover-$STAMP-$w-$n" \
        -d '{"customer_code":"CUST-0001","items":[{"sku":"BRG-001","quantity":1}]}')
      echo "$code" >> "$WRITER_LOG"
      sleep 0.15
    done
  ) &
  WRITER_PIDS="$WRITER_PIDS $!"
done
echo "  $WRITERS luong dang ghi vao nguon..."
sleep $(( DURATION / 2 ))
LAG_MID=$(psrc "select coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn),0)::bigint
                from pg_replication_slots where slot_name='abc_sub'")
echo "  giua chung: do tre replication ${LAG_MID} byte"
wait $WRITER_PIDS 2>/dev/null
WRITER_PIDS=""

WROTE_OK=$(grep -c '^20[01]$' "$WRITER_LOG" 2>/dev/null || echo 0)
WROTE_ALL=$(wc -l < "$WRITER_LOG")
echo "  da gui $WROTE_ALL request, $WROTE_OK duoc chap nhan"
rm -f "$WRITER_LOG"

echo
echo "--- 5. CUTOVER ------------------------------------------------------"
T0=$(now)
docker stop "${SRC_APP_CONTAINER:-abc-onprem-app}" >/dev/null
echo "  t0: da ngung ghi o nguon"

for i in $(seq 1 300); do
  LAG=$(psrc "select coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn),0)::bigint
              from pg_replication_slots where slot_name='abc_sub'" | tr -d '\n ')
  [ "${LAG:-1}" = "0" ] && break
  sleep 0.5
done
echo "  do tre ve 0 sau ${i} vong kiem tra"

# Logical replication KHONG chuyen sequence. Bo qua buoc nay thi ban ghi dau
# tien viet o dich se dung lai id da ton tai -> vi pham khoa chinh, va he thong
# gay ngay giay dau sau cutover.
#
# Quet MOI sequence chu khong liet ke tay: schema nay co 5 bang dung BIGSERIAL
# (customers, products, order_items, order_events, report_runs). Liet ke tay thi
# them mot bang moi la quen mot sequence, va loi chi lo ra sau khi cutover xong.
SEQ_FIXED=$(docker exec "$DST" psql -U abcapp -d abcsales -tAc "
DO \$\$
DECLARE r record; m bigint; n int := 0;
BEGIN
  FOR r IN
    SELECT c.oid::regclass AS tbl, a.attname AS col,
           pg_get_serial_sequence(c.oid::regclass::text, a.attname) AS seq
    FROM pg_class c
    JOIN pg_attribute a ON a.attrelid = c.oid
    WHERE c.relkind = 'r'
      AND c.relnamespace = 'public'::regnamespace
      AND a.attnum > 0 AND NOT a.attisdropped
      AND pg_get_serial_sequence(c.oid::regclass::text, a.attname) IS NOT NULL
  LOOP
    EXECUTE format('SELECT COALESCE(MAX(%I),0) FROM %s', r.col, r.tbl) INTO m;
    PERFORM setval(r.seq, m + 1, false);
    n := n + 1;
  END LOOP;
  RAISE NOTICE '%', n;
END \$\$;" 2>&1 | grep -oE '[0-9]+$' | tail -1)
echo "  da dat lai ${SEQ_FIXED:-?} sequence o dich"

pdst "ALTER SUBSCRIPTION abc_sub DISABLE" >/dev/null
T1=$(now)
DOWNTIME=$(awk "BEGIN{printf \"%.1f\", $T1 - $T0}")
echo "  t1: dich san sang nhan ghi"

echo
echo "--- 6. Dich co ghi duoc that khong ----------------------------------"
# Doi chieu so lieu THOI thi chua du. He thong co the khop tung con so ma van
# khong ghi duoc ban ghi tiep theo — dung cai bay sequence o buoc 5. Nen phai
# ghi that mot don qua duong ung dung roi cho no len CONFIRMED.
SMOKE_KEY="cutover-smoke-$STAMP"
SMOKE_ID=$(curl -s -X POST "$DST_APP/api/orders" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $SMOKE_KEY" \
  -d '{"customer_code":"CUST-0001","items":[{"sku":"BRG-001","quantity":1}]}' \
  | sed -n 's/.*"order_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

SMOKE_STATUS="KHONG_TAO_DUOC"
if [ -n "$SMOKE_ID" ]; then
  for i in $(seq 1 20); do
    SMOKE_STATUS=$(curl -s "$DST_APP/api/orders/$SMOKE_ID" \
      | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ "$SMOKE_STATUS" = "CONFIRMED" ] && break
    sleep 1
  done
fi
printf '  don thu sau cutover : %s (%s)\n' "${SMOKE_ID:-khong co}" "$SMOKE_STATUS"

WORKER_ERR=$(docker logs --since 60s abc-sales-worker-1 2>&1 | grep -c '"level": "ERROR"')
printf '  loi worker 60s qua  : %s\n' "$WORKER_ERR"

echo
echo "--- 7. Doi chieu -----------------------------------------------------"
SRC_FINAL=$(psrc "select count(*) from orders where status='CONFIRMED'")
DST_FINAL=$(pdst "select count(*) from orders where status='CONFIRMED'
                  and idempotency_key <> '$SMOKE_KEY'")
DUP_NO=$(pdst  "select count(*) from (select order_no from orders group by order_no having count(*)>1) x")
DUP_KEY=$(pdst "select count(*) from (select idempotency_key from orders group by idempotency_key having count(*)>1) x")
SRC_SUM=$(psrc "select coalesce(sum(total_amount),0)::text from orders where status='CONFIRMED'")
DST_SUM=$(pdst "select coalesce(sum(total_amount),0)::text from orders where status='CONFIRMED'
                and idempotency_key <> '$SMOKE_KEY'")

printf '  don CONFIRMED o nguon : %s\n' "$SRC_FINAL"
printf '  don CONFIRMED o dich  : %s\n' "$DST_FINAL"
printf '  tong tien nguon       : %s\n' "$SRC_SUM"
printf '  tong tien dich        : %s\n' "$DST_SUM"
printf '  order_no trung        : %s\n' "$DUP_NO"
printf '  idempotency_key trung : %s\n' "$DUP_KEY"

fail=0
[ "$SMOKE_STATUS" = "CONFIRMED" ] || { echo "  FAIL: dich khong ghi duoc don moi sau cutover"; fail=1; }
[ "${WORKER_ERR:-0}" -eq 0 ]      || { echo "  FAIL: worker bao loi sau cutover"; fail=1; }
[ "$SRC_FINAL" = "$DST_FINAL" ] || { echo "  FAIL: so don khong khop -> MAT GIAO DICH"; fail=1; }
[ "$SRC_SUM" = "$DST_SUM" ]     || { echo "  FAIL: tong tien khong khop"; fail=1; }
[ "$DUP_NO" = "0" ]             || { echo "  FAIL: co order_no trung"; fail=1; }
[ "$DUP_KEY" = "0" ]            || { echo "  FAIL: co idempotency_key trung"; fail=1; }
awk "BEGIN{exit !($DOWNTIME <= $DOWNTIME_BUDGET)}" || { echo "  FAIL: downtime vuot ngan sach"; fail=1; }

CHECKS=7
echo
echo "====================================================================="
printf ' DOWNTIME : %ss   (ngan sach %ss)\n' "$DOWNTIME" "$DOWNTIME_BUDGET"
printf ' KET QUA  : %s\n' "$([ "$fail" -eq 0 ] && echo DAT || echo 'KHONG DAT')"
echo "TESTRESULT pass=$((CHECKS - fail)) fail=$fail"
echo "====================================================================="
echo
echo "bang chung: ${LOG#"$ROOT"/}"

docker start abc-onprem-app >/dev/null 2>&1
exit "$fail"
