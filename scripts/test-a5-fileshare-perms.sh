#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# TEST A5 — phân quyền File Server theo phòng ban  (ràng buộc #7)
#
# Chứng minh hai nửa của yêu cầu:
#   "Người dùng không được truy cập ngoài quyền"
#     -> user phòng A đọc thư mục phòng B phải bị từ chối
#     -> user phòng A đọc thư mục phòng mình phải được
#     -> mọi user đọc được thư mục dùng chung
#
# Chạy trên NGUỒN để lấy mốc đối chiếu. Sau khi DataSync sang EFS thì chạy
# lại kịch bản tương đương trên đích rồi so hai kết quả — giống nhau nghĩa là
# giữ nguyên quyền theo phòng ban.
#
#   ./scripts/test-a5-fileshare-perms.sh
# ---------------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTAINER="${CONTAINER:-abc-onprem-files}"
DEPTS=(sales finance hr production purchasing)
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$ROOT/evidence/a5-fileshare-perms-$STAMP.log"
mkdir -p "$(dirname "$LOG")"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "container $CONTAINER chua chay."
  echo "chay: docker compose -f deploy/local/docker-compose.yml --profile onprem up -d onprem-files"
  exit 1
fi

pass=0; fail=0

check() {                      # $1 nhãn, $2 kỳ vọng (allow|deny), $3.. lệnh
  local label="$1" expect="$2"; shift 2
  local got="allow"
  docker exec -u "$1" "$CONTAINER" ls "$2" >/dev/null 2>&1 || got="deny"
  if [ "$got" = "$expect" ]; then
    printf '  OK    %-46s %s\n' "$label" "$got"; pass=$((pass+1))
  else
    printf '  FAIL  %-46s %s (mong doi %s)\n' "$label" "$got" "$expect"; fail=$((fail+1))
  fi
}

{
  echo "====================================================================="
  echo " TEST A5 — phan quyen File Server theo phong ban  (rang buoc #7)"
  echo " thoi diem: $STAMP"
  echo " nguon    : container $CONTAINER"
  echo "====================================================================="
  echo
  echo "1. User doc thu muc CUA PHONG MINH  -> phai duoc"
  for d in "${DEPTS[@]}"; do check "${d}_user -> /share/$d" allow "${d}_user" "/share/$d"; done

  echo
  echo "2. User doc thu muc PHONG KHAC  -> phai bi tu choi"
  for d in "${DEPTS[@]}"; do
    for o in "${DEPTS[@]}"; do
      [ "$d" = "$o" ] && continue
      check "${d}_user -> /share/$o" deny "${d}_user" "/share/$o"
    done
  done

  echo
  echo "3. Moi user doc thu muc DUNG CHUNG  -> phai duoc"
  for d in "${DEPTS[@]}"; do check "${d}_user -> /share/public" allow "${d}_user" "/share/public"; done

  echo
  echo "4. Quyen tren dia"
  docker exec "$CONTAINER" stat -c '  %n  uid=%u group=%G mode=%a' \
    /share/sales /share/finance /share/hr /share/production /share/purchasing /share/public 2>&1

  echo
  echo "====================================================================="
  printf ' KET QUA: %d dat, %d khong dat  -> %s\n' "$pass" "$fail" \
    "$([ "$fail" -eq 0 ] && echo DAT || echo 'KHONG DAT')"
  echo "TESTRESULT pass=$pass fail=$fail"
  echo "====================================================================="
} 2>&1 | tee "$LOG"

echo
echo "bang chung: ${LOG#"$ROOT"/}"
[ "$fail" -eq 0 ]
