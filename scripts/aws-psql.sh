#!/usr/bin/env bash
# Chạy một câu SQL trên database của môi trường AWS, qua SSM.
#
# Vì sao phải vòng qua SSM: RDS nằm trong private subnet, laptop không nối
# thẳng được. Một instance App tier đã có sẵn quyền và đã có /etc/abc.env.
#
# Vì sao đọc /etc/abc.env bằng Python chứ không `source`: mật khẩu do Terraform
# sinh có chứa ký tự (), bash source vào là lỗi cú pháp. systemd đọc được vì nó
# không qua shell.
#
#   ./scripts/aws-psql.sh "SELECT count(*) FROM orders"
#
set -euo pipefail

SQL="${1:?Thiếu câu SQL. Ví dụ: $0 \"SELECT count(*) FROM orders\"}"
PREFIX="${PREFIX:-abc-migration-dev}"
export AWS_PROFILE="${AWS_PROFILE:-abc-migration}"
export AWS_REGION="${AWS_REGION:-ap-southeast-1}"

INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PREFIX}-app" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [ -z "$INSTANCE" ] || [ "$INSTANCE" = "None" ]; then
  echo "Không tìm thấy instance App tier nào đang chạy." >&2
  exit 1
fi

# Gửi câu SQL qua base64 để dấu nháy trong SQL không bị lớp JSON của
# send-command nuốt mất.
SQL_B64=$(printf '%s' "$SQL" | base64 -w0)

read -r -d '' RUNNER <<'PY' || true
import base64, os, sys, psycopg
env = {}
with open("/etc/abc.env") as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k] = v
sql = base64.b64decode(sys.argv[1]).decode()
with psycopg.connect(
    host=env["DB_HOST"], port=env.get("DB_PORT", "5432"),
    dbname=env["DB_NAME"], user=env["DB_USER"], password=env["DB_PASSWORD"],
    connect_timeout=5,
) as conn:
    for row in conn.execute(sql):
        print("\t".join("" if c is None else str(c) for c in row))
PY

RUNNER_B64=$(printf '%s' "$RUNNER" | base64 -w0)

CMD=$(aws ssm send-command \
  --document-name AWS-RunShellScript --instance-ids "$INSTANCE" \
  --parameters "commands=[\"echo $RUNNER_B64 | base64 -d > /tmp/q.py\",\"python3 /tmp/q.py $SQL_B64\"]" \
  --query Command.CommandId --output text)

for _ in $(seq 30); do
  sleep 2
  STATUS=$(aws ssm get-command-invocation --command-id "$CMD" \
    --instance-id "$INSTANCE" --query Status --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Success|Failed|TimedOut|Cancelled) break ;; esac
done

OUT=$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" \
        --query StandardOutputContent --output text)
ERR=$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" \
        --query StandardErrorContent --output text)

if [ "$STATUS" != "Success" ]; then
  echo "SSM: $STATUS" >&2
  [ -n "$ERR" ] && echo "$ERR" >&2
  exit 1
fi
printf '%s' "$OUT"
