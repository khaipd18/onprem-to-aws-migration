# Chi phí theo ngày và theo tuần — môi trường thực hành

| | |
|---|---|
| **Tài khoản** | `123456789012` · `ap-southeast-1` |
| **Trần tài khoản** | 350 USD/tháng, dùng chung với người khác |
| **Ngày** | 2026-09-10 |

Giá lấy từ trang giá công khai của AWS cho `ap-southeast-1` và AWS Pricing Calculator.

---

## 1. Con số ngắn gọn

| Cách chạy | USD/ngày | USD/tuần | USD/tháng | % trần 350 |
|---|---|---|---|---|
| Chạy liên tục 24/7 | 6,83 | 47,84 | 207,82 | 59% |
| **8 giờ/ngày × 5 ngày làm việc** | **2,91** | **16,41** | **71,05** | **20%** ← đề nghị |
| 10 giờ/ngày × 5 ngày | 3,40 | 18,86 | 81,66 | 23% |
| Chỉ bật khi test và demo | — | 9,04 | 39,14 | 11% |
| Tắt hoàn toàn | 0,94 | 6,58 | 28,50 | 8% |

**Cách đọc bảng:**
- Cột **USD/ngày** là chi phí của một ngày **có chạy**. Ngày nghỉ chỉ mất 0,94 USD.
- Cột **USD/tuần** đã tính cả hai ngày nghỉ cuối tuần, không phải nhân trực tiếp cột ngày.

---

## 2. Công thức

```
chi phí = 0,2456 USD × số giờ chạy  +  28,50 USD/tháng
```

| | USD | Tắt máy có hết không |
|---|---|---|
| Phần tính theo giờ | 0,2456/giờ | **Có** |
| Phần cố định | 28,50/tháng · 0,94/ngày · 6,58/tuần | Không — là tiền lưu trữ |

Phần lớn chi phí nằm ở nhóm thứ nhất, nên **tắt ngoài giờ là đòn bẩy mạnh nhất**.

---

## 3. Theo ngày — từng dịch vụ

Khi máy chạy đủ 24 giờ:

| Dịch vụ | USD/ngày | Tắt là hết |
|---|---|---|
| NAT Gateway | 1,416 | ✓ |
| RDS primary `db.t4g.micro` Multi-AZ | 1,224 | ✓ |
| EC2 2 × `t4g.small` | 1,018 | ✓ |
| RDS Proxy | 0,864 | ✓ |
| RDS read replica | 0,612 | ✓ |
| ALB public | 0,605 | ✓ |
| EBS 80 GB | 0,253 | |
| RDS storage primary 20 GB | 0,182 | |
| CloudFront | 0,158 | |
| EC2 detailed monitoring | 0,139 | ✓ |
| NAT xử lý dữ liệu | 0,097 | |
| RDS storage replica 20 GB | 0,091 | |
| CloudWatch | 0,071 | |
| EFS | 0,023 | |
| Secrets Manager | 0,021 | |
| ALB LCU | 0,019 | ✓ |
| SQS | 0,016 | |
| DynamoDB | 0,016 | |
| S3 | 0,009 | |
| **Tổng** | **6,83** | |

**Sáu hạng mục đầu chiếm 83% chi phí mỗi ngày**, và cả sáu đều tính theo giờ.

## 4. Theo ngày — theo số giờ chạy

| Số giờ chạy trong ngày | USD/ngày |
|---|---|
| 24 giờ | 6,83 |
| 12 giờ | 3,89 |
| **8 giờ** | **2,91** |
| 4 giờ | 1,92 |
| 0 giờ — tắt cả ngày | 0,94 |

---

## 5. Theo tuần

| Cách chạy | Số giờ/tuần | USD/tuần |
|---|---|---|
| Liên tục 24/7 | 168 | 47,84 |
| 10 giờ/ngày × 5 ngày | 50 | 18,86 |
| **8 giờ/ngày × 5 ngày làm việc** | **40** | **16,41** ← đề nghị |
| Chỉ bật khi test và demo | 10 | 9,04 |
| Tắt cả tuần | 0 | 6,58 |

### Một tuần làm việc điển hình

```
Thứ 2 → Thứ 6   bật 8 giờ mỗi ngày   5 × 1,965 =  9,83
Thứ 7, Chủ nhật tắt                              0,00
Phần cố định    ổ đĩa, snapshot, log             6,58
──────────────────────────────────────────────────────
                                                16,41 USD
```

### Tuần chuyển đổi

Dữ liệu thực hành rất nhỏ nên hai công cụ chuyển đổi gần như không tốn gì:

| Nguồn | Khối lượng thật |
|---|---|
| File share | 7,7 MB — 41 file |
| PostgreSQL | 11 MB — 2.844 đơn |

Việc truyền mất vài giây; cái tốn là thời gian instance tồn tại (dựng DMS mất 10-15 phút).

```
Vận hành thường (40 giờ)                        16,41
DMS dms.t3.micro Single-AZ, 6 giờ                0,22
DataSync S3 → EFS, không cần agent               0,00
──────────────────────────────────────────────────────
                                                16,63 USD
```

**DataSync tính thuần theo gigabyte**, không chọn loại máy — trên Pricing Calculator chỉ có một ô "Total data copied per month". Máy agent nếu cần thì tính riêng dưới mục EC2.

Và ở đây không cần agent: agent chỉ bắt buộc khi nguồn là NFS/SMB tự quản. Đưa file lên S3 trước rồi DataSync S3 → EFS thì chạy agentless, bỏ được EC2 `m5.2xlarge` (0,512 USD/giờ).

Xoá DMS ngay sau khi cutover xong.

---

## 6. Bốn tuần đầu — dự kiến thực tế

| Tuần | Nội dung | USD |
|---|---|---|
| 1 | Dựng hạ tầng, chạy test cơ bản | 16,41 |
| 2 | Chuyển đổi dữ liệu và file | 16,63 |
| 3 | Chạy đủ bộ test, đo tải, thu bằng chứng | 18,86 |
| 4 | Chuẩn bị demo, chạy lại test | 16,41 |
| | **Tổng bốn tuần** | **69,23** |

Tương đương **20% trần một tháng**, đã bao gồm cả tuần chuyển đổi.

---

## 7. Chỗ dễ vỡ ngân sách

Rủi ro nằm ở chỗ **quên xoá**, không phải ở khối lượng dữ liệu.

| Công cụ | Kế hoạch | Nếu quên một tháng |
|---|---|---|
| DMS `dms.t3.micro` Single-AZ | 6 giờ = 0,22 | 20 |
| ~~DataSync agent `m5.2xlarge`~~ | **không dùng** | ~~374~~ |

Bỏ agent đi thì bỏ luôn được rủi ro lớn nhất. Chỉ còn DMS phải nhớ xoá.

---

## 8. Cách kiểm soát

```bash
./scripts/aws-env.sh status    # đang chạy gì, tốn bao nhiêu mỗi giờ
./scripts/aws-env.sh down      # tắt  → còn 0,94 USD/ngày
./scripts/aws-env.sh up        # bật lại, khoảng 5 phút
```

Script lọc theo tag `owner=khaipd18` nên không đụng và không đếm nhầm resource của người khác trong cùng tài khoản.

Mọi tài nguyên đều mang tag `owner=khaipd18` — đã kiểm chứng trên `terraform plan`: **119/119 resource hỗ trợ tag đều có**. Số còn lại là loại AWS không cho gắn tag.

Rà soát bất cứ lúc nào:

```bash
aws --profile abc-migration resourcegroupstaggingapi get-resources --region ap-southeast-1 \
  --query "ResourceTagMappingList[?!not_null(Tags[?Key=='owner'])].ResourceARN" --output table
```

---

## 9. Cam kết

1. Tắt môi trường ngoài giờ làm việc
2. Mọi resource mang tag `owner=khaipd18` để bóc tách được chi phí
3. Xoá DMS và DataSync agent ngay sau khi chuyển đổi xong
4. Báo cáo lại nếu chi phí thực tế vượt đề nghị

---

Bảng chi tiết đầy đủ, gồm cả bản dự toán production của SA và phần đối chiếu: `chi-phi.md`.
Đề nghị ngân sách đầy đủ: `../noi-bo/de-nghi-ngan-sach.md`.
