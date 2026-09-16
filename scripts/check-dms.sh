#!/usr/bin/env bash
# Kiem tra da duoc cap dms:* chua. KHONG tao resource nao.
#   ./scripts/check-dms.sh
set -uo pipefail
export AWS_PROFILE="${AWS_PROFILE:-abc-migration}"
export AWS_REGION="${AWS_REGION:-ap-southeast-1}"

EXPECTED_ACCOUNT="${EXPECTED_ACCOUNT:-123456789012}"
ACC=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -n "$EXPECTED_ACCOUNT" ] && [ "$ACC" != "$EXPECTED_ACCOUNT" ]; then
  echo "DUNG LAI: profile '$AWS_PROFILE' tro sang account $ACC, mong doi $EXPECTED_ACCOUNT." >&2
  exit 1
fi

v() { printf '  %-36s ' "$1"; shift
  o=$("$@" 2>&1)
  d=$(grep -o 'to perform: [a-zA-Z0-9:_-]*' <<<"$o" | head -1 | cut -d' ' -f3)
  if grep -qiE 'AccessDenied|not authorized' <<<"$o"; then echo "CHAN  <- $d"
  else echo "CO QUYEN"; fi; }

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  account $ACC  profile $AWS_PROFILE"
echo "--- DMS ---"
v dms:DescribeReplicationInstances aws dms describe-replication-instances
v dms:DescribeEndpoints            aws dms describe-endpoints
v dms:CreateReplicationInstance    aws dms create-replication-instance --replication-instance-identifier probe --replication-instance-class dms.t3.micro
v dms:CreateEndpoint               aws dms create-endpoint --endpoint-identifier probe --endpoint-type source --engine-name postgres
v dms:CreateReplicationTask        aws dms create-replication-task --replication-task-identifier probe --source-endpoint-arn x --target-endpoint-arn y --replication-instance-arn z --migration-type full-load --table-mappings '{}'
echo "--- DataSync (de so sanh) ---"
v datasync:ListLocations           aws datasync list-locations
