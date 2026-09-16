# Terraform

Hạ tầng AWS cho bài đánh giá cuối dự án.

Đã dựng thật ngày 2026-09-11: `Apply complete! Resources: 165 added` rồi
`Destroy complete! Resources: 165 destroyed`, không sót tài nguyên nào. Mỗi dịch vụ một module trong `modules/`, root chỉ gọi và nối dây.

```
versions.tf               ghim terraform >= 1.9, provider aws ~> 6.0
providers.tf              provider + default_tags
variables.tf              biến chung + tham số mạng
locals.tf                 name_prefix, common_tags
main.tf                   gọi module
outputs.tf                thông tin tài khoản + output của module
terraform.tfvars.example  mẫu để copy thành terraform.tfvars
```

## Sơ đồ tổng thể

```
                              người dùng
                                   │ HTTPS
                                   ▼
                             CloudFront            ◀── cdn
                          ┌────────┴────────┐
                    default │            /api/*
                          ▼                  ▼
                   S3 assets            ALB public         ◀── static, compute
                     (OAC)                   │
                                             ▼
                                  Auto Scaling group       ◀── compute
                                  t4g.small, 2→6 máy
                                  + warm pool 2 máy
                                   │        │        │
                        ┌──────────┘        │        └──────────┐
                        ▼                   ▼                   ▼
                   RDS Proxy          SQS FIFO             EFS access point
                        │             + DLQ                theo phòng ban
                        ▼                │                       ▲
              RDS PostgreSQL 16          ▼                       │
              Multi-AZ              worker ──▶ RDS           fileserver

                     DynamoDB <prefix>-accept  ◀── queue
                     ghi nhận đơn trước khi vào RDS,
                     đọc được cả khi RDS chết
                   │
              data │        network: VPC 2 AZ, 3 tầng subnet
                                security: 6 SG xâu chuỗi
                                iam: role EC2 + role RDS Proxy
                                observability: 8 alarm, SNS, dashboard
                                migration: DMS + DataSync (chỉ lúc cutover)
```

## Các module

| Module | Làm gì | Tài liệu |
|---|---|---|
| `network` | VPC 2 AZ, 3 tầng subnet, IGW, NAT, S3 endpoint | [README](modules/network/README.md) |
| `security` | 6 security group xâu chuỗi theo tầng | [README](modules/security/README.md) |
| `iam` | Role EC2 và role RDS Proxy, cùng policy least privilege | [README](modules/iam/README.md) |
| `data` | RDS PostgreSQL Multi-AZ, RDS Proxy, mật khẩu trong SSM | [README](modules/data/README.md) |
| `queue` | SQS FIFO + DLQ, bảng DynamoDB ghi nhận đơn | [README](modules/queue/README.md) |
| `compute` | ALB public, ASG + warm pool, bucket artifact và access log | [README](modules/compute/README.md) |
| `static` | S3 chứa file tĩnh của SPA | [README](modules/static/README.md) |
| `cdn` | CloudFront trước S3 và ALB, chứng chỉ HTTPS | [README](modules/cdn/README.md) |
| `observability` | SNS, 8 alarm, metric filter, truy vấn lưu sẵn, dashboard | [README](modules/observability/README.md) |
| `fileserver` | EFS + access point phân quyền theo phòng ban | [README](modules/fileserver/README.md) |
| `migration` | DMS chuyển database, DataSync chuyển file | [README](modules/migration/README.md) |

## Luồng đi xuyên hệ thống

[`FLOW.md`](FLOW.md) mô tả cái gì đi qua đâu và hỏng thì rẽ hướng nào: tạo đơn,
database chết, một máy chết, scale out, release, báo cáo song song, file server,
truy vết, và thứ tự phụ thuộc giữa các module.

Đọc file đó trước khi đọc README từng module thì dễ hình dung hơn.

## Thứ tự nên đọc

0. [`FLOW.md`](FLOW.md) — luồng xuyên suốt, để có bức tranh tổng
1. `network` — mọi thứ khác nằm trong VPC này
2. `security` — chuỗi cho phép giữa các tầng, đọc xong là hiểu luồng traffic
3. `iam` — role và policy mà module `compute`, `data` đều tham chiếu
4. `data` — nơi dữ liệu thật nằm
5. `queue` → `compute` — đường đi của một đơn hàng
6. `static` → `cdn` — đường đi của một request từ trình duyệt
7. `observability` — cách biết hệ thống đang ổn hay không
8. `fileserver`, `migration` — hai phần độc lập, đọc lúc nào cũng được

## Cờ bật tắt

Bốn cờ ở root, mỗi cờ ứng với một quyết định thật chứ không phải để chờ quyền:

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `create_rds_proxy` | `true` | Tắt để so sánh failover có và không có proxy, xem `docs/noi-bo/demo/demo-5-failover-va-proxy.md` |
| `create_cloudfront` | `false` | Bật ở lần apply thứ hai, khi đã có DNS của ALB để điền `alb_domain_name` |
| `create_migration` | `false` | Bật khi mở cửa sổ cutover. DMS tính tiền theo giờ nên không để chạy sẵn |
| `create_dms_service_roles` | `false` | Tạo `dms-vpc-role` và `dms-cloudwatch-logs-role`. Hai role này dùng chung cả tài khoản nên mặc định tắt |

Cộng một cờ an toàn là `allow_destroy`, xem mục **Xoá môi trường**.

Số tài nguyên trong `terraform plan`, đo ngày 13/09/2026:

| Cấu hình | Số tài nguyên |
|---|---|
| mặc định | **165** — đúng bộ đã apply và đo test ngày 12/09 |
| `create_rds_proxy = false` | **160** |
| `create_cloudfront = true` | **168** |
| `create_cloudfront` + `create_migration` | **173** |

### Các cờ đã bỏ

Trước đây còn `create_iam_roles`, `create_fileserver`, `create_read_replica`, `enable_nat_gateway`, `single_nat_gateway`, `public_ingress_prefix_list_ids`, `artifact_bucket_arn`. Phần lớn sinh ra lúc chưa được cấp quyền, để plan chạy được trước. Quyền đã đủ nên chúng chỉ còn làm code khó đọc: mỗi cờ kéo theo `count = ... ? 1 : 0`, rồi mọi chỗ tham chiếu phải viết `[0]`, `one()` hoặc `try()`.

Đã kiểm chứng việc bỏ không làm đổi hạ tầng: so plan JSON trước và sau từng thuộc tính của cả 165 tài nguyên, **0 khác biệt**.

Ngoài ra `accept_store_driver` mặc định `dynamodb` (bảng ngoài RDS, đọc được cả khi database chết). Đặt `pg` thì bản ghi nhận nằm trong chính RDS — chỉ hợp cho môi trường local.

## Không có comment trong file `.tf`

Toàn bộ lý do "vì sao lại làm thế này" nằm trong các file README, không nằm trong code. Code chỉ nói *cái gì*, README nói *vì sao*. Khi sửa code thì sửa README tương ứng.

## Chạy

```bash
cd deploy/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
```

Không có access key ở bất kỳ file nào. Provider lấy credential từ profile `abc-migration` của AWS CLI. Kiểm tra trước:

```bash
aws --profile abc-migration sts get-caller-identity
```

Kết quả phải là `assumed-role`, không phải `user`.

### Chốt chặn chạy nhầm tài khoản

Máy có nhiều profile, và profile `default` trỏ sang tài khoản cá nhân khác. Quên
`--profile abc-migration` một lần là tạo tài nguyên nhầm chỗ mà không có lỗi nào báo.

Vì vậy provider khai `allowed_account_ids = [var.expected_account_id]` — tính
năng có sẵn của AWS provider. Mỗi lần `plan` hoặc `apply`, provider hỏi STS xem
đang đứng ở account nào; không khớp `expected_account_id` (mặc định
`123456789012`) là dừng ngay, chưa tạo gì cả.

Thử bằng cách cố tình khai sai account:

```
$ terraform plan -var='expected_account_id=000000000000'
Error: AWS account ID not allowed: 123456789012
```

Trước đây chỗ này là một `precondition` tự viết gắn vào `data.aws_region`. Chạy
đúng, nhưng người đọc phải hiểu vì sao kiểm account lại nằm trong data source
region. `allowed_account_ids` làm cùng việc trong một dòng.

Dựng ở tài khoản khác thì đổi `expected_account_id` sang account id mới.




## Tag

Yêu cầu của công ty là mọi resource có tag `owner`. Khai báo một lần ở provider:

```hcl
default_tags {
  tags = local.common_tags     # owner, Project, Environment, ManagedBy
}
```

Nên không cần viết khối `tags` ở từng resource — chỉ viết khi cần thêm tag riêng, thường là `Name`:

```hcl
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags       = { Name = "${local.name_prefix}-vpc" }
}
```

Biến `owner` có validation chặn giá trị rỗng, `extra_tags` có validation chặn việc đặt lại key `owner` ở đó.

### Bốn chỗ `default_tags` không với tới

| Trường hợp | Vì sao | Cách xử lý |
|---|---|---|
| EC2 do Auto Scaling Group tạo | ASG tự tạo instance, không qua provider | `tag { ... propagate_at_launch = true }` trong ASG |
| EBS volume và ENI từ launch template | tag của launch template không chảy xuống tài nguyên con | `tag_specifications` cho cả `instance`, `volume`, `network-interface` |
| Snapshot tự động của RDS, AMI | dịch vụ tạo theo lịch | `copy_tags_to_snapshot = true`; AMI gắn tag lúc tạo |
| Bucket state, resource tạo tay | nằm ngoài terraform | gắn tag ngay lúc tạo |

Rà lại sau khi apply — liệt kê resource thiếu tag `owner`:

```bash
aws --profile abc-migration resourcegroupstaggingapi get-resources \
  --region ap-southeast-1 \
  --query "ResourceTagMappingList[?!not_null(Tags[?Key=='owner'])].ResourceARN" \
  --output table
```

## State

Đang dùng state local. `terraform.tfstate` chứa giá trị nhạy cảm ở dạng thô (mật khẩu RDS) — root `.gitignore` đã chặn `*.tfstate` và `*.tfvars`, đừng gỡ.

Chuyển sang S3 khi cần. Bucket phải tạo tay trước, vì tạo bằng terraform thì đã cần backend rồi:

```bash
aws --profile abc-migration s3api create-bucket \
  --bucket abc-migration-tfstate-<account-id> \
  --region ap-southeast-1 \
  --create-bucket-configuration LocationConstraint=ap-southeast-1
aws --profile abc-migration s3api put-bucket-versioning \
  --bucket abc-migration-tfstate-<account-id> \
  --versioning-configuration Status=Enabled
aws --profile abc-migration s3api put-bucket-tagging \
  --bucket abc-migration-tfstate-<account-id> \
  --tagging 'TagSet=[{Key=owner,Value=khaipd18}]'
```

Rồi thêm vào `versions.tf` và chạy `terraform init -migrate-state`:

```hcl
backend "s3" {
  bucket       = "abc-migration-tfstate-<account-id>"
  key          = "abc-migration/dev/terraform.tfstate"
  region       = "ap-southeast-1"
  profile      = "abc-migration"
  encrypt      = true
  use_lockfile = true
}
```

`use_lockfile` khoá ngay trên S3, không cần bảng DynamoDB (cách cũ `dynamodb_table` đã bỏ ở provider v6).

## Xoá môi trường

Terraform destroy được bất cứ lúc nào. Có ba chốt chặn cố ý, và cả ba chạy theo **một cờ duy nhất**:

| Chốt | Ở đâu | `allow_destroy = false` | `= true` |
|---|---|---|---|
| `deletion_protection` | RDS | `true` | `false` |
| `skip_final_snapshot` | RDS | `false` — có snapshot cuối | `true` |
| `deletion_protection_enabled` | bảng DynamoDB accept | `true` | `false` |
| `force_destroy` | các bucket S3 | `false` | `true` |

```bash
terraform apply -var='allow_destroy=true'
terraform destroy
```

Bước `apply` là bắt buộc: `destroy` đọc `deletion_protection` từ trạng thái đang có trên AWS, nên phải hạ cờ xuống trước rồi mới xoá được.

Trong lúc chưa dùng đến mà không muốn xoá hẳn, dùng `scripts/aws-env.sh down` để hạ ASG về 0 — giữ nguyên hạ tầng, chỉ ngừng tính tiền giờ máy.

## Còn nợ

- Endpoint đích của DMS đang nhận `password = ""` (`main.tf`). Trước khi chạy migration thật phải trỏ nó vào Secrets Manager hoặc truyền mật khẩu qua biến, nếu không endpoint tạo ra sẽ không kết nối được.
- Provider 6.63 cảnh báo `hash_key is deprecated. Use key_schema instead` cho `aws_dynamodb_table`. Bản 6.63 chưa có `key_schema` trong schema nên chưa đổi được; chờ bản sau.
- Root `.gitignore` đang bỏ qua `.terraform.lock.hcl`. Ràng buộc #8 cần dựng lại được từ tài liệu bàn giao, mà lock file ghim provider tới từng checksum — chặt hơn `~> 6.0`. Cân nhắc bỏ dòng đó khỏi `.gitignore` và commit file lock.
