# Chi phí

**Tài khoản:** `123456789012` · region `ap-southeast-1` · **trần 350 USD/tháng cho toàn bộ tài khoản, dùng chung với người khác**
**Cập nhật:** 2026-09-10

Tài liệu này tách làm hai phần vì chúng trả lời hai câu hỏi khác nhau:

| | Trả lời cho ai | Quy mô |
|---|---|---|
| **Phần A** — Báo giá khách hàng | ABC Manufacturing | Production thật: 500 GB file, 200 GB database |
| **Phần B** — Chi phí môi trường demo | Nhóm thực hành | Thu nhỏ theo cho phép của yêu cầu |

Yêu cầu cho phép *"thu nhỏ dung lượng dữ liệu thực hành nhưng phải giữ đầy đủ các hành vi"*. Hai con số khác nhau là đúng — điều quan trọng là nói rõ vì sao.

---

# PHẦN A — Báo giá cho khách hàng

Quy mô production, do SA dựng trên AWS Pricing Calculator.

| Dịch vụ | Cấu hình | USD/tháng |
|---|---|---|
| RDS primary | `db.t4g.large` Multi-AZ + 200 GB gp3 + RDS Proxy + Database Insights | 396,11 |
| DMS | `t3.medium` Multi-AZ + 100 GB, chạy liên tục | 191,12 |
| EFS | 500 GB Standard + Elastic throughput | 149,40 |
| RDS read replica | `db.t4g.medium` Single-AZ + 200 GB + Database Insights | 120,31 |
| NAT Gateway | Regional, 2 AZ + 100 GB xử lý | 92,04 |
| EC2 | 2 × `t3.large` | 86,96 |
| ALB | 1 cái + LCU | 21,32 |
| WAF | 1 Web ACL + 5 rule + 2 managed rule group + 15 triệu request | 21,00 |
| DataSync | 1.000 GB | 12,50 |
| Data transfer | 50 GB ra internet + 20 GB giữa AZ | 6,40 |
| SQS FIFO | 3 triệu request | 1,50 |
| Secrets Manager | 4 secret + 50.000 lời gọi | 1,85 |
| **Tổng** | | **1.100,51** |

Đây là con số đưa vào báo giá cho khách hàng. Nó phản ánh hệ thống thật của ABC: 150 người dùng, 500 GB tài liệu, cơ sở dữ liệu tăng trưởng theo năm.

---

# PHẦN B — Chi phí môi trường demo

Cùng kiến trúc, thu nhỏ dữ liệu. Đây là con số **thực sự tính vào trần 350** của tài khoản.

## B.1 Kiến trúc

```
Người dùng
   │ HTTPS
   ▼
CloudFront ──────► S3        SPA tĩnh, ảnh sản phẩm
   │
   ▼ HTTP
ALB public (1 cái)
   │
   ▼
ASG App tier   2 × t4g.small, warm pool 2, private subnet
   │
   ├─► RDS Proxy ──► RDS primary db.t4g.micro Multi-AZ
   │                 RDS read replica db.t4g.micro
   ├─► SQS FIFO + DLQ
   ├─► DynamoDB      accept store
   └─► EFS           file server, Access Point mỗi phòng ban
```

Không có Web tier EC2 và không có ALB internal — giao diện là SPA tĩnh trên S3, phục vụ qua CloudFront. Tách biệt Web/App vẫn giữ, chỉ là ranh giới nằm giữa S3/CloudFront và ALB/EC2 thay vì giữa hai tầng EC2.

## B.2 Chi phí theo giờ — tắt là hết

| Hạng mục | USD/giờ | USD/tháng | Nguồn giá |
|---|---|---|---|
| EC2 2 × `t4g.small` | 0,0424 | 30,95 | Calculator |
| NAT Gateway 1 cái | 0,0590 | 43,07 | trang giá |
| RDS primary `db.t4g.micro` Multi-AZ | 0,0510 | 37,23 | suy ra |
| RDS Proxy 2 vCPU | 0,0360 | 26,28 | trang giá |
| ALB public | 0,0252 | 18,40 | Calculator |
| RDS read replica `db.t4g.micro` | 0,0255 | 18,61 | suy ra |
| EC2 detailed monitoring | 0,0058 | 4,20 | Calculator |
| ALB LCU (0,1) | 0,0008 | 0,58 | Calculator |
| **Cộng** | **0,2456** | **179,32** | |

## B.3 Chi phí theo tháng — tắt vẫn mất

| Hạng mục | USD/tháng | Nguồn giá |
|---|---|---|
| EBS 4 × 20 GB `gp3` = 80 GB | 7,68 | trang giá |
| RDS storage primary 20 GB Multi-AZ | 5,52 | trang giá |
| CloudFront 20 GB + 1 triệu request | 4,80 | Calculator |
| NAT xử lý 50 GB | 2,95 | trang giá |
| RDS storage replica 20 GB | 2,76 | trang giá |
| CloudWatch 9 alarm + 2 GB log | 2,16 | trang giá |
| EFS 1 GB + throughput | 0,70 | trang giá |
| Secrets Manager 1 secret + 50k lời gọi | 0,65 | trang giá |
| SQS FIFO 1 triệu request | 0,50 | trang giá |
| DynamoDB On-Demand | 0,50 | ước tính |
| S3 6 GB + request | 0,28 | Calculator |
| SNS 1.000 email | 0,00 | miễn phí |
| Data transfer 50 GB ra internet | 0,00 | 100 GB đầu miễn phí |
| **Cộng** | **28,50** | |

## B.4 Công thức

```
chi phí tháng = 0,2456 × số giờ chạy + 28,50
```

| Cách chạy | Giờ/ngày | USD/ngày | USD/tuần | USD/tháng | % trần 350 |
|---|---|---|---|---|---|
| Liên tục 24/7 | 24 | 6,83 | 47,84 | **207,82** | 59,4% |
| **8 giờ/ngày × 5 ngày làm việc** | 8 | **2,91** | **16,41** | **71,05** | **20,3%** ← khuyến nghị |
| 10 giờ/ngày × 5 ngày | 10 | 3,40 | 18,86 | 81,66 | 23,3% |
| Chỉ khi test và demo | — | — | 9,04 | 39,14 | 11,2% |
| Tắt hoàn toàn | 0 | 0,94 | 6,58 | 28,50 | 8,1% |

Cột USD/ngày là chi phí của **một ngày có chạy**; ngày nghỉ thì chỉ mất 0,94 USD. Cột USD/tuần đã tính cả ngày nghỉ cuối tuần.

**Tuần chuyển đổi**: 16,41 (vận hành) + 0,22 (DMS) = **16,63 USD**. Dữ liệu thực hành chỉ 7,7 MB file và 11 MB database nên hai công cụ đó chỉ cần chạy vài giờ.

## B.5 Chi phí một lần — tuần chuyển đổi

| Nguồn | Khối lượng thật | Thời gian truyền |
|---|---|---|
| File share | 7,7 MB — 41 file | vài giây |
| PostgreSQL | 11 MB — 2.844 đơn | vài giây |

| Dịch vụ | Cấu hình | USD |
|---|---|---|
| DMS | `dms.t3.micro` Single-AZ + 50 GB, chạy 6 giờ | 0,22 |
| DataSync | 0,0077 GB × 0,0125 USD/GB | 0,00 |
| EC2 cho DataSync agent | **không dùng** — chạy agentless | 0,00 |
| **Cộng** | | **0,22** |

**DataSync tính thuần theo gigabyte**, không chọn loại máy. Trên Pricing Calculator chỉ có đúng một ô: *"Total data copied per month"*. Máy agent nếu cần thì tính **riêng dưới mục EC2**, không nằm trong giá DataSync — đó là chỗ trước đây tôi gộp nhầm.

Và ở đây **không cần agent**: agent chỉ bắt buộc khi nguồn là NFS/SMB tự quản. Nguồn là S3, EFS hay FSx thì DataSync chạy agentless. Đưa file lên S3 trước bằng `aws s3 sync` rồi DataSync S3 → EFS.

### Đường đi

```
bước 1   aws s3 sync   từ máy nguồn lên S3       chỉ tốn PUT request, ~0,0002 USD
bước 2   DataSync      S3 → EFS, agentless       0,0077 GB × 0,0125 = 0,0001 USD
```

Nếu đi đường có agent thì phải dựng EC2 `m5.2xlarge` (0,512 USD/giờ) — cấu hình AWS khuyến nghị cho khối lượng tới 20 triệu file. Với 41 file thì hoàn toàn không cần, và khoản đó lại nằm ở hoá đơn EC2 chứ không phải hoá đơn DataSync.

Đánh đổi: kịch bản có thêm một bước trung gian qua S3 nên bớt giống "on-premise sang AWS" trực tiếp. Ở quy mô này đó là đánh đổi đáng.

### DMS cũng hạ xuống `t3.micro`

`dms.t3.medium` là mặc định hay dùng, nhưng 11 MB thì `t3.micro` thừa sức. Giảm từ 0,73 xuống 0,22 USD.

> **Cảnh báo:** rủi ro nằm ở chỗ **quên xoá**, không phải ở khối lượng dữ liệu. `dms.t3.micro` để quên một tháng là 20 USD. Bỏ agent đi thì cũng bỏ luôn được rủi ro 374 USD của `m5.2xlarge`.

---

# PHẦN C — Vì sao hai con số khác nhau

| Hạng mục | Phần A (production) | Phần B (demo) | Chênh |
|---|---|---|---|
| RDS primary | `db.t4g.large` Multi-AZ, 200 GB, + Insights | `db.t4g.micro`, 20 GB, không Insights | 396 → 43 |
| DMS | chạy **730 giờ** + 100 GB | chạy **5 ngày** rồi xoá | 191 → 29 (một lần) |
| EFS | 500 GB | 1 GB (dữ liệu demo thật ~8 MB) | 149 → 0,7 |
| RDS replica | `db.t4g.medium`, 200 GB, + Insights | `db.t4g.micro`, 20 GB, không Insights | 120 → 21 |
| NAT Gateway | **Regional, 2 AZ** | **1 cái, 1 AZ** | 92 → 46 |
| EC2 | 2 × `t3.large` | 2 × `t4g.small` | 87 → 35 |
| WAF | có | không dùng | 21 → 0 |
| CloudFront | không có | có | 0 → 4,80 |

## Ba điểm cần thống nhất với SA

**1. NAT Gateway: Regional 2 AZ hay 1 cái?**
Chênh 46 USD/tháng. Một NAT ở một AZ thì khi AZ đó chết, cả hai AZ mất đường ra internet. Không ảnh hưởng luồng nhận đơn (traffic vào đi qua ALB), chỉ ảnh hưởng lúc ASG scale out phải tải artifact từ S3 — mà đã có S3 Gateway Endpoint nên phần đó cũng không qua NAT.

**2. Database Insights — 18,25 USD mỗi instance.**
SA bật cho cả primary và replica = 36,50 USD/tháng. Performance Insights bản miễn phí (giữ 7 ngày) đủ cho phạm vi này. Đề nghị tắt ở môi trường demo, giữ trong báo giá production.

**3. DMS chạy 730 giờ hay 5 ngày?**
DMS là công cụ chuyển đổi một lần, xong cutover thì xoá. Trong báo giá production để 730 giờ là hợp lý nếu khách hàng muốn chạy đồng bộ liên tục dài ngày; ở demo thì 5 ngày là đủ.

---

# PHẦN D — Cách kiểm soát

## D.1 Tắt và bật

```bash
./scripts/aws-env.sh status    # đang chạy gì, tốn bao nhiêu mỗi giờ
./scripts/aws-env.sh down      # tắt: ASG về 0, dừng RDS
./scripts/aws-env.sh up        # bật lại, ~5 phút
./scripts/aws-env.sh scale     # đưa ASG về mức thường sau khi RDS sẵn sàng
```

Script lọc theo tag `owner=khaipd18` nên không đếm nhầm resource của người khác.

**Không dùng `terraform destroy` để tắt** — nó xoá cả RDS và mất dữ liệu test.

RDS chỉ dừng được tối đa **7 ngày**, sau đó AWS tự bật lại. Nghỉ dài hơn thì chạy lại `down`.

## D.2 Hai chỗ dễ sai khi nhập Pricing Calculator

**EBS bị nhân đôi.** Ô "Storage amount" trong phần EBS của Calculator là **dung lượng mỗi instance**, không phải tổng. Nhập 80 GB với 2 instance thì nó tính 160 GB = 15,36 USD. Thiết kế thật là 80 GB tổng (4 khối × 20 GB: 2 máy chạy + 2 máy warm pool). Nhập **40 GB** để ra đúng 7,68 USD.

**Máy tắt vẫn tính tiền EBS.** Hai instance trong warm pool đang ở trạng thái `Stopped` nhưng ổ đĩa vẫn tồn tại nên vẫn tính phí. Đó là lý do có 4 khối chứ không phải 2.

## D.3 Giá suy ra, chưa tra được trực tiếp

`db.t4g.micro` không có trên bảng giá đã tra. Suy từ `db.t4g.medium` Single-AZ = 0,102 USD/giờ, họ `t4g` tăng tuyến tính theo cỡ (`medium` = 4 × `micro`):

```
db.t4g.micro Single-AZ  ≈ 0,0255 USD/giờ
db.t4g.micro Multi-AZ   ≈ 0,0510 USD/giờ
```

Nếu cần con số chính thức thì tra lại trên Calculator; sai lệch nếu có cũng chỉ vài USD/tháng.

---

# PHẦN E — Trả lời ràng buộc #9

> "Kiểm soát chi phí: Giải pháp phải nằm trong ngân sách đã thống nhất, bao gồm tải cao điểm, backup, truyền dữ liệu và tăng trưởng lưu trữ. Khi ngân sách giảm 20%, phải đề xuất điều chỉnh và chỉ rõ ảnh hưởng đến các cam kết kỹ thuật."

Tình huống này đã xảy ra thật trong quá trình làm: bản theo quy mô production là **1.100 USD**, trong khi tài khoản thực hành có trần **350** và còn dùng chung với người khác.

**Đã đưa về 208 USD mà không bỏ ràng buộc nào** — thu nhỏ dữ liệu thực hành theo đúng cho phép của yêu cầu, giữ nguyên Multi-AZ, giữ RDS Proxy, giữ read replica. Và **71 USD** nếu chỉ chạy trong giờ làm việc.

Nếu bị cắt tiếp 20% (208 → 166), thứ tự đòn bẩy:

| Cắt tiếp | Tiết kiệm | Ảnh hưởng cam kết kỹ thuật |
|---|---|---|
| Chạy 8 giờ/ngày thay vì 24/7 | ~137 | **Không ảnh hưởng gì.** Đòn bẩy đầu tiên và mạnh nhất |
| Bỏ **RDS Proxy** | 26 | `test-b4` cho thấy ràng buộc #5 vẫn đạt mà không có Proxy — hồi phục 22 giây, không restart. Mất lớp giữ kết nối phía máy chủ |
| Bỏ **read replica** | 21 | Job báo cáo chạy trên primary. Hiện SCP đang chặn nên coi như đã mất sẵn |
| Tắt EC2 detailed monitoring | 4 | Mất metric 1 phút, còn metric 5 phút. Ảnh hưởng độ nhạy của alarm ràng buộc #4 |
| RDS Multi-AZ → Single-AZ | 19 | **Không khuyến nghị.** RTO tăng từ ~2 phút lên ~30 phút, vi phạm ràng buộc #5 |

Đòn bẩy đầu tiên đủ mạnh để không phải chạm tới bốn cái sau.
