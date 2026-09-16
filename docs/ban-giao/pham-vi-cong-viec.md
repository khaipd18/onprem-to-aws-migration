# Hạng mục và phạm vi công việc

Yêu cầu cho 2 tuần và yêu cầu **chủ động thu hẹp phạm vi**, giải thích được lý do
chọn. File này là cam kết: làm gì, không làm gì, và vì sao.

---

## 1. Trong phạm vi — đã làm

### Hạ tầng

| Hạng mục | Mức độ |
|---|---|
| VPC 2 AZ, 3 tầng subnet, NAT, S3 endpoint | Đầy đủ |
| 6 security group xâu chuỗi theo tầng | Đầy đủ |
| ALB + target group + Auto Scaling 2–6 máy + warm pool | Đầy đủ |
| RDS PostgreSQL Multi-AZ + parameter group + RDS Proxy | Đầy đủ |
| SQS FIFO + DLQ, DynamoDB accept store | Đầy đủ |
| S3 + CloudFront cho SPA | Đầy đủ |
| EFS + 6 access point phân quyền phòng ban | Đầy đủ |
| IAM role, SSM Parameter Store, Secrets Manager | Đầy đủ |
| CloudWatch: 8 alarm, metric filter, 4 truy vấn lưu sẵn, dashboard | Đầy đủ |
| DMS + DataSync | Đã dựng, chưa chạy migration thật |

**Toàn bộ viết bằng Terraform**, 11 module, đã apply thật 165 tài nguyên và
destroy sạch.

### Ứng dụng demo

Không phải sản phẩm thương mại, chỉ đủ để chứng minh các ràng buộc:

| Có | Không có |
|---|---|
| Nhận đơn, xem đơn, sửa đơn | Giao diện đẹp |
| Chống trùng 3 tuyến | Đăng nhập, phân quyền người dùng |
| Optimistic locking | Thanh toán, tồn kho, vận chuyển |
| Báo cáo có mốc chốt | Báo cáo nhiều loại |
| Worker xử lý hàng đợi | Gửi email, thông báo |

### Tài liệu

Kỹ thuật, triển khai, vận hành, migration, chi phí, lý do chọn dịch vụ.

### Kiểm thử

6 kịch bản, 58 phép kiểm chứng, chạy ở môi trường local dựng đúng hình dạng AWS.

---

## 2. Ngoài phạm vi — không làm, kèm lý do

### Bỏ vì yêu cầu không yêu cầu

| Không làm | Lý do |
|---|---|
| **Đăng nhập người dùng (Cognito)** | Yêu cầu **không nhắc tới xác thực**. Người nhập đơn là nhân viên nội bộ, nhập thay cho khách. Không có khách tự đăng nhập |
| **Thanh toán, tồn kho, vận chuyển** | Yêu cầu tập trung vào hạ tầng và tính đúng đắn giao dịch, không phải nghiệp vụ bán hàng đầy đủ |
| **Giao diện hoàn chỉnh** | Chỉ cần đủ để demo các ràng buộc |

### Bỏ vì không đủ thời gian, khuyến nghị giai đoạn sau

| Không làm | Chi phí nếu làm | Khuyến nghị |
|---|---|---|
| **WAF** | ~21 USD/tháng | Nên có khi mở ra internet thật |
| **GuardDuty, Security Hub** | ~30 USD/tháng | Giai đoạn vận hành ổn định |
| **CI/CD đầy đủ** | 0 | Đã làm phần cốt lõi: artifact có phiên bản, thay máy từng nửa, cổng health check. Còn thiếu nối GitHub Actions |
| **X-Ray** | theo trace | Correlation id trong log đã đủ truy vết. X-Ray đáng giá khi có hàng chục microservice |

### Bỏ vì có cách rẻ hơn đạt cùng mục tiêu

| Không làm | Thay bằng |
|---|---|
| **ECR + Docker** | Tiến trình Python chạy bằng systemd. Cài Docker lên mỗi máy chỉ để chạy một tiến trình là thừa |
| **Synthetics canary** | Chạy 1 phút/lần, **không đủ phân giải** cho ngân sách gián đoạn 2 phút. Dùng vòng lặp curl 1 giây |
| **VPC Interface Endpoint** | 3 endpoint × 2 AZ ≈ 44 USD/tháng, **đắt hơn cả NAT**. Dùng S3 Gateway Endpoint (miễn phí) cho phần lớn lưu lượng |
| **NAT thứ hai** | Tiết kiệm 43 USD/tháng. Mất đường **ra** internet nếu AZ chứa NAT chết; traffic **vào** đi qua ALB nên nhận đơn không ảnh hưởng |

### Bỏ vì bị chặn ngoài tầm kiểm soát

| Không làm | Lý do |
|---|---|
| **RDS Read Replica** | `rds:CreateDBInstanceReadReplica` bị **SCP chặn ở cấp Organization**. IT của tài khoản không gỡ được. Báo cáo chạy trên primary với mốc chốt tường minh, đo được p95 61 ms |
| **Chứng chỉ ACM riêng** | Không được cấp quyền. Dùng chứng chỉ mặc định của CloudFront, vẫn được trình duyệt tin cậy |

---

## 3. Làm một phần — nói rõ đến đâu

| Hạng mục | Đã làm | Chưa làm |
|---|---|---|
| **Kiểm thử** | 6 kịch bản local 58/58, cộng 7 bài chạy trên AWS thật (A2, A3, A6, B2, B4, B5, B6) | B1 tải gấp 5 — cần EC2 riêng làm máy phát tải; phép so sánh có/không RDS Proxy |
| **Migration** | Dựng DMS + DataSync, viết kế hoạch chi tiết, đo cutover bằng logical replication (1,1 giây) | Chưa chạy DMS thật |
| **CI/CD** | Đóng gói có phiên bản, instance refresh, rollback một dòng | Chưa nối GitHub Actions |
| **Dữ liệu** | Thu nhỏ theo đúng cho phép của yêu cầu | Chưa chạy với 200 GB như production |

---

## 4. Giới hạn của môi trường thực hành

Những điều này **không phải lựa chọn**, mà là ràng buộc của tài khoản:

| Giới hạn | Ảnh hưởng |
|---|---|
| Trần 350 USD/tháng, dùng chung với người khác | Thiết kế production của SA là 1.100 USD, gấp 3,1 lần. Phải thu nhỏ còn 209 |
| Quyền cấp theo từng đợt, mất 5 lượt xin | Không apply được liên tục trong ngày đầu |
| SCP cấp Organization chặn read replica và instance class từ `4xlarge` | Không dùng được cấu hình lớn |

**Bản 208 USD không bỏ cam kết kỹ thuật nào** — vẫn Multi-AZ, vẫn RDS Proxy, vẫn
warm pool. Chỉ thu nhỏ dung lượng dữ liệu, đúng như yêu cầu cho phép.

---

## 5. Nếu có thêm 2 tuần nữa

Theo thứ tự ưu tiên:

```
1. Chạy 5 bài test còn lại trên AWS thật
2. Nối GitHub Actions vào quy trình release
3. Chạy migration thật bằng DMS, lấy Data Validation Report
4. Thêm WAF
5. Dựng môi trường staging riêng
```
