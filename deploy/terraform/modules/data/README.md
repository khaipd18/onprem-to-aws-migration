# `data`

PostgreSQL Multi-AZ, RDS Proxy đứng trước, mật khẩu sinh tự động và cất trong Parameter Store.

## Kiến trúc

```
      sg-app
        │ 5432
        ▼
   RDS Proxy ──── đọc mật khẩu ──▶ Secrets Manager  (key aws/secretsmanager)
        │ 5432
        ▼
   RDS PostgreSQL 16  (Multi-AZ)
   primary ──── đồng bộ ────▶ standby
   AZ 1a                      AZ 1b
        │
        └── snapshot tự động, giữ 7 ngày

   SSM Parameter Store  /<prefix>/db/{host,port,name,user,password}
        └── password là SecureString, mã hoá bằng key aws/ssm
```

## Multi-AZ đóng vai trò gì trong yêu cầu

Ràng buộc #6 đặt RPO ≤ 5 phút và RTO ≤ 30 phút. Multi-AZ ghi đồng bộ sang standby ở AZ khác, nên **RPO = 0** cho sự cố mất AZ, và failover tự động thường xong trong 60–120 giây, thừa so với RTO 30 phút.

Backup tự động giữ 7 ngày phủ trường hợp còn lại: hỏng dữ liệu do lỗi ứng dụng, khôi phục theo thời điểm với độ chi tiết 5 phút.

## Các tham số trong parameter group

| Tham số | Giá trị | Lý do |
|---|---|---|
| `rds.force_ssl` | `1` | Từ chối kết nối không mã hoá. Không có cách nào một client quên bật TLS mà vẫn kết nối được |
| `rds.logical_replication` | `1` | Bật để làm cutover bằng logical replication trong `scripts/test-a1-migration-cutover.sh` |
| `log_min_duration_statement` | `500` | Ghi log mọi câu lệnh chạy quá 500 ms. Đây là nguồn dữ liệu để truy p95 khi vượt ngưỡng (ràng buộc #4) |
| `log_lock_waits` | `1` | Ghi log khi có phiên chờ khoá — dấu hiệu báo cáo đang chặn OLTP (ràng buộc #10) |
| `idle_in_transaction_session_timeout` | `60000` | Cắt phiên mở transaction rồi bỏ đó quá 60 giây. Không có nó, một client treo giữ khoá vô hạn |

`rds.force_ssl` và `rds.logical_replication` là tham số static, đổi phải reboot — nên đặt `apply_method = "pending-reboot"`. Ba tham số còn lại là dynamic, áp dụng ngay.

## Vì sao mật khẩu không nằm trong biến

`random_password` sinh mật khẩu lúc apply, rồi ghi thẳng vào SSM SecureString và Secrets Manager. Không ai gõ mật khẩu vào `terraform.tfvars`, không mật khẩu nào đi qua Git.

Nó vẫn nằm trong state file — đó là lý do state phải để trên S3 có mã hoá và bật versioning, không để trên máy cá nhân.

Hai chỗ lưu vì hai người dùng khác nhau: **ứng dụng** đọc từ Parameter Store (rẻ, đọc nhiều), **RDS Proxy** bắt buộc đọc từ Secrets Manager (nó không hỗ trợ Parameter Store).

## RDS Proxy giải quyết gì

Không có proxy, mỗi instance ứng dụng tự mở pool riêng. Lúc `db.t4g.micro` chỉ chịu được khoảng 90 kết nối mà ASG scale lên 6 máy thì rất dễ chạm trần.

Quan trọng hơn với ràng buộc #5: khi RDS failover, proxy giữ nguyên kết nối phía client và tự nối lại phía database. Ứng dụng thấy câu lệnh chậm chứ không thấy kết nối đứt, nên không trả về "thành công giả" cho đơn hàng chưa ghi được.

## Không có read replica

Thiết kế ban đầu có read replica cho ràng buộc #10 (báo cáo chạy song song OLTP). Trên tài khoản này `rds:CreateDBInstanceReadReplica` bị SCP chặn ở cấp Organization, nên đã bỏ hẳn khỏi code thay vì để một cờ không bao giờ bật được.

Báo cáo chạy trên bản chính, trong transaction chỉ đọc `REPEATABLE READ`, có `statement_timeout`. Đo được p95 nhập đơn 61 ms trong lúc báo cáo chạy. Khi SCP được mở, thêm lại `aws_db_instance` với `replicate_source_db = aws_db_instance.main.identifier`.

## Proxy nằm ở security group nào

`aws_db_proxy` nhận `proxy_security_group_ids`, **không** dùng chung `security_group_ids` với instance. Đặt proxy vào `sg-rds` thì chính nó trở thành thứ mà `sg-rds` không cho phép kết nối vào — sg-rds chỉ nhận từ `sg-rds-proxy` và `sg-app`, nên proxy sẽ không chạm được database.

## Trước khi destroy

Cả hai chốt đều chạy theo một cờ duy nhất ở root: `allow_destroy`. Trong code là `deletion_protection = !var.allow_destroy`.

| Thuộc tính | Khi `allow_destroy = false` | Khi `= true` |
|---|---|---|
| `deletion_protection` | `true` | `false` |
| `skip_final_snapshot` | `false` (có snapshot cuối) | `true` |

```bash
terraform apply -var='allow_destroy=true'
terraform destroy
```

## Tài nguyên tạo ra

- `aws_db_instance.main`
- `aws_db_parameter_group.main`
- `aws_db_proxy.main`
- `aws_db_proxy_default_target_group.main`
- `aws_db_proxy_target.main`
- `aws_db_subnet_group.main`
- `aws_secretsmanager_secret.master`
- `aws_secretsmanager_secret_version.master`
- `aws_ssm_parameter.db_host`
- `aws_ssm_parameter.db_name`
- `aws_ssm_parameter.db_password`
- `aws_ssm_parameter.db_port`
- `aws_ssm_parameter.db_user`
- `random_password.master`

## Biến

| Tên | Mô tả | Mặc định |
|---|---|---|
| `allocated_storage` | Initial storage in gigabytes. | `20` |
| `allow_destroy` | Turn off deletion protection and skip the final snapshot, so the environment can be torn down in one command. | `false` |
| `backup_retention_days` | Days of automated backups. | `7` |
| `backup_window` | Daily window for automated backups, in UTC. | `"17:00-18:00"` |
| `create_proxy` | Whether to create an RDS Proxy. | `true` |
| `database_name` | Name of the initial database. | `"abcsales"` |
| `engine_version` | PostgreSQL version. Pinned to a minor version so a rebuild produces the same engine. | `"16.10"` |
| `instance_class` | Database instance class. | `"db.t4g.micro"` |
| `maintenance_window` | Weekly maintenance window, in UTC. | `"sun:18:30-sun:19:30"` |
| `master_username` | Master user name. | `"abcapp"` |
| `max_allocated_storage` | Upper bound for storage autoscaling. Set equal to allocated_storage to switch autoscaling off. | `100` |
| `name_prefix` | Prefix applied to every resource name in this module. | **bắt buộc** |
| `proxy_role_arn` | Role the proxy assumes to read the master password from Secrets Manager. | **bắt buộc** |
| `proxy_security_group_ids` | Security groups attached to the proxy endpoint. Must be the group the database accepts connections from, not the database group itself. | **bắt buộc** |
| `security_group_ids` | Security groups attached to the database. | **bắt buộc** |
| `subnet_ids` | Isolated subnets the database runs in. Must span at least two availability zones. | **bắt buộc** |

## Đầu ra

| Tên | Mô tả |
|---|---|
| `db_address` | Hostname of the primary database instance. |
| `db_endpoint` | Endpoint of the primary database instance. |
| `db_instance_identifier` | Identifier of the primary database instance. |
| `db_name` | Name of the initial database. |
| `db_port` | Port the database listens on. |
| `parameter_prefix` | Parameter Store path holding the connection settings. |
| `password_parameter_name` | Parameter holding the master password as a SecureString. |
| `proxy_endpoint` | Endpoint of the database proxy, or null when the proxy is not created. |
