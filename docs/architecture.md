# Kiến trúc AWS — Migration hạ tầng On-premise sang AWS

Sáu sơ đồ, nguồn `.drawio` nằm trong [`diagrams/`](diagrams/), PNG xuất ra nằm trong
[`img/`](img/). Mở và sửa bằng [app.diagrams.net](https://app.diagrams.net) hoặc draw.io
Desktop. Dùng bộ **AWS Architecture Icons** chính thức (thư viện `mxgraph.aws4`).

| Sơ đồ | Nội dung |
|---|---|
| [`architecture`](diagrams/architecture.drawio) | Kiến trúc ở trạng thái vận hành |
| [`network`](diagrams/network.drawio) | VPC, subnet, route table, đường ra internet |
| [`security-groups`](diagrams/security-groups.drawio) | Chuỗi security group và cổng |
| [`request-flow`](diagrams/request-flow.drawio) | Vòng đời một đơn hàng, kèm nhánh hỏng |
| [`migration`](diagrams/migration.drawio) | DMS + DataSync và trình tự cutover |
| [`observability`](diagrams/observability.drawio) | 8 alarm, dashboard, truy vết `correlation_id` |

Mọi thành phần trên sơ đồ đều có resource tương ứng trong [`../deploy/terraform/`](../deploy/terraform/).

---

## Luồng request bình thường

| # | Bước | Thành phần |
|---|---|---|
| 1 | Người dùng mở trang | CloudFront → S3 (SPA tĩnh, qua Origin Access Control) |
| 2 | Trình duyệt gọi `POST /api/orders` | CloudFront behavior `/api/*`, cache disabled, giữ nguyên header `Idempotency-Key` |
| 3 | Vào VPC | Internet Gateway → Application Load Balancer (`:80`) |
| 4 | Xuống App tier | ALB → EC2 `:8080`, health check `/ready` mỗi 10s, ngưỡng 2/2 |
| 5 | Chặn đơn trùng | EC2 → DynamoDB `PutItem` với `ConditionExpression` — lần gửi lại thứ hai bị chặn ngay đây |
| 6 | Xếp hàng | EC2 → SQS FIFO, `MessageGroupId` = mã khách, `MessageDeduplicationId` = Idempotency-Key |
| 7 | Trả lời | HTTP **202 Accepted**, `status: PENDING` — chưa phải "thành công" |
| 8 | Worker xử lý | long poll SQS 20s → RDS Proxy (TLS) → RDS PostgreSQL 16 Multi-AZ |
| 9 | Chốt giao dịch | Commit xong worker mới xoá message; đơn chuyển `PENDING` → `CONFIRMED` |

Quy tắc cốt lõi: **API không bao giờ báo thành công trước khi database commit.** Toàn bộ
hành vi chịu lỗi của hệ thống là hệ quả của đúng một câu đó.

## Hai luồng migration (đường màu xanh lục trên sơ đồ)

| Nguồn | Công cụ | Đích |
|---|---|---|
| PostgreSQL on-premise | **DMS** — `full-load-and-cdc`, replication instance trong data subnet, không public | RDS PostgreSQL primary |
| File server on-premise | Đẩy lên **S3 staging** rồi **DataSync** đồng bộ | EFS file system |

Hai luồng chạy song song, độc lập nhau — file server cutover trước vì rủi ro thấp và
rollback dễ, database cutover sau.

## Mạng

| Tầng | Route 0.0.0.0/0 | Chứa gì |
|---|---|---|
| public subnet · 2 AZ | → Internet Gateway | ALB, NAT Gateway |
| private subnet · 2 AZ | → NAT Gateway (một chiều) | EC2 App tier + Worker |
| data subnet · 2 AZ | **không có** | RDS, RDS Proxy, EFS mount target, DMS, DataSync |

Điều phân biệt `private` với `data` là **route table**, không phải cái tên. Tầng `data`
chỉ có route `local`; gộp hai tầng lại thì RDS có đường ra internet và mất hẳn tính tách biệt.

Chỉ có **một NAT Gateway**, đặt ở AZ 1a, cả hai private subnet cùng route qua nó. Đây là
đánh đổi chi phí có chủ ý (~43 USD/tháng cho cái thứ hai), đổi lại là mất đường ra internet
nếu AZ 1a chết — traffic đi vào không ảnh hưởng.

## Security group

| Security group | Cho vào | Từ đâu |
|---|---|---|
| `sg-alb-public` | 80, 443 | `0.0.0.0/0` |
| `sg-app` | 8080 | `sg-alb-public` |
| `sg-rds-proxy` | 5432 | `sg-app` |
| `sg-rds` | 5432 | `sg-rds-proxy` **và** `sg-app` (đường dự phòng khi proxy lỗi) |
| `sg-fileserver` | 2049 | `sg-app`, `sg-admin-client` |
| `sg-admin-client` | — | không có inbound; tồn tại để được tham chiếu làm nguồn |

Không security group nào mở bằng dải CIDR ngoài `sg-alb-public`; còn lại đều tham chiếu
security group khác làm nguồn.

## Dịch vụ region ngoài VPC

| Dịch vụ | Vai trò |
|---|---|
| S3 · SPA assets | Bundle giao diện, chỉ CloudFront đọc được qua OAC |
| S3 · artifacts | Bản build ứng dụng, EC2 tải lúc khởi động |
| S3 · ALB access log | Log truy cập, lifecycle 30 ngày |
| S3 · staging | File nguồn cho DataSync — **nằm ngoài Terraform stack**, truyền vào bằng biến |
| DynamoDB | Accept store chống đơn trùng, đặt ngoài RDS để còn đọc được khi RDS chết |
| SQS FIFO + DLQ | Hàng đợi đơn hàng, có redrive policy |
| EFS file system | Access point riêng cho từng phòng ban (`0770`) + một access point chung `/public` (`0775`) |
| Secrets Manager | Mật khẩu master của RDS, RDS Proxy dùng để xác thực |
| Systems Manager Parameter Store | 5 tham số kết nối DB, EC2 đọc lúc khởi động |
| CloudWatch | Log group, metric filter, dashboard, 8 alarm, 4 truy vấn Logs Insights dựng sẵn |
| SNS | Gửi cảnh báo qua email khi alarm kích hoạt |

## Quyết định thiết kế đáng chú ý

**Web tier không phải EC2.** Thiết kế ban đầu có hai tầng EC2; ở mốc chốt phạm vi đã đổi
Web tier sang SPA tĩnh trên CloudFront + S3. Vẫn giữ được yêu cầu tách biệt Web/App mà
tiết kiệm khoảng 47 USD/tháng và bỏ hẳn một tầng cần vá lỗi.

**DynamoDB nằm ngoài RDS là có chủ ý.** Nếu accept store dùng chung database với bảng
`orders` thì khi RDS chết, cơ chế chống trùng cũng chết theo — đúng lúc cần nó nhất.

**RDS Proxy gộp connection.** Instance `t4g.micro` chỉ chịu được số kết nối hạn chế, trong
khi ASG có thể lên 6 máy. Proxy hấp thụ phần đó, đồng thời giữ kết nối qua failover Multi-AZ.

**Warm pool ở trạng thái Stopped.** Máy dự phòng sẵn sàng trong 30–40 giây thay vì 2–3 phút,
mà chỉ tốn tiền ổ đĩa (~0,6 USD/tháng).

## Sinh lại ảnh

File `.drawio` trong `diagrams/` là nguồn duy nhất. Export bằng draw.io Desktop, chạy từ
thư mục gốc của repo:

```bash
for f in architecture network security-groups request-flow migration observability; do
  drawio -x -f png -b 24 --width 1900 -o "docs/img/$f.png" "docs/diagrams/$f.drawio"
done
```

Thêm cờ `-e` nếu muốn nhúng XML vào chính file PNG, khi đó ảnh xuất ra vẫn mở và sửa lại
được trong draw.io — đổi lại là file nặng hơn đáng kể.
