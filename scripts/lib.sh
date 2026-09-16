# Hàm dùng chung cho các script test. Source từ script khác, không chạy trực tiếp.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="docker compose -f $ROOT/deploy/local/docker-compose.yml"
WEB_URL="${WEB_URL:-http://localhost:8080}"
APP_URL="${APP_URL:-http://localhost:8081}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/evidence}"

C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'

PASS_COUNT=0; FAIL_COUNT=0

ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
say()  { printf '%s[%s]%s %s\n' "$C_DIM" "$(date -u +%H:%M:%S)" "$C_0" "$*"; }
head1(){ printf '\n%s=== %s ===%s\n' "$C_B" "$*" "$C_0"; }

check() {   # check "mô tả" "giá trị thực" "giá trị mong đợi"
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    printf '  %sPASS%s  %s (=%s)\n' "$C_OK" "$C_0" "$desc" "$actual"
    PASS_COUNT=$((PASS_COUNT+1))
  else
    printf '  %sFAIL%s  %s — mong đợi %s, thực tế %s\n' "$C_ERR" "$C_0" "$desc" "$expected" "$actual"
    FAIL_COUNT=$((FAIL_COUNT+1))
  fi
}

summary() {
  printf '\n%s---------------------------------------------%s\n' "$C_DIM" "$C_0"
  printf 'Kết quả: %s%d đạt%s, %s%d không đạt%s\n' \
    "$C_OK" "$PASS_COUNT" "$C_0" \
    "$([ "$FAIL_COUNT" -gt 0 ] && echo "$C_ERR" || echo "$C_DIM")" "$FAIL_COUNT" "$C_0"
  # Dòng máy đọc cho scripts/test-all.sh. Cố ý không chứa chữ PASS/FAIL để
  # không bị chính nó đếm nhầm là một kết quả kiểm chứng.
  printf 'TESTRESULT pass=%d fail=%d\n' "$PASS_COUNT" "$FAIL_COUNT"
  [ "$FAIL_COUNT" -eq 0 ]
}

uuid() { cat /proc/sys/kernel/random/uuid; }

psql_q() { docker exec abc-db psql -U abcapp -d abcsales -tAc "$1"; }

# Tạo 1 đơn. In ra order_id. $1 = idempotency key (mặc định sinh mới).
create_order() {
  local key="${1:-$(uuid)}" cust="${2:-CUST-0001}"
  curl -s -X POST "$WEB_URL/api/orders" \
    -H 'Content-Type: application/json' -H "Idempotency-Key: $key" \
    -d "{\"customer_code\":\"$cust\",\"items\":[{\"sku\":\"BRG-001\",\"quantity\":2}]}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("order_id",""))'
}

order_status() {
  curl -s "$WEB_URL/api/orders/$1" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("status","?"))
except Exception: print("HTTP_ERROR")'
}

wait_status() {   # wait_status <order_id> <status> <timeout_giây>
  local id="$1" want="$2" limit="${3:-60}" i=0
  while [ "$i" -lt "$limit" ]; do
    [ "$(order_status "$id")" = "$want" ] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

start_evidence() {   # start_evidence <tên-test>
  mkdir -p "$EVIDENCE_DIR"
  EVIDENCE_FILE="$EVIDENCE_DIR/$1-$(date -u +%Y%m%dT%H%M%SZ).log"
  say "ghi bằng chứng vào ${EVIDENCE_FILE#"$ROOT"/}"
}
