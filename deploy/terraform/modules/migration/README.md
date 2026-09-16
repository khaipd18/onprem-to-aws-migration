# `migration`

DMS chuyển database và DataSync chuyển file. Cả hai tạo ở trạng thái dừng, chỉ chạy khi mở cửa sổ cutover.

## Kiến trúc

```
   PostgreSQL on-premise                        RDS PostgreSQL
        │                                             ▲
        │   DMS replication instance (dms.t3.micro)   │
        └──▶  task "full-load-and-cdc"  ──────────────┘
               validation ROW_LEVEL
               ApplyErrorPolicy = STOP_TASK

   S3 (bản sao file server)  ──── DataSync ────▶  EFS
                                 agentless
                                 posix_permissions = PRESERVE
```

## Vì sao task tạo ra ở trạng thái dừng

DMS bắt đầu là bắt đầu ghi vào database đích. Chạy nhầm lúc `terraform apply` sẽ đụng dữ liệu thật. Task được tạo với `start_replication_task = false`; output `start_commands` in ra đúng lệnh CLI để chạy khi đã sẵn sàng.

## `full-load-and-cdc` và ràng buộc #2

Ràng buộc #2: downtime ≤ 15 phút, không mất và không trùng giao dịch.

Chia làm hai giai đoạn:
- **full load** — chép toàn bộ dữ liệu hiện có, chạy trong lúc hệ thống cũ vẫn nhận đơn bình thường, mất bao lâu cũng được.
- **CDC** — đọc tiếp WAL, đồng bộ liên tục những thay đổi mới.

Downtime chỉ là khoảng từ lúc chặn ghi ở nguồn đến lúc CDC đuổi kịp và đổi endpoint. Thực đo trong `scripts/test-a1-migration-cutover.sh` (dùng logical replication thay DMS, cùng nguyên lý): **0,8 giây**, 2.086 đơn khớp, 0 đơn trùng.

## Ba thiết lập quan trọng của task

| Thiết lập | Giá trị | Lý do |
|---|---|---|
| `ValidationSettings` | `ROW_LEVEL` | DMS đọc lại từng dòng ở hai đầu và so sánh. Đây là bằng chứng "không mất giao dịch", thay vì chỉ tin là xong |
| `ApplyErrorPolicy` | `STOP_TASK` | Gặp dòng lỗi thì dừng hẳn. Mặc định là bỏ qua và đi tiếp — sẽ mất dữ liệu âm thầm, đúng thứ ràng buộc #2 cấm |
| `TargetTablePrepMode` | `DO_NOTHING` | Không tự tạo hay xoá bảng ở đích. Schema do migration của ứng dụng tạo, để DMS tự tạo sẽ ra kiểu dữ liệu sai lệch |

## Việc DMS không làm: sequence

DMS chép dữ liệu, không chép giá trị hiện tại của sequence. Cutover xong mà không reset thì `INSERT` đầu tiên đâm vào khoá chính đã tồn tại — lỗi `UniqueViolation` trên `orders_pkey`.

Bước reset nằm trong `scripts/test-a1-migration-cutover.sh`, quét **toàn bộ** sequence qua `pg_get_serial_sequence` chứ không liệt kê tay từng bảng. Liệt kê tay đã từng bỏ sót `order_items`, `order_events`, `report_runs` và làm hỏng môi trường test.

## DataSync không cần agent

Agent chỉ bắt buộc khi nguồn là NFS hoặc SMB tự quản. Ở đây nguồn là **S3**, đích là **EFS** — cả hai đều là dịch vụ AWS, DataSync chạy thẳng, không cần EC2 nào.

Điều này làm chi phí phần file gần như bằng không: DataSync tính theo GB chuyển, không tính giờ instance. Với vài chục MB tài liệu thì gần như miễn phí.

Nếu chép thẳng từ NFS on-premise thì mới cần agent, và lúc đó `sg-admin-client` là security group dành cho nó.

## `posix_permissions = "PRESERVE"`

Giữ nguyên uid/gid/mode của file nguồn. Không có nó, mọi file sang EFS đều thuộc về cùng một owner và toàn bộ phân quyền theo phòng ban ở module `fileserver` trở thành vô nghĩa. `posix_uid` và `posix_gid` cũng đặt `INT_VALUE` để giữ số uid/gid nguyên vẹn.

## Cả module có cờ bật tắt

`enable_file_migration` là biến boolean, không phải phép so sánh với ARN của EFS. `count` phải tính được lúc plan; so sánh với ARN — thứ chỉ biết sau khi apply — sẽ ra lỗi `Invalid count argument`.

## Sau khi cutover xong

Module này chỉ dùng trong cửa sổ chuyển đổi. Xong việc thì huỷ, replication instance là tài nguyên tính tiền theo giờ liên tục.

## Hai role DMS tên cố định

DMS đòi hai role với tên **AWS quy định sẵn**, không đổi được:

| Role | Policy |
|---|---|
| `dms-vpc-role` | `AmazonDMSVPCManagementRole` |
| `dms-cloudwatch-logs-role` | `AmazonDMSCloudWatchLogsRole` |

Thiếu chúng thì tạo replication instance báo:

```
AccessDeniedFault: The IAM Role arn:aws:iam::<account>:role/dms-vpc-role
is not configured properly.
```

Đọc như thiếu quyền nhưng thực ra là thiếu role. Mất thời gian mới nhận ra.

Bật bằng `create_service_roles = true`. **Mặc định tắt**, vì hai role này khác
mọi role khác của stack: chúng không có prefix riêng mà dùng chung cả tài khoản.
Hai người cùng dựng thì `terraform destroy` của người này xoá mất role của người
kia.

Tạo xong phải **chờ 1–2 phút** cho IAM lan truyền rồi mới tạo replication
instance, làm ngay vẫn báo lỗi cũ.

## Tài nguyên tạo ra

- `aws_cloudwatch_log_group.datasync`
- `aws_datasync_location_efs.target`
- `aws_datasync_location_s3.source`
- `aws_datasync_task.files`
- `aws_dms_endpoint.source`
- `aws_dms_endpoint.target`
- `aws_dms_replication_instance.main`
- `aws_dms_replication_subnet_group.main`
- `aws_dms_replication_task.main`
- `aws_iam_role.dms_service`
- `aws_iam_role_policy_attachment.dms_service`

## Biến

| Tên | Mô tả | Mặc định |
|---|---|---|
| `allocated_storage` | Storage for the replication instance, in gigabytes. Fifty is the minimum the service accepts. | `50` |
| `create_service_roles` | Whether to create the two roles DMS requires under fixed names. They are shared by the whole account, so leave this off when another stack already owns them. | `false` |
| `datasync_role_arn` | Role DataSync assumes to read the staging bucket. Required when the file part is enabled. | `""` |
| `enable_file_migration` | Whether to create the file copy task. | `false` |
| `instance_class` | Replication instance class. | `"dms.t3.micro"` |
| `log_retention_days` | Days CloudWatch keeps the migration logs. | `30` |
| `migrated_tables` | Tables carried across. | `["customers", "products", "orders", "order_items", "order_events"]` |
| `multi_az` | Whether the replication instance runs across two availability zones. | `false` |
| `name_prefix` | Prefix applied to every resource name in this module. | **bắt buộc** |
| `security_group_arns` | Security group ARNs, the form the file copy location expects. | `[]` |
| `security_group_ids` | Security groups attached to the replication instance. | **bắt buộc** |
| `source_db` | Connection details of the database being migrated away from. | **bắt buộc** |
| `source_files_bucket_arn` | Bucket holding the file share staged out of the source server. Leave empty to skip the file part. | `""` |
| `subnet_arns` | Subnet ARNs, the form the file copy location expects. | `[]` |
| `subnet_ids` | Subnets the replication instance runs in. Must reach both the source database and the target database. | **bắt buộc** |
| `target_db` | Connection details of the database being migrated to. | **bắt buộc** |
| `target_efs_arn` | File system the files are copied into. | `""` |

## Đầu ra

| Tên | Mô tả |
|---|---|
| `datasync_task_arn` | ARN of the file copy task, or null when the file part is disabled. |
| `replication_instance_arn` | ARN of the replication instance. |
| `replication_task_arn` | ARN of the replication task. It is created stopped; start it when the cutover window opens. |
| `start_commands` | Commands that begin the migration once the task exists. |
