# `fileserver`

EFS thay cho file server on-premise. Phân quyền theo phòng ban bằng access point, không bằng user/password.

## Kiến trúc

```
   EC2 App tier (sg-app)
        │ NFS 2049, TLS bắt buộc
        ▼
   mount target ở mỗi AZ (subnet data)
        │
   ┌────┴─────────────────────────────────────────┐
   │  EFS file system  (mã hoá, key aws/efs)      │
   │                                              │
   │  access point sales      → /sales      uid 6001 gid 5001  0770
   │  access point finance    → /finance    uid 6002 gid 5002  0770
   │  access point hr         → /hr         uid 6003 gid 5003  0770
   │  access point production → /production uid 6004 gid 5004  0770
   │  access point purchasing → /purchasing uid 6005 gid 5005  0770
   │  access point shared     → /shared     uid 6000 gid 5000  0770
   └──────────────────────────────────────────────┘
```

## Vì sao EFS chứ không phải FSx

Yêu cầu chỉ nói "File Server dùng chung cho các phòng ban", không nói hệ điều hành. Giả định ghi ở `../../../../docs/ban-giao/gia-dinh.md`: on-premise chạy Linux, chia sẻ qua NFS, phân quyền bằng POSIX.

Với giả định đó thì EFS là ánh xạ một–một: cùng NFS, cùng mô hình uid/gid/mode. FSx for Windows hợp khi phía cũ là Windows + SMB + Active Directory — không phải trường hợp này, và nó đắt hơn nhiều.

## Access point làm gì cho ràng buộc #7

Ràng buộc #7 yêu cầu phân quyền theo phòng ban và **thu hồi quyền trong ≤ 5 phút**.

Access point ép danh tính từ phía server: `posix_user` quyết định instance mount qua nó **là ai**, bất kể tiến trình trên máy chạy dưới uid nào. Client không có cách nào tự khai mình thuộc phòng khác.

Thu hồi: xoá access point hoặc sửa policy của access point đó. Chặn **mount mới** ngay lập tức, không cần đợi cache credential hết hạn như mô hình user/password.

**Đo thật ngày 12/09/2026 (`evidence/aws-A6-efs-revoke-*.log`):** xoá access point **không** cắt được phiên đang mount. Mount đang mở vẫn đọc ghi bình thường suốt 283 giây, không hỏng lần nào. Lý do: NFS client giữ file handle đã mở, EFS kiểm access point ở thời điểm **mount**, không kiểm lại ở từng thao tác đọc ghi.

Vì vậy quy trình thu hồi 5 phút phải có hai bước:

1. Xoá access point (hoặc sửa policy) — chặn mọi mount mới.
2. Ép `umount -f` trên các máy đang mount, qua SSM `send-command`. Vài giây là xong vì đây là thao tác chủ động, không chờ client tự phát hiện.

Không dùng cách gỡ rule 2049 khỏi security group: đo thật cho thấy NFS không lỗi ngay mà **block**, uvicorn treo theo, `/ready` quá hạn, ALB đánh unhealthy và ASG thay máy sau 13–52 giây.

`root_directory.creation_info` với `permissions = "0770"` nghĩa là chỉ owner và group đọc/ghi được, phòng khác không vào được thư mục.

## Thư mục dùng chung

Access point `shared` gắn gid `5000` — group mà mọi nhân viên đều thuộc, cộng `secondary_gids` là gid của cả năm phòng ban. Đây là chỗ cho tài liệu toàn công ty.

Năm phòng ban và số uid/gid trùng khớp với `deploy/local/fileserver-entrypoint.sh` của môi trường on-premise, để bản chép sang EFS giữ nguyên quyền.

## File system policy

Policy trên file system yêu cầu hai điều:

1. **`aws:SecureTransport = true`** — từ chối mount không có TLS. Dữ liệu qua đường truyền trong VPC vẫn được mã hoá.
2. **Mount phải qua access point** — từ chối request không mang `elasticfilesystem:AccessPointArn`. Không có dòng này thì một máy có quyền IAM đủ rộng vẫn mount thẳng gốc file system và đọc hết mọi phòng ban, vô hiệu hoá toàn bộ phần phân quyền ở trên.

## Lifecycle sang Infrequent Access

`transition_to_ia` sau N ngày không truy cập. File tài liệu cũ chuyển sang lớp lưu trữ rẻ hơn khoảng 90%, chi phí truy cập cao hơn khi cần đọc lại. Hợp với file server: phần lớn file ghi một lần rồi hiếm khi mở lại.

## Mount target ở mỗi AZ

Instance trong một AZ phải nối tới mount target trong **chính AZ đó**. Đi chéo AZ vừa tốn phí truyền dữ liệu vừa mất luôn khả năng chịu lỗi. `count = length(var.subnet_ids)` nên thêm subnet data ở AZ mới là tự có mount target.

## Tài nguyên tạo ra

- `aws_efs_access_point.department`
- `aws_efs_access_point.shared`
- `aws_efs_backup_policy.main`
- `aws_efs_file_system.main`
- `aws_efs_file_system_policy.main`
- `aws_efs_mount_target.main`

## Biến

| Tên | Mô tả | Mặc định |
|---|---|---|
| `departments` | Departments that get their own access point. | xem `variables.tf` |
| `name_prefix` | Prefix applied to every resource name in this module. | **bắt buộc** |
| `security_group_ids` | Security groups attached to the mount targets. Must allow port 2049 from the application tier. | **bắt buộc** |
| `shared_gid` | Group every department belongs to, for the folder the whole company can read. | `5000` |
| `subnet_ids` | Isolated subnets the mount targets live in, one per availability zone. | **bắt buộc** |
| `transition_to_ia_days` | Days a file goes untouched before it moves to the cheaper infrequent access class. | `30` |

## Đầu ra

| Tên | Mô tả |
|---|---|
| `access_point_arns` | Access point ARNs by department, plus the shared one. |
| `access_point_ids` | Access point IDs by department, for the mount command. |
| `dns_name` | Hostname instances mount. |
| `file_system_arn` | ARN of the file system. |
| `file_system_id` | ID of the file system. |
| `mount_command_example` | How a department mounts its own folder. The access point decides the identity, so the command carries no user or password. |
