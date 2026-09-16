# `iam`

Hai IAM role: role cho EC2 trong ASG, và role cho RDS Proxy.

## Kiến trúc

```
  role instance ──▶ instance profile ──▶ EC2 trong ASG
        ├── AmazonSSMManagedInstanceCore   (Session Manager, không cần SSH)
        ├── CloudWatchAgentServerPolicy    (đẩy metric + log)
        └── inline policy: đọc SSM /<prefix>/*, giải mã qua key mặc định,
                           gửi/nhận SQS, đọc artifact bucket, ghi bảng accept

  role proxy ──▶ RDS Proxy
        └── inline policy: đọc secret master + giải mã qua aws/secretsmanager
```

## ARN bucket artifact tự ghép từ tên, không lấy từ module `compute`

Bucket artifact do module `compute` tạo, mà `compute` lại cần instance profile của module này. Lấy ARN thẳng từ `compute` sẽ thành phụ thuộc vòng: `iam` chờ `compute`, `compute` chờ `iam`.

Nên ARN được ghép sẵn trong `locals` từ quy ước đặt tên: `arn:aws:s3:::<name_prefix>-artifacts-<account-id>`. Hai module dùng chung một quy ước nên luôn khớp.

Trước đây module có cờ `create_roles` để chạy được khi chưa có quyền IAM. Đã bỏ vì quyền đã được cấp, và cờ đó bắt mọi resource phải viết `count` rồi truy cập bằng `[0]`.

## Không dùng SSH

Instance role gắn `AmazonSSMManagedInstanceCore` nên vào máy bằng Session Manager. Không key pair, không cổng 22 trong security group, mọi phiên đều có log trong CloudTrail.

## Không tạo KMS key — mỗi dịch vụ dùng key mặc định của nó

Module này từng tạo một customer managed key dùng chung. Đã bỏ hẳn.

| Dịch vụ | Key đang dùng |
|---|---|
| RDS | `storage_encrypted = true`, key `aws/rds` |
| SQS | `sqs_managed_sse_enabled = true`, tức SSE-SQS |
| DynamoDB | key do AWS sở hữu, không hiện ARN |
| EFS | `encrypted = true`, key `aws/elasticfilesystem` |
| SSM SecureString | key `aws/ssm` |
| Secrets Manager | key `aws/secretsmanager` |

**Dữ liệu vẫn mã hoá at-rest ở mọi chỗ.** Cái mất là quyền kiểm soát: không sửa
được key policy, không tự đặt chu kỳ xoay vòng, và mỗi dịch vụ một key riêng
thay vì một key chung.

Hai lý do bỏ, đều rút ra từ lần dựng thật ngày 12/09/2026:

1. CMK không chỉ cần `kms:CreateKey`. Nó kéo theo `kms:TagResource`,
   `kms:EnableKeyRotation`, `kms:Encrypt` — mỗi quyền thiếu chặn ở một bước khác
   nhau, phải xin bốn lượt mới đi hết.
2. **Xoá lại không được.** `kms:ScheduleKeyDeletion` không nằm trong nhóm quyền
   tạo key. `terraform destroy` để lại hai key mồ côi, mỗi key 1 USD/tháng, và
   không có cách nào tự dọn.

Policy của instance role vẫn giữ `kms:Decrypt` và `kms:GenerateDataKey` trên
`*`, kèm điều kiện `kms:ViaService` giới hạn đúng bốn dịch vụ — vì đọc SSM
SecureString và Secrets Manager vẫn phải qua KMS, dù là key mặc định.

Đánh đổi: key mặc định không có ARN cố định để trỏ vào, nên `kms:Decrypt` phải
cấp trên `*`. Điều kiện `kms:ViaService` kéo phạm vi về đúng bốn dịch vụ `ssm`,
`sqs`, `dynamodb`, `s3` — rộng hơn trỏ một ARN, nhưng không phải mở toang: role
không dùng được key nào ngoài bốn dịch vụ đó.

Đã dựng thật cả hai chế độ ngày 2026-09-11 và 12/09, đều chạy. Bản giữ lại là
bản không CMK.

## Tài nguyên tạo ra

- `aws_iam_instance_profile.instance`
- `aws_iam_role.instance`
- `aws_iam_role.proxy`
- `aws_iam_role_policy.instance`
- `aws_iam_role_policy.proxy`
- `aws_iam_role_policy_attachment.cloudwatch_agent`
- `aws_iam_role_policy_attachment.session_manager`

## Biến

| Tên | Mô tả | Mặc định |
|---|---|---|
| `name_prefix` | Prefix applied to every resource name in this module. | **bắt buộc** |

## Đầu ra

| Tên | Mô tả |
|---|---|
| `instance_profile_name` | Name of the instance profile. |
| `instance_role_arn` | ARN of the instance role. |
| `proxy_role_arn` | ARN of the role the database proxy assumes. |
