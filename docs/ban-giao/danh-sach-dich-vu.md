# Danh sách AWS Service — vai trò Cloud Engineer

Bản rút gọn. Chi tiết thông số xem [`thong-so-ky-thuat.md`](thong-so-ky-thuat.md).
Các bước bấm Console xem [`huong-dan-console.md`](huong-dan-console.md).

Region: `ap-southeast-1` (Singapore)

---

## 1. Bắt buộc — không có thì trượt ràng buộc

### Mạng
| Service | Dùng để làm gì |
|---|---|
| **VPC** | 2 AZ, 6 subnet: public / private-app / isolated-db |
| **Internet Gateway** | Lối ra internet cho ALB |
| **NAT Gateway** | 1 cái, cho private subnet kéo update và gọi API AWS |
| **VPC Endpoint (S3)** | Gateway endpoint, **miễn phí**, giảm phí NAT |
| **Security Group** | 6 SG xâu chuỗi: alb → web → alb-internal → app → proxy → rds |

### Compute
| Service | Dùng để làm gì |
|---|---|
| **ALB** (internet-facing) | Nhận traffic, health check 10s → phát hiện target chết trong 20s |
| **ALB** (internal) | Tách Web tier khỏi App tier |
| **EC2** `t4g.medium` | Chạy Web tier và App tier (2 ASG riêng) |
| **Auto Scaling Group** ×3 | web / app / worker. min 2, max 8, 2 AZ |
| **ASG Warm Pool** | 2 instance `Stopped` → scale-out 40s thay vì 2–4 phút |
| **ECR** | Chứa container image |
| **ACM** | Cert HTTPS cho ALB (miễn phí) |

### Dữ liệu
| Service | Dùng để làm gì |
|---|---|
| **RDS PostgreSQL** Multi-AZ | Database chính. `db.t4g.medium`, gp3 100GB, backup 7 ngày |
| **RDS Read Replica** | Gánh job báo cáo → không làm chậm đơn hàng |
| **RDS Proxy** | Nuốt failover, app tự phục hồi không cần restart |
| **DynamoDB** | Lưu đơn đã tiếp nhận — sống sót khi RDS chết |
| **SQS FIFO + DLQ** | Hàng đợi bền giữa App và DB |

### File Server
| Service | Dùng để làm gì |
|---|---|
| **EFS** | File server, Elastic throughput, lifecycle sang IA sau 30 ngày |
| **EFS Access Point** | Mỗi phòng ban một access point, ép sẵn UID/GID và root directory |

> **Đã chốt: Linux/NFS.** Yêu cầu chỉ nói "File Server dùng chung cho các phòng ban", không nêu hệ điều hành — giả định ghi ở `gia-dinh.md`. Quyền theo phòng ban làm bằng POSIX group + mode 2770 ở nguồn, sang đích thì mỗi phòng một EFS Access Point.
>
> Nhánh FSx for Windows + Managed Microsoft AD đã bỏ khỏi phạm vi: đắt hơn ~110 USD/tháng và không cần thiết khi nguồn là Linux.

### Migration
| Service | Dùng để làm gì |
|---|---|
| **DMS** | Full load + CDC PostgreSQL, downtime cutover ≤ 15 phút |
| **DataSync** | Copy file server kèm quyền POSIX sang EFS |

### Vận hành & bảo mật
| Service | Dùng để làm gì |
|---|---|
| **CloudWatch** | Log, metric, 8 alarm, dashboard |
| **CloudWatch Synthetics** | Canary 1 phút — đo thời gian gián đoạn |
| **SNS** | Gửi alarm về email |
| **Systems Manager (Session Manager)** | Thay SSH — không mở port 22 ra internet |
| **Secrets Manager** | Mật khẩu DB, RDS Proxy đọc trực tiếp |
| **KMS** | Không tạo CMK — dùng key mặc định của từng dịch vụ (`aws/rds`, `aws/ssm`, `aws/elasticfilesystem`…) |
| **IAM** | Role cho từng tier, **không dùng access key tĩnh** |
| **S3** | ALB access log, artifact, backup |
| **AWS Backup** | Backup tập trung RDS + EFS |
| **CloudTrail** | Audit |
| **AWS Budgets** | Cảnh báo ngân sách — bật TRƯỚC khi tạo tài nguyên |

---

## 2. Cắt được nếu thiếu thời gian

| Service | Cắt thì mất gì |
|---|---|
| **X-Ray** | Thay bằng correlation ID trong log — vẫn đạt ràng buộc #8 |
| **WAF** | Bảo vệ tầng ứng dụng. Ghi "khuyến nghị giai đoạn sau" |
| **GuardDuty / Security Hub** | Phát hiện mối đe doạ |
| **CloudFront** | Không giúp gì cho API POST. Bỏ |
| **ElastiCache** | Chỉ thêm nếu load test chỉ ra DB là nút thắt |
| **CodePipeline/CodeDeploy** | Yêu cầu chỉ đòi CI/CD **mức concept** — dùng GitHub Actions + OIDC |

---

## 3. Ràng buộc nào cần service nào

| # | Ràng buộc | Service quyết định | Bằng chứng |
|---|---|---|---|
| 1 | Chạy hoàn toàn trên AWS | tất cả | `test-a1` — sau cutover đích ghi được đơn mới trong khi nguồn đã dừng |
| 2 | Downtime ≤ 15', không mất/trùng | **DMS** (full load + CDC + Data Validation) | `test-a1` — downtime 0.8s, 2086 đơn khớp, 0 trùng |
| 3 | Không đơn trùng, không ghi đè | **SQS FIFO** + **DynamoDB** + optimistic locking | `test-a2`, `test-a3` |
| 4 | Tải 5x, p95 ≤ 2s, lỗi ≤ 1% | **ASG + Warm Pool** + **ALB** + **RDS Proxy** | `loadtest/k6/order-load.js` |
| 4 | Thành phần chết, gián đoạn ≤ 2' | **≥2 instance / 2 AZ** + ALB health check 10s×2 | phát hiện ~20s |
| 5 | DB chết 3', tự phục hồi | **RDS Proxy** + **RDS Multi-AZ** + **SQS** | `test-b4` — hồi phục 22s, không restart |
| 6 | RPO 5' / RTO 30' | **RDS PITR** (backup 7 ngày, `delete_automated_backups=false`) | **chưa đo** — phải đo trên RDS thật |
| 7 | File Server giữ quyền phòng ban | **EFS + Access Point** + **DataSync** | `test-a5` — 30/30, chéo phòng ban đều bị từ chối |
| 8 | Truy vết giao dịch | **CloudWatch Logs Insights** + `correlation_id` | 4 truy vấn lưu sẵn trong `modules/observability` |
| 8 | Dựng lại từ hồ sơ bàn giao | **Terraform**, 9 module, 171 resource | `terraform plan` sạch |
| 9 | Kiểm soát chi phí | **tag `owner` bắt buộc** + AWS Pricing Calculator | mục 4 tài liệu này |
| 10 | Job báo cáo không phá OLTP | `REPEATABLE READ` + `statement_timeout` + lệch giờ | `test-b8` |

**Ba chỗ khác với thiết kế ban đầu, đều có lý do:**

- **#10 không dùng Read Replica.** `rds:CreateDBInstanceReadReplica` bị SCP của Organization chặn thẳng (`p-zvb9d6hn`). Thay bằng chạy báo cáo trên primary trong transaction `REPEATABLE READ` để có mốc chốt nhất quán.
- **#8 dùng Terraform, không dùng CloudFormation.** Yêu cầu chỉ yêu cầu dựng lại được từ hồ sơ; Terraform đáp ứng và đã có sẵn.
- **#9 không dùng Budgets/Cost Explorer.** Đó là dữ liệu thanh toán ở cấp tổ chức. Thay bằng tag `owner` trên mọi resource (đã kiểm chứng 115/115) cộng ước tính bằng Pricing Calculator.

---

## 4. Chi phí ước tính

> Giá ước tính cho `ap-southeast-1`. **Chưa xác nhận bằng AWS Pricing Calculator** — `pricing:GetProducts` bị chặn nên không lấy được giá chính thức. Phải kiểm lại trước khi đưa vào báo giá.

### Chi phí

Giá thật `ap-southeast-1`. Bảng đầy đủ ở `chi-phi.md`.

| | USD/tháng |
|---|---|
| **Báo giá khách hàng** (production, bản SA) | **1.100,51** |
| **Môi trường demo** 24/7 | 207,82 — 59% trần |
| **Môi trường demo** 8 giờ/ngày × 5 ngày | **71,05** — 20% trần ← khuyến nghị |
| Môi trường demo, tắt hoàn toàn | 29,50 — 8% trần |

Cộng **khoảng 0,22 USD một lần** cho DMS. DataSync chạy agentless (S3 → EFS) nên gần như miễn phí.

```
chi phí demo = 0,2456 × số giờ chạy + 29,50
```

Tắt bằng `./scripts/aws-env.sh down`.

### Đã cắt so với thiết kế đầu (452 → 257)

| Cắt | Tiết kiệm | Có mất ràng buộc nào không |
|---|---|---|
| `t4g.medium` → `t4g.small`, 5 máy → 4 | ~107 | Không. Tiến trình Python chờ database là chính |
| `db.t4g.medium` → `db.t4g.micro`, **vẫn Multi-AZ** | ~102 | Không. Multi-AZ chạy được trên `micro`, hình dạng triển khai giữ nguyên |
| Worker gộp vào tầng App | ~32 | Không. Vẫn là tiến trình riêng, unit systemd riêng |
| **RDS Proxy** | ~22 | Không. `test-b4` đã đạt mà không có Proxy: hồi phục 22s, 6/6 đơn `CONFIRMED`, không restart |
| **DMS + DataSync** | dùng `dms.t3.micro` và DataSync agentless thay vì `t3.medium` + agent `m5.2xlarge` | Không. `test-a1` đã chứng minh #2 bằng logical replication gốc: downtime 0,8s, 2086 đơn khớp, 0 trùng |
| Thêm **S3 Gateway Endpoint** | giảm phí xử lý của NAT | Miễn phí |

DataSync agent chạy trên `m5.2xlarge` (~374 USD/tháng nếu để quên) — đã bỏ hẳn bằng cách đưa file qua S3 rồi DataSync S3 → EFS, chạy agentless.

### Khi bị cắt 20% ngân sách (ràng buộc #9)

Cần cắt ~92 USD trên nền ~460.

| Cắt gì | Tiết kiệm | Đánh đổi |
|---|---|---|
| Bỏ **Read Replica** | ~60 | Job báo cáo chạy trên primary → rủi ro ràng buộc #10. **Thực tế đã mất sẵn**: SCP của Organization chặn `rds:CreateDBInstanceReadReplica` |
| **Savings Plan** 1 năm cho EC2 | ~28 | Cam kết 1 năm, không ảnh hưởng kỹ thuật |
| Web tier `t4g.medium` → `t4g.small` | ~15 | Web tier chỉ chuyển tiếp request, ít tốn CPU. Phải chạy lại test B1 để chứng minh vẫn đạt p95 |
| ~~Multi-AZ → Single-AZ~~ | ~~75~~ | **Không làm** — phá trực tiếp ràng buộc #5 |



Cắt 2 dòng đầu = ~170 USD (30%), thừa yêu cầu. Trình bày kèm đánh đổi rõ ràng.
