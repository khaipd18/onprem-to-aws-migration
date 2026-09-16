#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bang chung SCP cap Organization chan rds:CreateDBInstanceReadReplica.
# KHONG tao resource nao: moi lenh deu dung lai o vong kiem quyen hoac o loi
# thieu tham so.
#
#   ./scripts/check-scp-rds.sh                  # in ra man hinh
#   ./scripts/check-scp-rds.sh | tee out.log    # luu lai lam bang chung
# ---------------------------------------------------------------------------
set -uo pipefail
export AWS_PROFILE="${AWS_PROFILE:-abc-migration}"
export AWS_REGION="${AWS_REGION:-ap-southeast-1}"
PREFIX="${PREFIX:-abc-migration-dev}"

# Chan chay nham tai khoan. AWS_PROFILE co san trong shell se de len mac dinh
# abc-migration, ma profile default tro sang tai khoan ca nhan.
EXPECTED_ACCOUNT="${EXPECTED_ACCOUNT:-123456789012}"
ACTUAL_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$ACTUAL_ACCOUNT" ]; then
  echo "Khong lay duoc danh tinh AWS. Kiem tra profile '$AWS_PROFILE'." >&2
  exit 1
fi
if [ -n "$EXPECTED_ACCOUNT" ] && [ "$ACTUAL_ACCOUNT" != "$EXPECTED_ACCOUNT" ]; then
  echo "DUNG LAI: profile '$AWS_PROFILE' tro sang account $ACTUAL_ACCOUNT," >&2
  echo "          mong doi $EXPECTED_ACCOUNT." >&2
  echo "          Chay lai voi AWS_PROFILE=abc-migration, hoac dat EXPECTED_ACCOUNT= de bo qua." >&2
  exit 1
fi

run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; }

echo "====================================================================="
echo " SCP chan rds:CreateDBInstanceReadReplica"
echo " $(date -u +%Y-%m-%dT%H:%M:%SZ)  profile=$AWS_PROFILE  region=$AWS_REGION"
echo "====================================================================="

run aws sts get-caller-identity

echo; echo "--- 1. Tao read replica: bi chan boi SCP ---"
run aws rds create-db-instance-read-replica \
  --db-instance-identifier "$PREFIX-db-replica" \
  --source-db-instance-identifier "$PREFIX-db"

echo; echo "--- 2. Doi chung: db.t4g.micro di qua duoc vong kiem quyen ---"
run aws rds create-db-instance \
  --db-instance-identifier "$PREFIX-probe" \
  --db-instance-class db.t4g.micro --engine postgres

echo; echo "--- 3. Doi chung: db.r6g.4xlarge bi chinh SCP do chan ---"
run aws rds create-db-instance \
  --db-instance-identifier "$PREFIX-probe2" \
  --db-instance-class db.r6g.4xlarge --engine postgres \
  --master-username u --master-user-password Abcd12345678

echo; echo "--- 4. Khong doc duoc noi dung SCP ---"
run aws organizations describe-policy --policy-id p-zvb9d6hn

cat <<'TXT'

--- Ket luan ---
Policy p-zvb9d6hn (org o-eevgice2ll, account 210987654321) lam hai viec:
  a) cam thang rds:CreateDBInstanceReadReplica  -> muc 1
  b) gioi han instance class duoc phep          -> muc 2 qua, muc 3 chan

"explicit deny in a service control policy" khac han "no identity-based
policy allows": SCP la chan o cap Organization, IT cua account
123456789012 khong go duoc.
TXT
