#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bật / tắt môi trường AWS để không trả tiền cho máy chạy không.
#
# Tài khoản có trần 350 USD/tháng cho TOÀN BỘ resource, dùng chung với người
# khác. Chạy liên tục hết khoảng 207 USD — quá nửa trần. Chạy 8 giờ mỗi ngày
# làm việc thì còn khoảng 50.
#
# Phần lớn chi phí tính theo giờ, nên tắt là hết:
#   ASG          desired = 0        không mất dữ liệu
#   RDS          stop               tối đa 7 ngày, chỉ còn tiền lưu trữ
#   NAT Gateway  xoá                dựng lại mất ~2 phút
#
# KHÔNG dùng terraform destroy để tắt: nó xoá cả RDS và mất hết dữ liệu test.
#
#   ./scripts/aws-env.sh down     tắt, còn ~13 USD/tháng tiền lưu trữ
#   ./scripts/aws-env.sh up       bật lại, mất ~5 phút
#   ./scripts/aws-env.sh status   xem đang chạy gì và tốn bao nhiêu
# ---------------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="$ROOT/deploy/terraform"

export AWS_PROFILE="${AWS_PROFILE:-abc-migration}"
export AWS_REGION="${AWS_REGION:-ap-southeast-1}"
PREFIX="${PREFIX:-abc-migration-dev}"

# Script nay HA ASG ve 0, DUNG RDS va XOA NAT. Chay nham tai khoan la dung
# ha tang that cua nguoi khac, nen chan truoc.
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

DB="$PREFIX-db"
# KHONG dat ten bien nay la GROUPS: do la bien dac biet cua bash, chua danh
# sach group id cua user dang chay. Gan de len no bi bo qua am tham, va vong
# lap se chay tren cac GID that.
# Kien truc SPA chi con mot ASG. Truoc day co them "$PREFIX-web".
ASG_NAMES=("$PREFIX-app")

# Giá ước tính theo giờ, ap-southeast-1. Chua xac nhan bang Pricing Calculator.
RATE_PER_HOUR="0.28"

asg_set() {
  for g in "${ASG_NAMES[@]}"; do
    aws autoscaling update-auto-scaling-group \
      --auto-scaling-group-name "$g" \
      --min-size "$1" --desired-capacity "$2" 2>/dev/null \
      && printf '  %-28s min=%s desired=%s\n' "$g" "$1" "$2" \
      || printf '  %-28s (chua ton tai)\n' "$g"
  done
}

case "${1:-status}" in

  down)
    echo "TAT moi truong"
    echo
    echo "1. Auto Scaling Group ve 0"
    asg_set 0 0

    echo
    echo "2. Dung RDS"
    if aws rds stop-db-instance --db-instance-identifier "$DB" >/dev/null 2>&1; then
      echo "  $DB dang dung lai (mat vai phut)"
      echo "  luu y: RDS tu bat lai sau 7 ngay, chay lai lenh nay neu con nghi lau"
    else
      STATE=$(aws rds describe-db-instances --db-instance-identifier "$DB" \
                --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)
      echo "  $DB: ${STATE:-chua ton tai}"
    fi

    echo
    echo "3. Xoa NAT Gateway"
    echo "  chay: cd deploy/terraform && terraform destroy \\"
    echo "          -target=module.network.aws_nat_gateway.this -target=module.network.aws_eip.nat"
    echo "  (chi xoa NAT va EIP, cac route tro vao NAT bi xoa theo; RDS va du lieu khong bi dong)"
    echo "  (dat rieng vi no thay doi state, khong nen chay ngam)"
    ;;

  up)
    echo "BAT moi truong"
    echo
    echo "1. Khoi dong RDS"
    aws rds start-db-instance --db-instance-identifier "$DB" >/dev/null 2>&1 \
      && echo "  $DB dang khoi dong (~3-5 phut)" \
      || echo "  $DB da chay hoac chua ton tai"

    echo
    echo "2. NAT Gateway"
    echo "  chay: cd deploy/terraform && terraform apply"

    echo
    echo "3. Auto Scaling Group ve muc thuong"
    echo "  chay lenh nay LAI sau khi RDS available, vi instance doc"
    echo "  Parameter Store va noi DB ngay luc boot:"
    echo "      ./scripts/aws-env.sh scale"
    ;;

  scale)
    echo "Dua Auto Scaling Group ve muc thuong"
    asg_set 2 2
    ;;

  status)
    echo "TRANG THAI  ($AWS_PROFILE @ $AWS_REGION)"
    echo
    RUNNING=0

    echo "Auto Scaling Group"
    for g in "${ASG_NAMES[@]}"; do
      LINE=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$g" \
        --query 'AutoScalingGroups[0].[DesiredCapacity,length(Instances)]' \
        --output text 2>/dev/null)
      if [ -n "$LINE" ] && [ "$LINE" != "None" ]; then
        D=$(echo "$LINE" | cut -f1); N=$(echo "$LINE" | cut -f2)
        printf '  %-28s desired=%s dang chay=%s\n' "$g" "$D" "$N"
        RUNNING=$((RUNNING + ${N:-0}))
      else
        printf '  %-28s chua ton tai\n' "$g"
      fi
    done

    echo
    echo "RDS"
    STATE=$(aws rds describe-db-instances --db-instance-identifier "$DB" \
              --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)
    printf '  %-28s %s\n' "$DB" "${STATE:-chua ton tai}"

    echo
    echo "NAT Gateway"
    # Loc theo tag owner: tai khoan dung chung voi nguoi khac, dem het thi
    # tinh nham ca NAT cua ho.
    NAT=$(aws ec2 describe-nat-gateways \
      --filter Name=state,Values=available Name=tag:owner,Values=khaipd18 \
      --query 'length(NatGateways)' --output text 2>/dev/null)
    NAT_ALL=$(aws ec2 describe-nat-gateways \
      --filter Name=state,Values=available \
      --query 'length(NatGateways)' --output text 2>/dev/null)
    printf '  %-28s %s cua minh  (%s trong ca tai khoan)\n' \
      "dang chay" "${NAT:-0}" "${NAT_ALL:-0}"

    echo
    if [ "$RUNNING" -gt 0 ] || [ "${STATE:-}" = "available" ] || [ "${NAT:-0}" -gt 0 ]; then
      echo "  => Dang TINH TIEN, khoang $RATE_PER_HOUR USD moi gio"
      echo "     de qua dem 16 gio ~ $(awk "BEGIN{printf \"%.1f\", $RATE_PER_HOUR*16}") USD"
      echo "     tat bang: ./scripts/aws-env.sh down"
    else
      echo "  => Da tat. Chi con tien luu tru, khoang 13 USD/thang."
    fi
    ;;

  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
