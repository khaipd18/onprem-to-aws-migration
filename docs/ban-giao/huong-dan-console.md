# Triển khai trên AWS Console — theo thứ tự

Đường chính của dự án là **Terraform** (`deploy/terraform/`), đã dựng thật
**165 tài nguyên** và destroy sạch ngày 2026-09-11. Tài liệu này phục vụ hai việc khác:

1. **Phương án dự phòng** khi role chưa được cấp đủ quyền để `terraform apply`, hoặc khi chỉ có Console.
2. **Bản đồ đối chiếu** — mỗi bước dưới đây ứng với một module Terraform, dùng để kiểm tra bằng mắt xem Terraform đã dựng đúng thứ mình nghĩ chưa.

Mọi tên, cổng, kích cỡ trong tài liệu này lấy từ giá trị mặc định của Terraform. Sửa một bên thì phải sửa bên kia.

Danh sách service: [`danh-sach-dich-vu.md`](danh-sach-dich-vu.md) · Thông số: [`thong-so-ky-thuat.md`](thong-so-ky-thuat.md) · Kiến trúc từng module: [`deploy/terraform/README.md`](../../deploy/terraform/README.md)

Region: **`ap-southeast-1`** — chọn đúng region ở góc trên bên phải **trước mọi thao tác**.

---

## Quy ước tên

Terraform ghép tên từ `<project>-<environment>`, mặc định là **`abc-migration-dev`**. Dưới đây viết tắt là `<prefix>`.

Mọi tài nguyên phải có tag **`owner = khaipd18`**. Console không có `default_tags`, nên khi bấm tay **phải gõ tag ở từng màn hình tạo**. Đây là chỗ dễ sót nhất khi làm Console.

Ba bucket S3 có hậu tố account id vì tên bucket là namespace toàn cầu, tài khoản lại dùng chung với người khác:

```
<prefix>-assets-<account-id>       SPA tĩnh
<prefix>-artifacts-<account-id>    gói ứng dụng instance tải lúc boot
<prefix>-alb-logs-<account-id>     access log của ALB
```

---

## Bấm tay thì mất bao lâu

Terraform dựng 165 tài nguyên hết khoảng **20 phút**, phần lớn là chờ RDS. Bấm
tay thì lâu hơn nhiều vì phải điền từng ô:

| Giai đoạn | Bấm | Chờ |
|---|---|---|
| Mạng, security group | 20 phút | — |
| IAM | 15 phút | — |
| RDS | 10 phút | 15 phút |
| SQS, DynamoDB | 15 phút | — |
| Compute | 45 phút | 5 phút |
| Front-end | 20 phút | 15 phút |
| EFS, RDS Proxy | 30 phút | — |
| Observability | 30 phút | — |
| **Tổng** | **~3 giờ** | **~35 phút** |

Con số này giải thích vì sao đường chính là Terraform. Bấm tay chỉ dùng khi
thiếu quyền chạy Terraform, hoặc để đối chiếu xem Terraform đã tạo đúng chưa.

---

## Nguyên tắc: bấm thứ CHẬM trước rồi đi làm việc khác

| Tài nguyên | Thời gian tạo |
|---|---|
| RDS Multi-AZ | **10–20 phút** |
| CloudFront distribution | **5–15 phút** (Deploying → Enabled) |
| DMS replication instance | ~10 phút |
| ALB | ~3 phút |
| EFS + mount target | ~2 phút |

Bấm **Giai đoạn 3 (RDS)** rồi làm tiếp giai đoạn 4, 5 trong lúc chờ. Làm tuần tự mất trắng gần hai tiếng.

---

# Những chỗ vấp khi dựng thật

Phần này rút từ lần dựng thật ngày 2026-09-11: 165 tài nguyên, apply và destroy
đều sạch. Toàn bộ là thứ chỉ lộ ra khi bấm, không đọc tài liệu nào biết trước.

## 1. Hai role DMS phải có TRƯỚC, tên cố định

Tạo replication instance mà chưa có hai role này thì báo:

```
AccessDeniedFault: The IAM Role arn:aws:iam::<account>:role/dms-vpc-role
is not configured properly.
```

Đọc như thiếu quyền nhưng thực ra là **thiếu role**. Tạo trước, tên phải đúng
từng chữ:

| Role | Gắn policy |
|---|---|
| `dms-vpc-role` | `AmazonDMSVPCManagementRole` |
| `dms-cloudwatch-logs-role` | `AmazonDMSCloudWatchLogsRole` |

Trust policy: service `dms.amazonaws.com`.

Tạo xong **chờ 1–2 phút** rồi mới tạo replication instance — IAM cần thời gian
lan truyền, tạo ngay vẫn báo lỗi cũ.

Hai role này dùng chung cả tài khoản, không có prefix riêng. Nếu bạn khác đã
tạo rồi thì đừng tạo lại, cũng đừng xoá khi dọn môi trường của mình.

## 2. Không tạo KMS key — mỗi dịch vụ dùng key mặc định

Hệ thống này **không tạo customer managed key**. Mỗi dịch vụ dùng key mặc định
của nó, dữ liệu **vẫn mã hoá at-rest** ở mọi chỗ:

| Dịch vụ | Key dùng | Bấm gì trong Console |
|---|---|---|
| RDS | `aws/rds` | Encryption: bật, để nguyên key mặc định |
| SQS | SQS-owned | Encryption: chọn **SSE-SQS**, không phải SSE-KMS |
| DynamoDB | AWS owned | Để nguyên mặc định, không hiện key trong Console |
| EFS | `aws/elasticfilesystem` | Encryption: bật, để nguyên key mặc định |
| SSM SecureString | `aws/ssm` | Chọn type SecureString, KMS key để mặc định |
| Secrets Manager | `aws/secretsmanager` | Encryption key: để mặc định |

Mất gì: không sửa được key policy, không tự đặt chu kỳ xoay vòng, và mỗi dịch vụ
một key riêng thay vì một key chung.

Được gì: không cần thêm quyền nào, không tốn 1 USD/tháng, và **dọn được sạch**.
Xoá CMK cần `kms:ScheduleKeyDeletion` — quyền không nằm trong nhóm tạo key, nên
lần dựng ngày 12/09/2026 để lại hai key mồ côi không xoá nổi.

## 3. Metric filter: `dimensions` và `default value` loại trừ nhau

Ở màn hình tạo metric filter, điền cả hai thì AWS từ chối:

```
InvalidParameterException: Invalid metric transformation:
dimensions and default value are mutually exclusive properties
```

Muốn tách metric theo tier thì để trống ô **Default value**.

## 4. Tên SQS FIFO

Tên phải kết thúc bằng `.fifo` **và** bật ô FIFO. Thiếu một trong hai:

```
Can only include alphanumeric characters, hyphens, or underscores
```

## 5. RDS Multi-AZ đi qua bốn trạng thái

Bấm Create xong đừng tưởng treo. Thứ tự và thời gian thực đo:

```
creating  →  modifying  →  configuring-enhanced-monitoring  →  backing-up  →  available
                 ↑
          lâu nhất, ~8 phút: AWS dựng single-AZ trước rồi mới nhân bản sang AZ thứ hai
```

Tổng khoảng **12–15 phút**. Trong lúc `modifying`, cột Multi-AZ vẫn hiện `No` —
bình thường, nó bật lên `Yes` ở cuối.

## 6. Xoá RDS Proxy rồi tạo lại mất thêm 5 phút

Proxy chuyển sang `DELETING` và không tạo lại được cho tới khi biến mất hẳn. Xoá
nhầm là mất 5 phút chờ.

## 7. Thứ tự xoá của SQS

Xoá queue xong AWS khoá tên đó **60 giây**, tạo lại ngay sẽ lỗi. Chờ rồi hẵng
làm.

---

# GIAI ĐOẠN 0 — Trước khi tiêu đồng nào (10 phút)

### 0.1 Kiểm tra CloudShell

Bấm icon terminal ở thanh trên cùng Console.

```bash
aws sts get-caller-identity
```

Ra `assumed-role/...` → có CLI mà không cần access key. Nếu mở được, cân nhắc chạy thẳng Terraform từ CloudShell thay vì bấm tay.

### 0.2 Ngân sách

Budget và cảnh báo chi phí là thiết lập ở cấp tài khoản, do phía công ty quản lý — không tạo ở đây. Phần ước tính và theo dõi chi phí của nhóm nằm ở [`chi-phi.md`](chi-phi.md) và [`chi-phi-ngay-tuan.md`](chi-phi-ngay-tuan.md).

Cần nhớ một con số: tài khoản có trần **350 USD/tháng cho toàn bộ resource**, dùng chung với người khác. Cấu hình trong tài liệu này rơi vào khoảng **208 USD/tháng nếu chạy liên tục**. Không dùng thì hạ xuống bằng `./scripts/aws-env.sh down`.

### 0.3 Cost Explorer

**Billing → Cost Explorer → Enable**. Mất tới 24 giờ mới có dữ liệu, nên bật ngay hôm nay để cuối kỳ có số liệu lọc theo tag `owner` cho ràng buộc #9.

---

# GIAI ĐOẠN 1 — Mạng (20 phút) → `modules/network`

### 1.1 Tạo VPC bằng wizard

**VPC → Create VPC → chọn "VPC and more"** (không chọn "VPC only")

| Trường | Giá trị |
|---|---|
| Name tag | `<prefix>` |
| IPv4 CIDR | `10.0.0.0/16` |
| Availability Zones | **2** |
| Public subnets | **2** |
| Private subnets | **4** |
| NAT gateways | **In 1 AZ** |
| VPC endpoints | **S3 Gateway** |
| DNS hostnames / DNS resolution | bật cả hai |

Một lần bấm ra VPC + 6 subnet + IGW + NAT + route table + S3 endpoint.

**NAT một cái, không phải hai.** Rẻ hơn khoảng 43 USD/tháng. Đánh đổi: AZ chứa NAT chết thì cả hai AZ mất đường ra internet — không ảnh hưởng luồng nhận đơn, vì traffic vào đi qua ALB chứ không qua NAT.

### 1.2 Đặt lại tên subnet

**VPC → Subnets** → sửa tag `Name` cho khớp Terraform:

| Tầng | Tên | CIDR |
|---|---|---|
| public | `<prefix>-public-ap-southeast-1a` / `-1b` | `10.0.0.0/24`, `10.0.1.0/24` |
| private | `<prefix>-private-ap-southeast-1a` / `-1b` | `10.0.10.0/24`, `10.0.11.0/24` |
| data | `<prefix>-data-ap-southeast-1a` / `-1b` | `10.0.20.0/24`, `10.0.21.0/24` |

### 1.3 Sửa route table của tầng data

Wizard tạo 4 private subnet với route ra NAT. **Hai subnet `data-*` không được có route đó.**

**VPC → Route tables → Create route table** → tên `<prefix>-rt-data`, VPC vừa tạo, **không thêm route nào** → **Subnet associations** → gắn hai subnet `data-*`.

Điều phân biệt tầng `private` với tầng `data` là route table, không phải cái tên. Để chung thì RDS có đường ra internet, mất hẳn tính tách biệt.

### 1.4 Tạo Security Group — TẠO RỖNG TRƯỚC

**EC2 → Security Groups → Create security group** — tạo đủ **6 cái**, phần Inbound để trống:

`<prefix>-sg-alb-public` · `<prefix>-sg-app` · `<prefix>-sg-rds-proxy` · `<prefix>-sg-rds` · `<prefix>-sg-fileserver` · `<prefix>-sg-admin-client`

> **Bẫy:** các SG tham chiếu lẫn nhau. Vừa tạo vừa thêm rule sẽ báo "group does not exist". Tạo hết rồi mới thêm rule.

### 1.5 Thêm rule

| SG | Type | Port | Source |
|---|---|---|---|
| `sg-alb-public` | HTTP | 80 | `0.0.0.0/0`, hoặc prefix list CloudFront `pl-31a34658` |
| `sg-app` | Custom TCP | **8080** | `sg-alb-public` |
| `sg-rds-proxy` | PostgreSQL | 5432 | `sg-app` |
| `sg-rds` | PostgreSQL | 5432 | `sg-rds-proxy` |
| `sg-rds` | PostgreSQL | 5432 | `sg-app` |
| `sg-fileserver` | NFS | 2049 | `sg-app` |
| `sg-fileserver` | NFS | 2049 | `sg-admin-client` |
| `sg-admin-client` | — | — | **không có rule vào** |

Chọn **source là SG khác**, không phải dải CIDR. Đây là điểm người review sẽ nhìn.

Vài điểm hay bị hỏi:

- **Chỉ có port 80, không có 443.** CloudFront chấm dứt TLS ở edge rồi gọi origin bằng HTTP. Tài khoản không có quyền ACM nên ALB không gắn được chứng chỉ. Khi nào có ACM thì thêm listener 443 và đổi `origin_protocol_policy` sang `https-only`.
- **`sg-rds` có hai nguồn.** Đường chính là qua RDS Proxy. Đường từ `sg-app` là dự phòng cho môi trường chưa dựng proxy và để chẩn đoán.
- **`sg-admin-client` không có rule vào mà vẫn cần.** Nó tồn tại để **được tham chiếu làm nguồn** — máy trạm quản trị gắn nó vào, rồi EFS mở 2049 cho nó.

**Không tạo rule SSH port 22 nào cả** — dùng Session Manager.

---

# GIAI ĐOẠN 2 — IAM (15 phút) → `modules/iam`

Không có bước tạo KMS key. Xem mục 2 ở đầu tài liệu để biết mỗi dịch vụ dùng key
nào.

### 2.1 Role cho EC2

**IAM → Roles → Create role → AWS service → EC2** → tên **`<prefix>-instance`**

Gắn 2 managed policy:

```
AmazonSSMManagedInstanceCore     Session Manager, không cần SSH
CloudWatchAgentServerPolicy      đẩy metric và log
```

Thêm 1 inline policy — thay `<account-id>` bằng số tài khoản thật:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow",
     "Action":["sqs:SendMessage","sqs:ReceiveMessage","sqs:DeleteMessage",
               "sqs:ChangeMessageVisibility","sqs:GetQueueAttributes","sqs:GetQueueUrl"],
     "Resource":"arn:aws:sqs:ap-southeast-1:<account-id>:abc-migration-dev-*"},
    {"Effect":"Allow",
     "Action":["dynamodb:PutItem","dynamodb:GetItem","dynamodb:UpdateItem",
               "dynamodb:Query","dynamodb:ConditionCheckItem"],
     "Resource":"arn:aws:dynamodb:ap-southeast-1:<account-id>:table/abc-migration-dev-*"},
    {"Effect":"Allow",
     "Action":["ssm:GetParameter","ssm:GetParameters","ssm:GetParametersByPath"],
     "Resource":"arn:aws:ssm:ap-southeast-1:<account-id>:parameter/abc-migration-dev/*"},
    {"Effect":"Allow",
     "Action":["s3:GetObject","s3:ListBucket"],
     "Resource":["arn:aws:s3:::abc-migration-dev-artifacts-<account-id>",
                 "arn:aws:s3:::abc-migration-dev-artifacts-<account-id>/*"]},
    {"Effect":"Allow",
     "Action":["kms:Decrypt","kms:GenerateDataKey"],
     "Resource":"*",
     "Condition":{"StringEquals":{"kms:ViaService":[
       "ssm.ap-southeast-1.amazonaws.com","sqs.ap-southeast-1.amazonaws.com",
       "dynamodb.ap-southeast-1.amazonaws.com","s3.ap-southeast-1.amazonaws.com"]}}}
  ]
}
```

> Bản chuẩn của policy này nằm ở `deploy/terraform/modules/iam/main.tf`, khối `data "aws_iam_policy_document" "instance"`. Nếu hai chỗ lệch nhau thì tin file Terraform.

**Chỉ một role, không phải ba.** Kiến trúc SPA không còn Web tier chạy EC2, và worker chạy chung instance với App tier, nên chỉ còn một loại máy.

### 2.2 Role cho RDS Proxy

Tạo ở bước 6.1 — Console cho phép bấm **Create new IAM role** ngay trong màn hình tạo proxy, tiện hơn tạo trước.

---

# GIAI ĐOẠN 3 — Bấm RDS rồi để đó (10 phút bấm, 20 phút chờ) → `modules/data`

**RDS → Databases → Create database**

> Chọn **Standard create**, KHÔNG chọn Easy create — Easy create không cho bật Multi-AZ.

| Trường | Giá trị |
|---|---|
| Engine | PostgreSQL **16.10** |
| Template | Production |
| Availability | **Multi-AZ DB instance** |
| DB identifier | `<prefix>-db` |
| Master username | `abcapp` |
| Credentials management | **Managed in AWS Secrets Manager** |
| Instance class | **`db.t4g.micro`** |
| Storage | gp3, **20 GB**, autoscaling max **100 GB** |
| VPC | VPC vừa tạo |
| Subnet group | tạo mới từ 2 subnet `data-*` |
| Public access | **No** |
| Security group | `<prefix>-sg-rds` |
| Encryption | bật, key mặc định `aws/rds` |
| Initial database name | `abcsales` |
| Backup retention | **7 ngày**, cửa sổ `17:00-18:00` UTC |
| Maintenance window | `sun:18:30-sun:19:30` UTC |
| Performance Insights | bật |
| Deletion protection | bật |
| Log exports | `postgresql`, `upgrade` |

**Create database** → đi làm việc khác.

### 3.1 Parameter group

**RDS → Parameter groups → Create** → family `postgres16`, tên `<prefix>-pg16`. Đặt 5 tham số:

| Tham số | Giá trị | Áp dụng | Lý do |
|---|---|---|---|
| `rds.force_ssl` | `1` | pending-reboot | Từ chối kết nối không mã hoá |
| `rds.logical_replication` | `1` | pending-reboot | Cần cho cutover bằng logical replication |
| `log_min_duration_statement` | `500` | immediate | Log mọi câu chạy quá 500 ms — nguồn để truy p95 (#4) |
| `log_lock_waits` | `1` | immediate | Log phiên chờ khoá — dấu hiệu báo cáo chặn OLTP (#10) |
| `idle_in_transaction_session_timeout` | `60000` | immediate | Cắt phiên mở transaction rồi bỏ đó quá 60 giây |

Hai tham số đầu là static, gắn xong phải **Reboot** instance mới có hiệu lực.

### 3.2 Parameter Store

Ứng dụng đọc cấu hình từ Parameter Store, không hardcode. **Systems Manager → Parameter Store → Create parameter** ×5:

| Tên | Loại | Giá trị |
|---|---|---|
| `/<prefix>/db/host` | String | endpoint của **RDS Proxy** (điền lại sau bước 6.1) |
| `/<prefix>/db/port` | String | `5432` |
| `/<prefix>/db/name` | String | `abcsales` |
| `/<prefix>/db/user` | String | `abcapp` |
| `/<prefix>/db/password` | **SecureString**, key `aws/ssm` | mật khẩu master |

---

# GIAI ĐOẠN 4 — Messaging (15 phút) → `modules/queue`

### 4.1 SQS — DLQ TRƯỚC

**SQS → Create queue** → Type **FIFO**, name `<prefix>-orders-dlq.fifo`

| Trường | Giá trị |
|---|---|
| Message retention | **14 ngày** (tối đa) |
| Encryption | **SSE-SQS** (key do SQS quản lý) |

14 ngày để có đủ thời gian điều tra rồi redrive lại.

### 4.2 SQS — queue chính

**SQS → Create queue**

| Trường | Giá trị |
|---|---|
| Type | **FIFO** |
| Name | `<prefix>-orders.fifo` |
| Visibility timeout | **180** giây |
| Message retention | **14 ngày** |
| Receive message wait time | **20** giây (long polling) |
| Content-based deduplication | **tắt** — app tự gửi `MessageDeduplicationId` |
| **Deduplication scope** | **Message group** |
| **FIFO throughput limit** | **Per message group ID** |
| Encryption | **SSE-SQS** (key do SQS quản lý) |
| Dead-letter queue | bật → `<prefix>-orders-dlq.fifo`, **Maximum receives = 5** |

> **Hai ô "Deduplication scope" và "FIFO throughput limit" phải đổi cùng nhau**, bật một cái AWS từ chối. Mặc định FIFO chỉ 300 message/giây trên toàn queue; đặt theo message group thì lên 3.000. Vì `MessageGroupId` là mã khách hàng nên các khách khác nhau không chờ nhau — đây là phần đáp ứng ràng buộc #4.

Ở màn hình DLQ, bật thêm **Redrive allow policy → By queue** và chọn queue chính, để sau này đẩy ngược message về được.

**Copy lại cả hai Queue URL** — cần cho user data.

### 4.3 DynamoDB — accept store

**DynamoDB → Tables → Create table**

| Trường | Giá trị |
|---|---|
| Table name | `<prefix>-accept` |
| Partition key | **`idempotency_key`** — String |
| Sort key | không có |
| Table settings | Customize → **On-demand** |
| Encryption | **Owned by Amazon DynamoDB** (mặc định) |

Tạo xong, vào tab **Indexes → Create index**:

| Trường | Giá trị |
|---|---|
| Index name | **`order_id-index`** |
| Partition key | `order_id` — String |
| Projection | **All** |

Rồi **Additional settings → Time to Live → Enable**, attribute **`expires_at`**.

> Ba tên này do ứng dụng gọi cứng trong `app/common/store.py`: partition key `idempotency_key`, index `order_id-index`, thuộc tính TTL `expires_at`. Đặt sai tên là app chạy nhưng hỏng ở đúng lúc cần nhất.

**Vì sao DynamoDB chứ không phải một bảng trong RDS:** bản ghi "đã nhận đơn" phải đọc được **khi RDS chết**. Đó là cách `GET /orders/{id}` trả `PENDING` thay vì 404 hay 500 trong suốt 3 phút mất kết nối — client biết đơn chưa thành công chứ không nhận thông báo thành công giả (ràng buộc #5).

---

# GIAI ĐOẠN 5 — Compute (45 phút) → `modules/compute`

### 5.1 Bucket artifact và bucket log

**S3 → Create bucket** ×2:

| Bucket | Thiết lập |
|---|---|
| `<prefix>-artifacts-<account-id>` | Block all public access, **Versioning bật**, SSE-S3 |
| `<prefix>-alb-logs-<account-id>` | Block all public access, lifecycle xoá sau 30 ngày |

Bucket log cần bucket policy cho phép tài khoản ELB của region ghi vào. Console tự đề nghị policy này khi bật access log ở bước 5.3 — bấm đồng ý.

Versioning trên bucket artifact cho phép rollback bằng cách trỏ `current.txt` về mã cũ.

### 5.2 Đóng gói artifact

Không dùng ECR. Ứng dụng là một tiến trình Python chạy thẳng trên OS bằng systemd — đúng chất migration, và không phải cài Docker daemon lên mỗi instance chỉ để chạy một tiến trình.

Chạy trong **CloudShell**:

```bash
git clone <repo> && cd ecv_final_task
VERSION=$(git rev-parse --short HEAD)
BUCKET=abc-migration-dev-artifacts-$(aws sts get-caller-identity --query Account --output text)

tar czf app-$VERSION.tar.gz app/
aws s3 cp app-$VERSION.tar.gz s3://$BUCKET/app-$VERSION.tar.gz
echo "$VERSION" > current.txt
aws s3 cp current.txt s3://$BUCKET/current.txt
```

Tên file mang mã commit nên bất biến và có phiên bản. Rollback = sửa `current.txt` rồi thay instance.

### 5.3 ALB public

**EC2 → Load Balancers → Create → Application Load Balancer**

| Trường | Giá trị |
|---|---|
| Name | `<prefix>-public` |
| Scheme | **Internet-facing** |
| VPC / Subnets | 2 subnet `public-*` |
| Security group | `<prefix>-sg-alb-public` |
| Listener | HTTP **80** → forward `<prefix>-app` (tạo ở 5.4) |
| Attributes → Access logs | bật, bucket `<prefix>-alb-logs-<account-id>`, prefix `public` |
| Attributes → Drop invalid header fields | **bật** |
| Attributes → Idle timeout | 60 giây |

**Chỉ một ALB.** Kiến trúc SPA không còn ALB internal: CloudFront gọi thẳng ALB này cho `/api/*`, ALB chuyển xuống App tier.

**Copy DNS name** — cần cho CloudFront ở giai đoạn 6.

### 5.4 Target group

**EC2 → Target Groups → Create target group**

| Trường | Giá trị |
|---|---|
| Target type | Instances |
| Name | `<prefix>-app` |
| Protocol / Port | HTTP **8080** |
| Health check path | **`/ready`** |
| Success codes | `200` |
| Interval | **10** giây |
| Timeout | 5 giây |
| Healthy / Unhealthy threshold | **2 / 2** |
| Deregistration delay | **30** giây (mặc định 300 — phải đổi) |

> **Health check phải là `/ready`, KHÔNG phải `/health`.** Đây là bẫy dễ mắc nhất trong cả bài.
>
> `/health` chạm tới database. Nếu ALB kiểm endpoint đó thì lúc RDS chết 3 phút, **mọi** instance rớt health check, ALB rút sạch target, và ASG với `health_check_type = ELB` sẽ terminate rồi tạo máy mới — máy mới cũng hỏng y hệt vì database vẫn chưa lên. Test B4 fail, ràng buộc #5 fail.
>
> `/ready` chỉ khẳng định tiến trình còn nhận được request. Việc database không truy cập được do chính ứng dụng xử lý: trả 503 trung thực, đưa đơn vào SQS, không báo thành công giả.
>
> `/health` vẫn hữu ích — dùng để chẩn đoán tay và làm nguồn cho alarm, chỉ là không gắn vào target group.

### 5.5 Launch template

**EC2 → Launch Templates → Create launch template**

| Trường | Giá trị |
|---|---|
| Name | `<prefix>-app` |
| AMI | **Amazon Linux 2023 (arm64)** |
| Instance type | **`t4g.small`** |
| Key pair | **không cần** — Session Manager |
| Subnet | không chọn, ASG quyết |
| Security group | `<prefix>-sg-app` |
| Advanced → IAM instance profile | `<prefix>-instance` |
| Advanced → Metadata version | **IMDSv2 required** |
| Advanced → Resource tags | gắn `owner=khaipd18` cho **cả ba**: Instances, Volumes, Network interfaces |

> **Ô "Resource tags" là chỗ Console dễ sót nhất.** Tag của launch template không tự chảy xuống instance, EBS volume và ENI mà nó tạo — phải khai riêng cho từng loại. Terraform giải quyết bằng `tag_specifications`; ở Console là ba dòng trong mục Resource tags.

Graviton (`t4g`) rẻ hơn khoảng 20% so với `t3` và ứng dụng là Python thuần nên không vướng kiến trúc.

**Advanced details → User data:**

```bash
#!/bin/bash
set -eux
REGION=ap-southeast-1
PREFIX=abc-migration-dev
ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region $REGION)
BUCKET=$PREFIX-artifacts-$ACCOUNT

dnf install -y python3.12 python3.12-pip

VERSION=$(aws s3 cp s3://$BUCKET/current.txt - --region $REGION)
aws s3 cp s3://$BUCKET/app-$VERSION.tar.gz /tmp/app.tar.gz --region $REGION
mkdir -p /opt/abc && tar xzf /tmp/app.tar.gz -C /opt/abc --strip-components=1
python3.12 -m venv /opt/abc/.venv
/opt/abc/.venv/bin/pip install --no-cache-dir -r /opt/abc/requirements.txt

get() { aws ssm get-parameter --region $REGION --name "/$PREFIX/$1" \
          --with-decryption --query Parameter.Value --output text; }

TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

cat >/etc/abc.env <<EOF
APP_ENV=aws
AWS_REGION=$REGION
INSTANCE_ID=$IID
DB_HOST=$(get db/host)
DB_PORT=$(get db/port)
DB_NAME=$(get db/name)
DB_USER=$(get db/user)
DB_PASSWORD=$(get db/password)
DB_SSLMODE=require
QUEUE_DRIVER=sqs
SQS_QUEUE_URL=<dán Queue URL ở bước 4.2>
SQS_DLQ_URL=<dán DLQ URL ở bước 4.1>
VISIBILITY_TIMEOUT=180
MAX_RECEIVE_COUNT=5
ACCEPT_STORE_DRIVER=dynamodb
DDB_ACCEPT_TABLE=$PREFIX-accept
ALLOWED_ORIGINS=
WORKER_BATCH=10
EOF
chmod 600 /etc/abc.env

unit() {   # unit <ten> <mo ta> <lenh> <tier>
  cat >/etc/systemd/system/$1.service <<EOF
[Unit]
Description=$2
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/abc
EnvironmentFile=/etc/abc.env
Environment=TIER=$4
ExecStart=$3
Restart=always
RestartSec=3
User=ec2-user

[Install]
WantedBy=multi-user.target
EOF
}

unit abc-app    "ABC Sales app tier" \
     "/opt/abc/.venv/bin/uvicorn appapi.main:app --host 0.0.0.0 --port 8080" app
unit abc-worker "ABC Sales worker" \
     "/opt/abc/.venv/bin/python -u worker/main.py" worker

systemctl daemon-reload
systemctl enable --now abc-app abc-worker

dnf install -y amazon-cloudwatch-agent
cat >/opt/aws/amazon-cloudwatch-agent/etc/cfg.json <<EOF
{"logs":{"logs_collected":{"files":{"collect_list":[
  {"file_path":"/var/log/messages","log_group_name":"/$PREFIX/app",
   "log_stream_name":"{instance_id}"}]}}}}
EOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/cfg.json
```

> **TUYỆT ĐỐI không set `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`.** Bê nguyên block env từ `docker-compose.yml` sang thì giá trị giả `test` đè lên IAM role và mọi lời gọi SQS/DynamoDB/S3 báo `InvalidClientTokenId`.

> **Một launch template, hai systemd unit.** App tier và worker chạy chung máy. Ở quy mô này tách ASG riêng cho worker chỉ tốn thêm 2 instance mà không giải quyết vấn đề gì — nếu sau này worker cần scale độc lập thì tách.

> `ALLOWED_ORIGINS` để **trống**. CloudFront phục vụ cả trang lẫn `/api/*` nên trình duyệt gọi cùng một origin, không cần CORS. Chỉ điền khi mở trang từ nơi khác.

### 5.6 Auto Scaling group

**EC2 → Auto Scaling Groups → Create Auto Scaling group**

| Trường | Giá trị |
|---|---|
| Name | `<prefix>-app` |
| Launch template | `<prefix>-app` |
| Subnets | 2 subnet **`private-*`** |
| Load balancing | **Attach to existing** → target group `<prefix>-app` |
| Health check type | **ELB** |
| Health check grace period | **120** giây |
| Desired / Min / Max | **2 / 2 / 6** |
| AZ distribution | Balanced best effort |
| Tags | `owner=khaipd18`, `Name=<prefix>-app`, **Tag new instances = bật** |

Sau khi tạo:

**Automatic scaling → Create dynamic scaling policy**
- Target tracking, metric **Application Load Balancer request count per target**
- Target group `<prefix>-app`, target value **600** *(đo lại bằng k6 rồi chỉnh)*

**Instance management → Warm pool → Create warm pool**
- Min size **2**, state **Stopped**, **Reuse on scale in** bật

> Warm pool giữ 2 máy ở trạng thái Stopped — chỉ tính tiền EBS, khoảng 0,6 USD/tháng cho 8 GB, không tính giờ chạy. Scale out từ máy stopped mất 30–40 giây thay vì 2–3 phút. Ràng buộc #4 yêu cầu gián đoạn ≤ 2 phút; đây là cách đạt con số đó mà không trả tiền cho máy chạy không.

> **Bẫy:** tạo ASG khi ALB chưa `active` thì instance bị đánh unhealthy rồi ASG giết liên tục, rất khó debug. Chờ ALB xong hẳn.

---

# GIAI ĐOẠN 6 — Front-end (20 phút bấm, 15 phút chờ) → `modules/static` + `modules/cdn`

### 6.1 Bucket chứa SPA

**S3 → Create bucket** → `<prefix>-assets-<account-id>`

| Trường | Giá trị |
|---|---|
| Block all public access | **bật hết** |
| Object Ownership | Bucket owner enforced |
| Versioning | bật |
| Encryption | SSE-S3 |

**Không bật Static website hosting.** Endpoint đó chỉ chạy HTTP và bắt buộc bucket public. Ở đây bucket đóng hoàn toàn, CloudFront ký request bằng Origin Access Control để đọc.

Build và đẩy SPA lên:

```bash
./scripts/build-spa.sh
aws s3 sync build/spa/ s3://abc-migration-dev-assets-<account-id>/
```

> Kiểm lại `Content-Type` của `index.html` phải là `text/html`. Sai thành `application/octet-stream` thì trình duyệt tải file về thay vì hiển thị.

### 6.2 CloudFront distribution

**CloudFront → Create distribution**

**Origin 1 — bucket SPA:**

| Trường | Giá trị |
|---|---|
| Origin domain | `<prefix>-assets-<account-id>.s3.ap-southeast-1.amazonaws.com` |
| Origin access | **Origin access control settings** → Create new OAC |
| | Sau khi tạo, CloudFront hiện nút **Copy policy** → dán vào bucket policy |

**Origin 2 — ALB:**

| Trường | Giá trị |
|---|---|
| Origin domain | DNS name của `<prefix>-public` |
| Protocol | **HTTP only** (ALB chưa có chứng chỉ) |

**Default behavior** → origin là bucket SPA:

| Trường | Giá trị |
|---|---|
| Viewer protocol policy | **Redirect HTTP to HTTPS** |
| Allowed methods | GET, HEAD, OPTIONS |
| Cache policy | **CachingOptimized** |
| Origin request policy | **CORS-S3Origin** |
| Compress objects | bật |

**Thêm behavior `/api/*`** → origin là ALB:

| Trường | Giá trị |
|---|---|
| Path pattern | `/api/*` |
| Viewer protocol policy | Redirect HTTP to HTTPS |
| Allowed methods | **GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE** |
| Cache policy | **CachingDisabled** |
| Origin request policy | **AllViewerExceptHostHeader** |

> `CachingDisabled` cho `/api/*` là bắt buộc. Cache một POST tạo đơn hoặc một GET trạng thái đơn thì người dùng thấy dữ liệu cũ — vi phạm ràng buộc #3.
>
> `AllViewerExceptHostHeader` chuyển tiếp toàn bộ header, cookie, query string xuống ALB **trừ** `Host`. Header `Idempotency-Key` mà ứng dụng dùng để chống đơn trùng đi qua được nhờ policy này. Giữ nguyên `Host` thì ALB nhận host của CloudFront và routing theo host sẽ hỏng.

**Custom error responses** — thêm 2 mục:

| HTTP error code | Response page path | HTTP response code | TTL |
|---|---|---|---|
| 403 | `/index.html` | **200** | 10 |
| 404 | `/index.html` | **200** | 10 |

> SPA điều hướng ở phía trình duyệt. Mở thẳng `/orders/123` thì CloudFront đi tìm object `orders/123`, không có, S3 trả 403. Ánh xạ về 200 + `index.html` để SPA tự xử lý đường dẫn.

**Settings:** Price class **PriceClass_200** (có edge châu Á). `PriceClass_All` đắt hơn mà vô ích; `PriceClass_100` khiến người dùng trong nước đi vòng.

Distribution mất 5–15 phút để chuyển từ **Deploying** sang **Enabled**. Domain `dxxxxx.cloudfront.net` là địa chỉ người dùng mở.

> **Vì sao bắt buộc phải có CloudFront:** không phải để tăng tốc, mà vì **chứng chỉ TLS**. Tài khoản không có quyền ACM nên ALB không gắn được chứng chỉ. CloudFront đi kèm sẵn chứng chỉ cho `*.cloudfront.net`, được trình duyệt tin cậy, không tốn thêm đồng nào và không cần quyền gì.

### 6.3 Siết ALB lại sau khi CloudFront xong

Quay lại `<prefix>-sg-alb-public` → xoá rule `0.0.0.0/0` → thêm rule port 80 với source là **prefix list** `com.amazonaws.global.cloudfront.origin-facing` (ở ap-southeast-1 là `pl-31a34658`).

Sau bước này không ai gọi thẳng DNS của ALB để đi vòng qua CDN được nữa.

---

# GIAI ĐOẠN 7 — Sau khi RDS xong (30 phút)

### 7.1 RDS Proxy → `modules/data`

**RDS → Proxies → Create proxy**

| Trường | Giá trị |
|---|---|
| Name | `<prefix>-proxy` |
| Engine | PostgreSQL |
| Target group | database `<prefix>-db` |
| Secrets Manager secret | secret RDS tạo ở giai đoạn 3 |
| IAM role | **Create new** |
| Subnets | 2 subnet `data-*` |
| Security group | **`<prefix>-sg-rds-proxy`** |
| Require TLS | bật |
| Max connections percent | 90 |

> **Security group của proxy phải là `sg-rds-proxy`, không phải `sg-rds`.** Đặt proxy vào `sg-rds` thì chính nó trở thành thứ mà `sg-rds` không cho phép kết nối vào — `sg-rds` chỉ nhận từ `sg-rds-proxy` và `sg-app`. Proxy sẽ không chạm được database.

**Copy proxy endpoint** → đây mới là giá trị `DB_HOST` thật, **không phải endpoint của RDS**. Cập nhật parameter `/<prefix>/db/host`, rồi thay instance để user data đọc lại.

RDS Proxy giữ nguyên kết nối phía client khi RDS failover và tự nối lại phía database. Ứng dụng thấy câu lệnh chậm chứ không thấy kết nối đứt — đây là phần đỡ cho ràng buộc #5.

### 7.2 Read Replica — BỎ QUA, bị SCP chặn

`rds:CreateDBInstanceReadReplica` bị SCP của Organization từ chối. Đây là chặn ở cấp tổ chức, IT của tài khoản không cấp được.

Ràng buộc #10 xử lý bằng cách chạy job báo cáo trên primary trong transaction `REPEATABLE READ` với mốc chốt tường minh. Bảng `report_runs` có cột `ran_on` ghi rõ đã chạy ở đâu.

<details>
<summary>Nếu SCP được mở</summary>

**RDS → Databases → chọn `<prefix>-db` → Actions → Create read replica**
- Identifier `<prefix>-db-replica`, `db.t4g.micro`, AZ khác primary, public access **No**

Copy endpoint → đặt vào `DB_REPLICA_HOST` trong `/etc/abc.env`.

</details>

### 7.3 EFS → `modules/fileserver`

**EFS → Create file system → Customize**

| Trường | Giá trị |
|---|---|
| Encryption at rest | bật, key `aws/elasticfilesystem` |
| Lifecycle → Transition to IA | **30 ngày** không truy cập |
| Automatic backups | bật |
| VPC | VPC của stack |
| Mount targets | **cả 2 subnet `data-*`**, SG `<prefix>-sg-fileserver` |

Instance trong một AZ phải nối tới mount target trong **chính AZ đó** — đi chéo AZ vừa tốn phí truyền dữ liệu vừa mất khả năng chịu lỗi.

**Access Point cho từng phòng ban** — đây là cơ chế phân quyền của ràng buộc #7:

| Phòng ban | POSIX UID/GID | Root directory | Quyền thư mục |
|---|---|---|---|
| sales | 6001 / 5001 | `/sales` | `0770` |
| finance | 6002 / 5002 | `/finance` | `0770` |
| hr | 6003 / 5003 | `/hr` | `0770` |
| production | 6004 / 5004 | `/production` | `0770` |
| purchasing | 6005 / 5005 | `/purchasing` | `0770` |
| dùng chung | 6000 / 5000 | `/shared` | `0770` |

Access point `shared` khai thêm **secondary GIDs** là gid của cả năm phòng ban.

UID/GID khớp đúng với `deploy/local/fileserver-entrypoint.sh` ở nguồn, nên `diff` hai bản kiểm kê là so được trực tiếp.

**File system policy** — vào tab **File system policy → Edit**, bật cả hai ô:

- **Enforce in-transit encryption for all clients** — từ chối mount không có TLS
- **Prevent root access by default** + chỉ cho mount qua access point

> Không có điều kiện "chỉ mount qua access point" thì một máy có quyền IAM đủ rộng vẫn mount thẳng gốc file system và đọc hết mọi phòng ban, vô hiệu hoá toàn bộ phần phân quyền ở trên.

Access point ép danh tính từ phía server: `posix_user` quyết định máy mount qua nó **là ai**, bất kể tiến trình chạy dưới uid nào — kể cả khi có `root` trên EC2.

**Thu hồi quyền trong ≤ 5 phút (ràng buộc #7)** — hai bước, không phải một:

1. Xoá access point hoặc sửa policy của nó. Chặn mọi **mount mới** ngay lập tức, không phải đợi cache credential hết hạn như mô hình user/password.
2. Ép unmount trên các máy đang mount, bằng **Systems Manager → Run Command → AWS-RunShellScript**, target theo tag `Name = abc-migration-dev-app`, lệnh `umount -f -l /mnt/<phòng>`.

Bước 2 là bắt buộc. Đo thật ngày 12/09/2026 (`evidence/aws-A6-efs-revoke-*.log`): sau khi xoá access point, mount đang mở vẫn đọc ghi bình thường suốt 283 giây. EFS xét access point ở thời điểm **mount**, không xét lại ở từng thao tác I/O.

Đừng thu hồi bằng cách gỡ rule 2049 khỏi security group. Đo thật: NFS không lỗi ngay mà block, uvicorn treo theo, `/ready` quá hạn, ALB đánh unhealthy, ASG thay máy sau 13–52 giây.

---

# GIAI ĐOẠN 8 — Nạp dữ liệu và migrate (60 phút) → `modules/migration`

### 8.1 Nạp schema

Từ **Session Manager** vào một EC2 app (CloudShell không nằm trong VPC):

```bash
psql "postgresql://abcapp:<pw>@<proxy-endpoint>:5432/abcsales?sslmode=require" \
  -f db/01-schema.sql
```

### 8.2 Dựng môi trường "on-premise" nguồn

Một EC2 ở **VPC riêng** (hoặc máy cá nhân), chạy `docker compose up -d` + seed dữ liệu. `docker-compose.yml` đã set sẵn `wal_level=logical` — bắt buộc để DMS CDC hoạt động.

### 8.3 DMS

**DMS → Replication instances → Create** → **`dms.t3.micro`**, 50 GB, **Single-AZ**, VPC của stack, subnet `data-*` *(~10 phút)*

**DMS → Endpoints → Create endpoint** ×2:
- Source: PostgreSQL on-prem → **Run test** phải xanh
- Target: RDS `<prefix>-db` → **Run test** phải xanh

**DMS → Database migration tasks → Create task**

| Trường | Giá trị |
|---|---|
| Migration type | **Migrate existing data and replicate ongoing changes** |
| Target table preparation mode | **Do nothing** |
| **Turn on validation** | **bật** |
| Validation mode | Row level |
| Error handling → Apply error policy | **Stop task** |
| CloudWatch logs | bật |
| Start task on create | **tắt** |

Ba thiết lập đáng giải thích:

| Thiết lập | Vì sao |
|---|---|
| Validation **Row level** | DMS đọc lại từng dòng ở hai đầu và so sánh. Đây là bằng chứng "không mất giao dịch" thay vì chỉ tin là xong |
| Apply error policy **Stop task** | Gặp dòng lỗi thì dừng hẳn. Mặc định là bỏ qua và đi tiếp — mất dữ liệu âm thầm, đúng thứ ràng buộc #2 cấm |
| Target table prep **Do nothing** | Không tự tạo hay xoá bảng ở đích. Schema do `db/01-schema.sql` tạo; để DMS tự tạo sẽ ra kiểu dữ liệu lệch |

**Tạo task ở trạng thái dừng**, chỉ bấm Start khi mở cửa sổ cutover — start là bắt đầu ghi vào database đích.

> **Việc DMS không làm: sequence.** DMS chép dữ liệu chứ không chép giá trị hiện tại của sequence. Cutover xong mà không reset thì `INSERT` đầu tiên đâm vào khoá chính đã tồn tại — lỗi `UniqueViolation` trên `orders_pkey`. Bước reset nằm trong `scripts/test-a1-migration-cutover.sh`, quét **toàn bộ** sequence qua `pg_get_serial_sequence` chứ không liệt kê tay từng bảng.

### 8.4 DataSync

Nguồn là **S3** (bản sao file server), đích là **EFS** — cả hai đều là dịch vụ AWS nên **DataSync chạy agentless, không cần EC2 agent nào**.

Agent chỉ bắt buộc khi nguồn là NFS hoặc SMB tự quản. Chép vài chục MB tài liệu mà dựng thêm một EC2 là lãng phí.

**DataSync → Locations → Create location** ×2 (S3 nguồn, EFS đích) → **Tasks → Create task**

| Trường | Giá trị |
|---|---|
| Verify data | **Verify all data transferred** |
| **Copy POSIX permissions** | **Preserve** |
| Copy ownership (UID/GID) | **Preserve** (INT_VALUE) |

> `Preserve` là điểm mấu chốt của ràng buộc #7. Không có nó, mọi file sang EFS đều thuộc về cùng một owner và toàn bộ phân quyền theo phòng ban trở thành vô nghĩa.

Chạy xong, đối chiếu bằng `evidence/fileshare-manifest.txt` và chạy lại `scripts/test-a5-fileshare-perms.sh` trên đích.

**Xong việc thì huỷ replication instance** — nó tính tiền theo giờ liên tục.

---

# GIAI ĐOẠN 9 — Quan sát (30 phút) → `modules/observability`

### 9.1 SNS

**SNS → Topics → Create topic** → Standard, `<prefix>-alerts` → **Create subscription** → Email

> Subscription tạo ra ở trạng thái **PendingConfirmation**. Phải bấm link trong email thì alarm mới tới nơi. Chưa xác nhận thì alarm vẫn bắn, vẫn đổi trạng thái, chỉ là không ai biết.

### 9.2 Alarm

**CloudWatch → Alarms → Create alarm** — tạo **8 cái**, đều gửi về `<prefix>-alerts`:

| Metric | Thống kê | Ngưỡng | Chu kỳ | Missing data | Ràng buộc |
|---|---|---|---|---|---|
| ALB `TargetResponseTime` | **p95** | > **2** giây | 2 × 60s | notBreaching | #4 |
| 5XX ÷ RequestCount × 100 | metric math | > **1** % | 2 × 60s | notBreaching | #4 |
| ALB `UnHealthyHostCount` | Maximum | > 0 | 1 × 60s | notBreaching | #4 |
| RDS `DatabaseConnections` | Average | > **68** (80% của 85) | 3 × 60s | missing | #5 |
| RDS `CPUUtilization` | Average | > 80 % | 5 × 60s | missing | #10 |
| RDS `FreeStorageSpace` | Minimum | < **2 GB** | 1 × 300s | missing | #6 |
| SQS `ApproximateAgeOfOldestMessage` | Maximum | > **300** giây | 2 × 60s | notBreaching | #3 |
| DLQ `ApproximateNumberOfMessagesVisible` | Maximum | > 0 | 1 × 60s | notBreaching | #3 |

Hai ngưỡng đầu lấy thẳng từ yêu cầu: p95 ≤ 2s và tỉ lệ lỗi ≤ 1%.

Vài chi tiết dễ bấm sai:

- **p95 phải chọn ở ô Statistic → Percentile → p95**, không phải Average. Trung bình che mất phần đuôi: 95 request 100 ms và 5 request 10 giây cho trung bình 595 ms — nghe ổn, trong khi 5% người dùng chờ 10 giây.
- **Tỉ lệ lỗi không có metric sẵn**, phải dùng **Math expression**: `(m5xx / mreq) * 100`.
- **`treat_missing_data` khác nhau giữa ALB/SQS và RDS.** ALB và SQS: không có request thì không có metric, im lặng là bình thường → `notBreaching`, để không báo động mỗi đêm. RDS luôn phát metric khi còn sống, metric biến mất nghĩa là có vấn đề → `missing`.

### 9.3 Metric filter cho log lỗi

**CloudWatch → Log groups → `/<prefix>/app` → Metric filters → Create**

Filter pattern:

```
{ ($.level = "ERROR") || ($.level = "CRITICAL") }
```

> **Phải là JSON pattern, không phải text pattern.** Ứng dụng ghi log JSON. Dùng text pattern `"?ERROR ?CRITICAL"` thì filter vẫn khớp dòng log, nhưng nếu metric có dimension theo field JSON (`$.tier`) thì giá trị trích ra rỗng — metric ra rỗng, alarm không bao giờ bắn.

### 9.4 Truy vấn Logs Insights lưu sẵn

**CloudWatch → Logs Insights** → gõ truy vấn → **Save**. Lưu 4 cái, đây là phần cho ràng buộc #8:

| Tên | Dùng khi |
|---|---|
| `<prefix>/truy-vet-mot-giao-dich` | Có `correlation_id`, xem toàn bộ chặng app → worker → DB |
| `<prefix>/truy-vet-theo-ma-don` | Chỉ có mã đơn khách hàng đọc qua điện thoại |
| `<prefix>/loi-gan-day` | Vừa nhận alarm, muốn biết lỗi gì |
| `<prefix>/request-cham` | p95 vượt ngưỡng, muốn biết endpoint nào chậm |

Lưu sẵn để lúc sự cố không phải nhớ cú pháp Logs Insights.

### 9.5 Log retention

**CloudWatch → Log groups** → mỗi group → **Actions → Edit retention → 30 days**. Để `Never expire` là đốt tiền vô ích.

### 9.6 Dashboard

**CloudWatch → Dashboards → Create dashboard** — gom: ALB latency p95, request count, 5xx, ASG instance count, RDS CPU + connections, SQS queue depth + DLQ.

Đây là ảnh bỏ vào slide.

---

# GIAI ĐOẠN 10 — Chạy test (1 ngày)

```bash
SITE=https://<cloudfront-domain>

./scripts/test-a2-idempotency.sh       $SITE 20
./scripts/test-a3-concurrent-update.sh $SITE
k6 run -e BASE_URL=$SITE loadtest/k6/order-load.js   # baseline TRƯỚC
k6 run -e BASE_URL=$SITE loadtest/k6/peak-5x.js      # test B1
./scripts/test-b4-db-outage.sh         $SITE <sg-rds-id>
./scripts/test-b8-report-consistency.sh $SITE
```

Chạy baseline trước để biết một instance chịu được bao nhiêu req/phút ở p95 < 1,5s, rồi lấy đúng con số đó chỉnh lại target value ở bước 5.6.

Load generator chạy từ **một EC2 riêng** (`c6i.large`), đừng chạy từ laptop qua internet — độ trễ đường truyền làm hỏng số đo p95.

**Đo gián đoạn cho ràng buộc #4** — vòng lặp 1 giây, phân giải đủ cho ngân sách 2 phút:

```bash
while true; do
  printf '%s,%s\n' "$(date +%s)" \
    "$(curl -s -o /dev/null -m 3 -w '%{http_code}' $SITE/api/ready)"
  sleep 1
done | tee b2-timeline.csv
```

Rồi terminate 1 instance. Đếm số dòng khác `200` liên tiếp = số giây gián đoạn chính xác.

---

# GIAI ĐOẠN 11 — Hồ sơ bàn giao (ràng buộc #8)

Nếu đã dựng bằng Terraform thì hồ sơ bàn giao chính là repo: `terraform init && terraform apply` dựng lại toàn bộ. Kèm `.terraform.lock.hcl` để ghim provider tới từng checksum.

Nếu dựng bằng Console, phải sinh ngược ra template thì mới đạt ràng buộc #8:

**CloudFormation → IaC generator → Create scan** → quét tài nguyên → chọn tài nguyên của mình → **Create template**

Template sinh ra khá thô, phải dọn tay. Bằng chứng mạnh nhất: dùng template đó `Create stack` vào một VPC mới, quay video, bấm giờ.

**Đối chiếu Console với Terraform:** sau khi dựng bằng Terraform, dùng tài liệu này như checklist đi soi từng màn hình Console. Chỗ nào lệch thì hoặc Terraform sai, hoặc tài liệu này cũ — sửa cả hai cho khớp.

---

# Checklist bằng chứng cần thu

| # | Bằng chứng | Lấy ở đâu |
|---|---|---|
| 2 | DMS Data Validation report + timeline cutover | DMS console → task → Table statistics |
| 2 | Log `test-a1-migration-cutover.sh` (downtime đo được) | terminal |
| 3 | Kết quả test A2 / A3 | terminal, chụp màn hình |
| 4 | Kết quả k6 `peak-5x` + dashboard CloudWatch | k6 tự xuất |
| 4 | Timeline gián đoạn khi giết instance | vòng lặp curl 1 giây |
| 5 | Log test B4 + `aws sts get-caller-identity` | script + Session Manager |
| 6 | Video PITR restore có bấm giờ | quay màn hình |
| 7 | Kết quả `test-a5-fileshare-perms.sh` trước–sau + video thu hồi quyền | script |
| 8 | Truy vấn Logs Insights theo `correlation_id` | CloudWatch |
| 8 | Video `terraform apply` dựng lại từ đầu | quay màn hình |
| 9 | Cost Explorer lọc theo tag `owner` | Billing console |
| 10 | Performance Insights lúc chạy job báo cáo | RDS console |

**Rà tag sau khi dựng** — liệt kê tài nguyên thiếu tag `owner`:

```bash
aws --profile abc-migration resourcegroupstaggingapi get-resources \
  --region ap-southeast-1 \
  --query "ResourceTagMappingList[?!not_null(Tags[?Key=='owner'])].ResourceARN" \
  --output table
```

---

# Tắt tạm để đỡ tiền

Không cần xoá. Phần lớn chi phí tính theo giờ:

```bash
./scripts/aws-env.sh down     # ASG desired=0, RDS stop, xoá NAT
./scripts/aws-env.sh up       # bật lại, mất ~5 phút
./scripts/aws-env.sh status   # xem đang chạy gì
```

**KHÔNG dùng `terraform destroy` để tắt** — nó xoá cả RDS và mất hết dữ liệu test.

---

# Xoá hẳn tài nguyên (thứ tự NGƯỢC)

Nếu dựng bằng Terraform:

```bash
terraform apply -var='allow_destroy=true'   # hạ deletion protection trước
terraform destroy
```

Nếu dựng bằng Console, xoá sai thứ tự sẽ kẹt, đặc biệt là VPC (ENI còn dính):

```
1. CloudFront distribution (Disable trước, chờ Deployed, rồi Delete)
2. Alarm, dashboard, metric filter, truy vấn lưu sẵn, SNS
3. DMS task → endpoint → replication instance
4. DataSync task → location
5. ASG (đặt desired = 0 trước) → warm pool → launch template
6. ALB → target group
7. EFS: Access Point → mount target → file system
8. RDS Proxy → read replica → primary (tắt deletion protection trước)
9. SQS, DynamoDB (tắt deletion protection), S3 (assets, artifacts, alb-logs), Secrets Manager
10. NAT Gateway → giải phóng EIP
11. VPC (xoá cuối cùng)
```

> Xoá NAT Gateway và EIP là bắt buộc — chúng tính tiền theo giờ kể cả khi không dùng.
> CloudFront phải **Disable rồi chờ** mới xoá được, thường mất 15 phút.
