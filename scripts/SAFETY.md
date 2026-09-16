# Quy tắc khi viết script dò quyền

Rút ra sau khi dò quyền làm hỏng tài nguyên thật ngày 2026-09-11.

## Chuyện đã xảy ra

Dò `rds:DeleteDBProxy` bằng tên proxy thật → **xoá luôn proxy đang chạy**.
Dò `secretsmanager:PutSecretValue` bằng secret id thật → **ghi đè mật khẩu
master thành chuỗi `x`**, RDS Proxy mất khả năng xác thực.
Dò `sqs:CreateQueue` bằng tên hợp lệ → **tạo thật một queue**.

Khôi phục được bằng `terraform apply` vì Terraform giữ giá trị đúng trong
state. Nhưng nếu là môi trường thật thì đã thành sự cố.

## Ba quy tắc

**1. Hành động GHI hoặc XOÁ phải dùng tên không tồn tại.**

Đặt hậu tố cố định, không bao giờ trùng tài nguyên đang chạy:

    PROBE="$PREFIX-zzprobe-khong-dung"

**2. Hành động TẠO phải kèm một tham số chắc chắn sai.**

Để AWS từ chối ở bước validate sau khi đã xét quyền. Ví dụ `--policy sai`,
`--performance-mode SAI`. Tuyệt đối không gọi một lệnh tạo hợp lệ hoàn toàn.

**3. Đọc xem AWS từ chối hành động NÀO, đừng chỉ kiểm AccessDenied.**

    denied=$(grep -o 'to perform: [a-zA-Z0-9:_-]*' <<<"$out" | head -1 | cut -d' ' -f3)

Nếu `denied` khác hành động đang test thì **không kết luận được**. Ví dụ
`rds:CreateDBProxy` bị từ chối ở `iam:PassRole` — điều đó không nói gì về
quyền tạo proxy.

## Ba kiểu báo sai đã gặp

| Kiểu | Ví dụ |
|---|---|
| AWS validate tham số trước khi xét quyền | `iam:CreateRole` với tên có dấu cách → ValidationError, tưởng là có quyền |
| Bị chặn ở hành động khác | `rds:CreateDBCluster` báo deny trên `rds:CreateDBInstance` |
| Quyền giới hạn theo tên tài nguyên | probe bằng `khong-ton-tai` trong khi quyền chỉ cấp cho `abc-migration-*` |
