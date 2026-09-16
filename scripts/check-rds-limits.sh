#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Do xem SCP va identity policy cho phep gi tren RDS.
# KHONG tao resource: moi lenh dung lai o vong kiem quyen hoac loi tham so.
#
#   ./scripts/check-rds-limits.sh
#   ./scripts/check-rds-limits.sh | tee evidence/rds-limits-$(date -u +%Y%m%dT%H%M%SZ).log
# ---------------------------------------------------------------------------
set -uo pipefail
export AWS_PROFILE="${AWS_PROFILE:-abc-migration}"
export AWS_REGION="${AWS_REGION:-ap-southeast-1}"
PREFIX="${PREFIX:-abc-migration-dev}"
PW=Abcd12345678

EXPECTED_ACCOUNT="${EXPECTED_ACCOUNT:-123456789012}"
ACTUAL_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$ACTUAL_ACCOUNT" ]; then
  echo "Khong lay duoc danh tinh AWS. Kiem tra profile '$AWS_PROFILE'." >&2; exit 1
fi
if [ -n "$EXPECTED_ACCOUNT" ] && [ "$ACTUAL_ACCOUNT" != "$EXPECTED_ACCOUNT" ]; then
  echo "DUNG LAI: profile '$AWS_PROFILE' tro sang account $ACTUAL_ACCOUNT, mong doi $EXPECTED_ACCOUNT." >&2
  exit 1
fi

verdict() {
  # $1 = hanh dong dang test   $2 = output
  # So hanh dong bi tu choi voi hanh dong dang test. Lech nhau -> khong ket luan.
  local want="$1" out="$2" denied
  denied=$(grep -o 'to perform: [a-zA-Z0-9:_-]*' <<<"$out" | head -1 | cut -d' ' -f3)
  if [ -n "$denied" ] && [ -n "$want" ] && [ "$denied" != "$want" ]; then
    echo "? chan o $denied, khong ket luan duoc"; return
  fi
  if grep -q 'service control policy' <<<"$out"; then echo "SCP CHAN"
  elif grep -qiE 'AccessDenied|not authorized' <<<"$out"; then echo "THIEU QUYEN"
  else echo "CHO PHEP"; fi
}

echo "====================================================================="
echo " Gioi han RDS  |  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " account $ACTUAL_ACCOUNT  profile $AWS_PROFILE  region $AWS_REGION"
echo "====================================================================="

echo; echo "--- 1. Read replica ---"
out=$(aws rds create-db-instance-read-replica \
  --db-instance-identifier "$PREFIX-db-replica" \
  --source-db-instance-identifier "$PREFIX-db" 2>&1)
printf '  %-34s %s\n' "CreateDBInstanceReadReplica" "$(verdict rds:CreateDBInstanceReadReplica "$out")"

echo; echo "--- 2. Instance class nao duoc phep ---"
for c in db.t4g.micro db.t4g.small db.t4g.medium db.t4g.large db.t4g.2xlarge \
         db.m6g.large db.m6g.xlarge db.m6g.2xlarge db.m6g.4xlarge \
         db.r6g.large db.r6g.2xlarge db.r6g.4xlarge; do
  out=$(aws rds create-db-instance --db-instance-identifier "$PREFIX-probe" \
        --db-instance-class "$c" --engine postgres \
        --master-username u --master-user-password "$PW" 2>&1)
  printf '  %-34s %s\n' "$c" "$(verdict rds:CreateDBInstance "$out")"
done

echo; echo "--- 3. Cac hanh dong RDS khac ---"
probe() { printf '  %-34s %s\n' "$1" "$(verdict "rds:$1" "$2")"; }
probe "CreateDBSubnetGroup"   "$(aws rds create-db-subnet-group --db-subnet-group-name p --db-subnet-group-description d --subnet-ids subnet-0 2>&1)"
probe "CreateDBParameterGroup" "$(aws rds create-db-parameter-group --db-parameter-group-name p --db-parameter-group-family postgres16 --description d 2>&1)"
probe "CreateDBSnapshot"      "$(aws rds create-db-snapshot --db-snapshot-identifier p --db-instance-identifier q 2>&1)"
probe "RestoreDBInstanceToPointInTime" "$(aws rds restore-db-instance-to-point-in-time --target-db-instance-identifier p --source-db-instance-identifier q --use-latest-restorable-time 2>&1)"
probe "CreateDBProxy"         "$(aws rds create-db-proxy --db-proxy-name p --engine-family POSTGRESQL --role-arn "arn:aws:iam::$ACTUAL_ACCOUNT:role/x" --vpc-subnet-ids subnet-0 --auth Description=d 2>&1)"
probe "CreateDBCluster"       "$(aws rds create-db-cluster --db-cluster-identifier p --engine postgres --db-cluster-instance-class db.m6g.large --allocated-storage 100 --storage-type io1 --iops 1000 --master-username u --master-user-password "$PW" 2>&1)"
