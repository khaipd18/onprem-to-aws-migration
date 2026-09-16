#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Kiểm tra role hiện tại có đủ quyền dựng hệ thống không, KHÔNG tạo resource.
#
# Hai kỹ thuật:
#   EC2  -> --dry-run, AWS trả DryRunOperation nếu được phép.
#   Khác -> gọi thật nhưng với tham số chắc chắn sai. AWS xét quyền TRƯỚC khi
#           validate, nên AccessDenied = bị chặn, lỗi validate = có quyền.
#
# Cột KET QUA:
#   CO QUYEN   được phép
#   BI CHAN    thiếu quyền trong policy
#   ?          CLI chặn từ phía client, chưa gọi tới AWS -> chưa kết luận được
#
#   ./scripts/check-aws-permissions.sh
#   AWS_PROFILE=abc-migration AWS_REGION=ap-southeast-1 ./scripts/check-aws-permissions.sh
# ---------------------------------------------------------------------------
set -uo pipefail
export AWS_PROFILE="${AWS_PROFILE:-abc-migration}"
export AWS_REGION="${AWS_REGION:-ap-southeast-1}"
# Quyen thuong duoc cap gioi han theo ten tai nguyen. Probe PHAI dung ten
# khop prefix, khong thi se bao chan nham.
PREFIX="${PREFIX:-abc-migration-dev}"

# BAI HOC: probe cac hanh dong GHI/XOA bang ten tai nguyen THAT se thuc thi
# that. Da tung xoa nham RDS Proxy va ghi de secret. Moi probe ghi/xoa phai
# dung hau to nay, va khong bao gio trung ten tai nguyen dang chay.
PROBE="$PREFIX-zzprobe-khong-dung"

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

blocked=0
unknown=0

banner() { printf '\n\033[1m%s\033[0m\n' "$1"; }

judge() {
  # $1 = hanh dong dang test   $2 = output cua lenh aws
  #
  # Bai hoc: phai doc AWS tu choi hanh dong NAO. Neu khac voi hanh dong dang
  # test thi khong ket luan duoc. Vi du create-db-proxy bi tu choi o
  # iam:PassRole, dieu do khong noi gi ve rds:CreateDBProxy.
  local label="$1" out="$2" want denied
  want=$(cut -d' ' -f1 <<<"$label")
  # ten trong IAM khac ten dich vu o vai cho
  case "$want" in
    efs:*)     want="elasticfilesystem:${want#efs:}" ;;
    budgets:*) want="budgets:ViewBudget" ;;
  esac
  denied=$(grep -o 'to perform: [a-zA-Z0-9:_-]*' <<<"$out" | head -1 | cut -d' ' -f3)

  if grep -qiE 'Parameter validation failed|^aws: \[ERROR\]' <<<"$out"; then
    printf '  %-36s ?  (CLI chan phia client)\n' "$label"; unknown=$((unknown + 1)); return
  fi
  if [ -n "$denied" ] && [ "${denied,,}" != "${want,,}" ]; then
    printf '  %-36s ?  (bi chan o %s, khong ket luan duoc)\n' "$label" "$denied"
    unknown=$((unknown + 1)); return
  fi
  if grep -qi 'explicit deny in a service control policy' <<<"$out"; then
    printf '  %-36s BI CHAN (SCP)\n' "$label"; blocked=$((blocked + 1))
  elif grep -qiE 'AccessDenied|is not authorized|UnauthorizedOperation' <<<"$out"; then
    printf '  %-36s BI CHAN\n' "$label"; blocked=$((blocked + 1))
  else
    # Loi tham so = da qua vong kiem quyen (AWS xet quyen truoc khi validate).
    printf '  %-36s CO QUYEN\n' "$label"
  fi
}

dry() { local label="$1"; shift; judge "$label" "$("$@" --dry-run 2>&1)"; }
try() { local label="$1"; shift; judge "$label" "$("$@" 2>&1)"; }

ident=$(aws sts get-caller-identity --output json 2>&1) || { echo "$ident"; exit 1; }
echo "$ident" | sed -n 's/.*"Arn": "\(.*\)".*/danh tinh: \1/p'
echo "region  : $AWS_REGION"

VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
        --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
SUBNET=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
AMI=$(aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
        --query 'Parameters[0].Value' --output text 2>/dev/null)
ACC=$(echo "$ident" | sed -n 's/.*"Account": "\([0-9]*\)".*/\1/p')

banner "Mang va compute (module network, security, compute)"
dry ec2:CreateVpc             aws ec2 create-vpc --cidr-block 10.99.0.0/16
dry ec2:CreateSubnet          aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.99.0.0/24
dry ec2:CreateInternetGateway aws ec2 create-internet-gateway
dry ec2:CreateRouteTable      aws ec2 create-route-table --vpc-id "$VPC"
dry ec2:AllocateAddress       aws ec2 allocate-address --domain vpc
dry ec2:CreateSecurityGroup   aws ec2 create-security-group --group-name probe --description probe --vpc-id "$VPC"
dry ec2:CreateVpcEndpoint     aws ec2 create-vpc-endpoint --vpc-id "$VPC" --service-name "com.amazonaws.$AWS_REGION.ssm" --vpc-endpoint-type Interface
dry ec2:CreateLaunchTemplate  aws ec2 create-launch-template --launch-template-name probe --launch-template-data '{}'
dry ec2:RunInstances          aws ec2 run-instances --image-id "$AMI" --instance-type t4g.medium
dry ec2:CreateTags            aws ec2 create-tags --resources "$VPC" --tags Key=probe,Value=probe
try elbv2:CreateLoadBalancer  aws elbv2 create-load-balancer --name 'ten khong hop le' --subnets "$SUBNET"
try elbv2:CreateTargetGroup   aws elbv2 create-target-group --name "$PREFIX-probe" --protocol HTTP --port 8080 --vpc-id "$VPC"
try elbv2:AddTags             aws elbv2 add-tags --resource-arns "arn:aws:elasticloadbalancing:$AWS_REGION:$ACC:loadbalancer/app/x/x" --tags Key=owner,Value=khaipd18
try autoscaling:CreateASG     aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$PREFIX-probe" --min-size 1 --max-size 0 --launch-template LaunchTemplateName="$PREFIX-probe"
try autoscaling:PutWarmPool   aws autoscaling put-warm-pool --auto-scaling-group-name "$PREFIX-probe" --min-size 1
try autoscaling:PutScalingPolicy aws autoscaling put-scaling-policy --auto-scaling-group-name "$PREFIX-probe" --policy-name x --policy-type TargetTrackingScaling

banner "Danh tinh va ma hoa (module iam)"
# Ten phai HOP LE. Ten co dau cach bi AWS tra ValidationError truoc khi xet
# quyen, nen probe se bao nham la co quyen.
try iam:CreateRole            aws iam create-role --role-name "$PREFIX-probe" --assume-role-policy-document '{}'
try iam:CreateInstanceProfile aws iam create-instance-profile --instance-profile-name "$PREFIX-probe"
try iam:CreatePolicy          aws iam create-policy --policy-name "$PREFIX-probe" --policy-document '{}'
try iam:PutRolePolicy         aws iam put-role-policy --role-name "$PREFIX-probe" --policy-name x --policy-document '{}'
try iam:AttachRolePolicy      aws iam attach-role-policy --role-name "$PREFIX-probe" --policy-arn arn:aws:iam::aws:policy/"$PREFIX-probe"
try iam:TagRole               aws iam tag-role --role-name "$PREFIX-probe" --tags Key=owner,Value=khaipd18
try iam:ListRolePolicies      aws iam list-role-policies --role-name "$PREFIX-probe"
try iam:ListAttachedRolePolicies aws iam list-attached-role-policies --role-name "$PREFIX-probe"
try iam:GetInstanceProfile    aws iam get-instance-profile --instance-profile-name "$PREFIX-probe"
try kms:CreateKey             aws kms create-key --policy 'khong-phai-json'

banner "Du lieu (module data, queue)"
try rds:CreateDBInstance      aws rds create-db-instance --db-instance-identifier "$PREFIX-probe" --db-instance-class db.t4g.medium --engine postgres
try rds:CreateDBSubnetGroup   aws rds create-db-subnet-group --db-subnet-group-name "$PREFIX-probe" --db-subnet-group-description x --subnet-ids "$SUBNET"
try rds:CreateDBParameterGroup aws rds create-db-parameter-group --db-parameter-group-name "$PREFIX-probe" --db-parameter-group-family postgres16 --description x
try rds:CreateDBInstanceReadReplica aws rds create-db-instance-read-replica --db-instance-identifier "$PREFIX-probe" --source-db-instance-identifier "$PREFIX-probe"
try rds:AddTagsToResource     aws rds add-tags-to-resource --resource-name "arn:aws:rds:$AWS_REGION:$ACC:db:"$PREFIX-probe"" --tags Key=owner,Value=khaipd18
try rds:CreateDBProxy         aws rds create-db-proxy --db-proxy-name "$PREFIX-probe" --engine-family POSTGRESQL --auth '[]' --role-arn "arn:aws:iam::$ACC:role/"$PREFIX-probe"" --vpc-subnet-ids "$SUBNET"
try dynamodb:CreateTable      aws dynamodb create-table --table-name a --attribute-definitions AttributeName=k,AttributeType=S --key-schema AttributeName=k,KeyType=HASH --billing-mode PAY_PER_REQUEST
try dynamodb:DescribeTable    aws dynamodb describe-table --table-name "$PREFIX-probe"
try dynamodb:PutItem          aws dynamodb put-item --table-name "$PREFIX-probe" --item '{"k":{"S":"v"}}'
try dynamodb:TagResource      aws dynamodb tag-resource --resource-arn "arn:aws:dynamodb:$AWS_REGION:$ACC:table/"$PREFIX-probe"" --tags Key=owner,Value=khaipd18
try sqs:CreateQueue           aws sqs create-queue --queue-name "$PREFIX-orders.fifo"
try sqs:GetQueueAttributes    aws sqs get-queue-attributes --queue-url "https://sqs.$AWS_REGION.amazonaws.com/$ACC/"$PREFIX-probe""

banner "File server (module fileserver)"
try efs:CreateFileSystem      aws efs create-file-system --throughput-mode BOGUSMODE
try efs:CreateMountTarget     aws efs create-mount-target --file-system-id fs-00000000 --subnet-id "$SUBNET"
try efs:CreateAccessPoint     aws efs create-access-point --file-system-id fs-00000000
try efs:DescribeMountTargets  aws efs describe-mount-targets --file-system-id fs-00000000

banner "Container registry"
try ecr:CreateRepository      aws ecr create-repository --repository-name "$PREFIX-probe"
try ecr:DescribeRepositories  aws ecr describe-repositories --repository-names "$PREFIX-probe"

banner "Bi mat va chung chi"
try secretsmanager:CreateSecret aws secretsmanager create-secret --name x --secret-string y --kms-key-id sai
try ssm:PutParameter          aws ssm put-parameter --name 'ten sai' --value x --type SecureString
try acm:RequestCertificate    aws acm request-certificate --domain-name 'ten sai' --validation-method DNS
try acm:DescribeCertificate   aws acm describe-certificate --certificate-arn "arn:aws:acm:$AWS_REGION:$ACC:certificate/00000000-0000-0000-0000-000000000000"

banner "Chuyen doi (module migration)"
try dms:CreateReplicationInstance aws dms create-replication-instance --replication-instance-identifier "$PREFIX-probe" --replication-instance-class dms.t3.medium
try datasync:CreateLocationS3 aws datasync create-location-s3 --s3-bucket-arn arn:aws:s3:::"$PREFIX-probe" --s3-config "BucketAccessRoleArn=arn:aws:iam::$ACC:role/"$PREFIX-probe""

banner "Van hanh (module observability)"
try logs:CreateLogGroup       aws logs create-log-group --log-group-name 'ten co dau cach'
try cloudwatch:PutMetricAlarm aws cloudwatch put-metric-alarm --alarm-name probe --comparison-operator BOGUS --evaluation-periods 1
try sns:CreateTopic           aws sns create-topic --name 'ten co dau cach'
try synthetics:CreateCanary   aws synthetics create-canary --name "$PREFIX-probe" --artifact-s3-location s3://x --execution-role-arn "arn:aws:iam::$ACC:role/x" --schedule 'Expression=rate(1 minute)' --runtime-version syn-nodejs-puppeteer-9.0 --code Handler=x
try cloudtrail:CreateTrail    aws cloudtrail create-trail --name "$PREFIX-probe" --s3-bucket-name "$PREFIX-probe"
try s3:CreateBucket           aws s3api create-bucket --bucket "$PREFIX-probe-INVALID"
try s3:PutObject              aws s3api put-object --bucket "$PREFIX-probe"-abc --key x --if-none-match '*'
try ce:GetCostAndUsage        aws ce get-cost-and-usage --time-period Start=2026-09-01,End=2026-09-02 --granularity DAILY --metrics UnblendedCost
try budgets:DescribeBudgets   aws budgets describe-budgets --account-id "$ACC"

printf '\n\033[1mtong ket\033[0m  bi chan: %d   chua ket luan duoc: %d\n' "$blocked" "$unknown"
[ "$blocked" -eq 0 ]
