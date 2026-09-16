# Tài liệu kỹ thuật — Hệ thống bán hàng ABC Manufacturing trên AWS

**Vai trò:** Cloud Engineer · **Người thực hiện:** khaipd18

Tài liệu này dành cho người đọc **không cần biết AWS**. Mục tiêu là trả lời bốn câu:
hệ thống làm gì, được dựng bằng gì, có chạy đúng không, và hỏng thì làm sao.

Tài liệu sâu hơn liệt kê ở [mục 9](#9-đi-sâu-hơn-ở-đâu).

---

## 1. Hệ thống này làm gì

ABC Manufacturing bán hàng B2B. Nhân viên kinh doanh nhập đơn thay cho khách,
kế toán duyệt, kho xuất hàng, cuối ngày chạy báo cáo doanh thu. Các phòng ban
dùng chung một file server để trao đổi tài liệu.

Hệ thống cũ chạy trên ba máy chủ vật lý đặt tại công ty: một máy web, một máy
ứng dụng, một máy database. Ba vấn đề:

| Vấn đề cũ | Hệ quả |
|---|---|
| Mỗi tầng chỉ có **một máy** | Máy chết là mất dịch vụ. Cao điểm traffic gấp 4–5 lần thì chậm hoặc sập |
| Database **không có bản dự phòng** | Máy hỏng là mất dữ liệu. Backup làm thủ công |
| Release ứng dụng làm tay | Chậm và dễ sai |

Công việc là chuyển toàn bộ lên AWS sao cho ba vấn đề trên biến mất, **và
không được mất một đơn hàng nào trong lúc chuyển**.

---

## 2. Hệ thống mới nhìn như thế nào

```
                        Người dùng (trình duyệt)
                                 │  HTTPS
                                 ▼
                          ┌─────────────┐
                          │ CloudFront  │  ← cửa vào duy nhất
                          └──────┬──────┘
                    trang        │        gọi API
              ┌──────────────────┴──────────────────┐
              ▼                                     ▼
      ┌───────────────┐                     ┌──────────────┐
      │  S3 (giao diện)│                     │ Cân bằng tải │
      └───────────────┘                     └──────┬───────┘
                                                   ▼
                                        ┌──────────────────────┐
                                        │  2–6 máy ứng dụng    │
                                        │  tự tăng giảm số máy │
                                        └───┬──────┬───────┬───┘
                                            ▼      ▼       ▼
                                    ┌────────┐ ┌──────┐ ┌────────┐
                                    │Database│ │Hàng  │ │File    │
                                    │2 bản   │ │đợi   │ │server  │
                                    │song song│ │đơn  │ │chung   │
                                    └────────┘ └──────┘ └────────┘
```

Ba điều đáng chú ý trong hình:

**Không còn máy nào là điểm chết duy nhất.** Máy ứng dụng có ít nhất 2 cái,
đặt ở hai khu vực vật lý khác nhau. Database có một bản sao chạy song song ở
khu vực còn lại, tự động thế chỗ nếu bản chính hỏng.

**Có một "hàng đợi đơn" nằm giữa.** Khi nhân viên bấm gửi đơn, hệ thống không
ghi thẳng vào database. Nó bỏ đơn vào hàng đợi và trả lời *"đã nhận, đang xử
lý"*. Một tiến trình riêng lấy đơn từ hàng đợi ra ghi vào database. Nghe có vẻ
vòng vo, nhưng đây chính là thứ giữ cho hệ thống không mất đơn khi database
gặp sự cố — xem mục 4.

**Giao diện không chạy trên máy chủ nào.** Trang web là file tĩnh nằm trên kho
lưu trữ, phát qua mạng phân phối của AWS. Không có máy chủ web để hỏng, và
rẻ hơn khoảng 47 USD/tháng so với phương án chạy máy chủ riêng.

---

## 3. Từng thành phần làm gì

| Thành phần | Nói cho dễ hiểu | Vì sao chọn cái này |
|---|---|---|
| **CloudFront** | Cửa vào duy nhất, có ổ khoá HTTPS | Tài khoản không được cấp quyền mua chứng chỉ bảo mật. CloudFront có sẵn chứng chỉ miễn phí — đây là đường duy nhất để trang chạy HTTPS |
| **S3** | Kho chứa file giao diện | Không có máy chủ nào để hỏng, trả tiền theo dung lượng thật |
| **Cân bằng tải (ALB)** | Người gác cổng, chia request cho các máy | Máy nào chết thì ngừng gửi việc vào máy đó trong ~20 giây |
| **Máy ứng dụng (EC2 + Auto Scaling)** | 2 máy thường trực, tự tăng lên 6 khi đông | Có sẵn 2 máy "ngủ đông" để bật lên trong 30–40 giây thay vì 2–3 phút |
| **Hàng đợi (SQS)** | Chỗ xếp hàng cho đơn chờ ghi | Database chết thì đơn nằm chờ ở đây, không mất |
| **Sổ ghi nhận (DynamoDB)** | Sổ "đã nhận đơn này lúc mấy giờ" | Nằm **ngoài** database, nên khi database chết vẫn tra được đơn của mình đang ở đâu |
| **Database (RDS PostgreSQL)** | Nơi dữ liệu thật nằm, có 2 bản song song | Bản chính hỏng thì bản dự phòng thế chỗ trong 1–2 phút, không mất dữ liệu |
| **RDS Proxy** | Người môi giới kết nối | Lúc database đổi bản, ứng dụng không thấy đứt kết nối nên không cần khởi động lại |
| **File server (EFS)** | Ổ đĩa chung cho các phòng ban | Giữ nguyên cấu trúc thư mục và quyền theo phòng ban như hệ thống cũ |
| **Giám sát (CloudWatch)** | Chuông báo động | 8 chuông, mỗi cái gắn với một ngưỡng trong yêu cầu của khách hàng |

---

## 4. Mười yêu cầu của khách hàng và cách đáp ứng

Yêu cầu đưa ra 10 ràng buộc. Bảng dưới nói **ngắn gọn** cách từng cái được giải
quyết; bản đầy đủ ở [`anh-xa-rang-buoc.md`](anh-xa-rang-buoc.md).

| # | Khách hàng yêu cầu | Cách làm |
|---|---|---|
| 1 | Chạy hoàn toàn trên AWS, cắt hẳn hệ thống cũ | Không có thành phần nào còn phụ thuộc máy chủ tại công ty |
| 2 | Chuyển đổi ≤ 15 phút, không mất/trùng đơn | Chép dữ liệu trước nhiều giờ, chỉ khoá ghi ở phút cuối. **Đo được: 1,1 giây** |
| 3 | Không tạo đơn trùng, không âm thầm ghi đè | Mỗi đơn mang một mã duy nhất; gửi lại 5 lần vẫn ra đúng 1 đơn. Hai người cùng sửa thì người sau nhận thông báo "đơn đã thay đổi", không đè lên |
| 4 | Chịu tải gấp 5, hỏng 1 máy gián đoạn ≤ 2 phút | Tự tăng số máy theo lượng request; máy dự phòng "ngủ đông" bật trong 30–40 giây |
| 5 | Database chết 3 phút không được báo thành công giả | Hệ thống trả *"đã nhận, chưa xác nhận"* chứ không nói "thành công". Đơn nằm chờ trong hàng đợi. **Đo được: tự hồi phục 13 giây, không phải khởi động lại gì** |
| 6 | Mất dữ liệu ≤ 5 phút, khôi phục ≤ 30 phút | Hai bản database chạy song song (mất 0 phút dữ liệu) + sao lưu 7 ngày, khôi phục về đúng từng phút |
| 7 | Phân quyền file theo phòng ban, thu hồi ≤ 5 phút | Mỗi phòng có một "cửa vào" riêng do AWS kiểm soát, không phải do máy con tự khai. Xoá cửa vào là mất quyền ngay |
| 8 | Truy vết được một giao dịch, dựng lại được hệ thống | Mỗi request mang một mã theo suốt hành trình. Toàn bộ hạ tầng viết bằng Terraform, dựng lại bằng một lệnh |
| 9 | Kiểm soát chi phí, cắt 20% thì đề xuất được | 208 USD/tháng nếu chạy liên tục, 71 USD nếu chỉ chạy giờ làm việc |
| 10 | Báo cáo chạy song song không làm chậm việc nhập đơn | Báo cáo chốt tại một mốc thời gian rõ ràng, đọc trong một "ảnh chụp" dữ liệu. **Đo được: nhập đơn vẫn 61 ms trong lúc báo cáo chạy** |

---

## 5. Kết quả kiểm thử thực tế

Sáu kịch bản đã chạy thật, không phải lý thuyết. Script nằm ở `scripts/test-*.sh`,
log lưu ở `evidence/`.

Lần chạy local gần nhất: **58/58 phép kiểm chứng đạt, 0 không đạt**. Ngoài ra bảy bài đã chạy trên AWS thật ngày 12/09/2026 (`evidence/aws-*.log`)
(`evidence/test-report-20260910T173621Z.txt`).

| Mã | Kịch bản | Kết quả đo được | |
|---|---|---|---|
| **A1** | Chuyển đổi trong lúc vẫn có đơn phát sinh | Ngừng dịch vụ **1,1 giây** (cho phép 15 phút). 3.587 đơn ở nguồn = 3.587 đơn ở đích, tổng tiền khớp tuyệt đối, **0 mã đơn trùng** | 7/7 |
| **A2** | Bấm gửi lại 5 lần cùng một đơn | Đúng **1 đơn** được tạo | 3/3 |
| **A3** | 10 người cùng sửa một đơn | **1 người** ghi thành công, **9 người** nhận báo "đơn đã thay đổi", số phiên bản chỉ tăng đúng 1 lần | 7/7 |
| **A5** | Phân quyền file server theo phòng ban | Không phòng nào đọc được thư mục phòng khác | 30/30 |
| **B4** | Cắt kết nối database 60 giây | **0 đơn** bị báo thành công sai; tự hồi phục sau **13 giây**; ứng dụng và tiến trình xử lý đơn **không hề khởi động lại** | 5/5 |
| **B8** | Chạy báo cáo song song với nhập đơn | Nhập đơn **p95 = 61 ms** (ngưỡng cho phép 2.000 ms); 5 lần chạy báo cáo ra cùng một con số; đơn tạo sau mốc chốt không lọt vào | 6/6 |

Vài kịch bản còn lại phải chạy trên AWS thật vì phụ thuộc tính năng chỉ có ở
đó (khôi phục theo thời điểm, đổi bản database, tải 5 lần cần máy phát tải riêng).

---

## 6. Vận hành hằng ngày

### Kiểm tra hệ thống có khoẻ không

```bash
SITE=https://<địa-chỉ-trang>

curl -s $SITE/api/ready      # tiến trình còn sống?
curl -s $SITE/api/health     # có tới được database?
curl -s $SITE/api/ops/queue  # còn bao nhiêu đơn đang chờ?
```

Bình thường: `ready` và `health` trả `ok`, số đơn chờ về 0 trong vài giây.

### Cập nhật phiên bản ứng dụng

1. Đóng gói mã nguồn, đẩy lên kho artifact
2. Sửa con trỏ `current.txt` sang phiên bản mới
3. Gọi lệnh thay máy — hệ thống thay **từng nửa** số máy một, chờ máy mới
   chạy tốt 2 phút rồi mới thay tiếp
4. Máy mới không chạy được → quá trình dừng lại, giữ nguyên bản cũ

Quay lại bản cũ = sửa `current.txt` về mã cũ rồi làm lại bước 3. Chi tiết:
[`quy-trinh-release.md`](quy-trinh-release.md).

### Tắt bớt cho đỡ tốn tiền

Môi trường thực hành không cần chạy 24/7.

```bash
./scripts/aws-env.sh down     # còn ~13 USD/tháng tiền lưu trữ
./scripts/aws-env.sh up       # bật lại, mất ~5 phút
./scripts/aws-env.sh status   # xem đang chạy gì
```

> **Không dùng `terraform destroy` để tắt tạm** — lệnh đó xoá cả database và
> mất hết dữ liệu.

---

## 7. Khi có sự cố

Bảng "thấy gì → làm gì". Chi tiết từng bước ở [`runbook.md`](runbook.md).

| Chuông báo | Nghĩa là | Việc phải làm ngay |
|---|---|---|
| `UnHealthyHostCount > 0` | Một máy ứng dụng chết | **Không làm gì trong 5 phút đầu** — hệ thống tự thay máy. Sau 5 phút chưa khỏi thì xem log khởi động |
| `TargetResponseTime` p95 > 2s | Hệ thống chậm | Xem số máy có tăng chưa; nếu chưa thì kiểm tra chính sách tự tăng |
| `DatabaseConnections` > 68 | Sắp hết chỗ kết nối database | Kiểm tra có tiến trình nào giữ kết nối không nhả |
| `ApproximateAgeOfOldestMessage` > 300s | Đơn nằm chờ quá lâu | Tiến trình xử lý đơn có chết không? Database có truy cập được không? |
| **DLQ có message** | **Có đơn không ghi được vào database** | Ưu tiên cao nhất. Xem nội dung đơn hỏng, sửa nguyên nhân, đẩy lại |
| `FreeStorageSpace` < 2 GB | Database sắp đầy | Kiểm tra dung lượng tự mở rộng có bật không |

### Ba điều đừng làm

1. **Đừng khởi động lại ứng dụng khi database chết.** Hệ thống được thiết kế
   để sống qua sự cố đó và tự nối lại. Khởi động lại làm mất đơn đang xử lý dở.
2. **Đừng khôi phục database đè lên bản đang chạy.** Sẽ mất các giao dịch hợp
   lệ phát sinh sau thời điểm sự cố. Khôi phục ra một bản riêng rồi lấy đúng
   phần cần.
3. **Đừng đổi cấu hình bằng tay trên Console.** Lần `terraform apply` sau sẽ
   đưa về như cũ, và không ai biết vì sao. Sửa trong mã nguồn rồi apply.

---

## 8. Chi phí

| Phương án | USD/tháng |
|---|---|
| Quy mô production (thiết kế của SA) | **1.100,51** |
| Quy mô thực hành, chạy liên tục | **207,82** |
| Quy mô thực hành, chỉ chạy giờ làm việc | **~72** |

Tài khoản thực hành có trần **350 USD/tháng cho toàn bộ resource**, dùng chung
với người khác — nên bản production gấp 3,1 lần trần, không dựng nguyên trạng
được.

Bản 208 USD **giữ nguyên mọi cam kết kỹ thuật**: vẫn hai bản database song
song, vẫn RDS Proxy, vẫn máy dự phòng ngủ đông. Chỉ thu nhỏ dung lượng dữ liệu
thực hành, đúng như yêu cầu cho phép.

**Nếu bị cắt 20%** (208 → 166): đòn bẩy đầu tiên là **lịch chạy, không phải cấu
hình**. Hạ xuống 8 giờ mỗi ngày làm việc đã vượt xa mức cắt 20% mà không đụng
tới bất kỳ ràng buộc nào. Tuyệt đối không đề xuất bỏ chế độ hai bản database
song song — nó phá trực tiếp yêu cầu số 5.

Chi tiết: [`chi-phi.md`](chi-phi.md) · [`chi-phi-ngay-tuan.md`](chi-phi-ngay-tuan.md)

---

## 9. Đi sâu hơn ở đâu

| Cần biết | Đọc file |
|---|---|
| Những giả định đã đặt ra | [`gia-dinh.md`](gia-dinh.md) |
| Từng ràng buộc ánh xạ sang dịch vụ nào | [`anh-xa-rang-buoc.md`](anh-xa-rang-buoc.md) |
| Vì sao chọn dịch vụ này không chọn dịch vụ kia | [`lua-chon-thiet-ke.md`](lua-chon-thiet-ke.md) |
| Xử lý sự cố từng bước | [`runbook.md`](runbook.md) |
| Bảng chi phí đầy đủ | [`chi-phi.md`](chi-phi.md) |
| Quy trình release và rollback | [`quy-trinh-release.md`](quy-trinh-release.md) |
| Kiến trúc từng module hạ tầng | [`../../deploy/terraform/README.md`](../../deploy/terraform/README.md) |
| Thông số kỹ thuật đầy đủ | [`thong-so-ky-thuat.md`](thong-so-ky-thuat.md) |
| Các bước bấm trên AWS Console | [`huong-dan-console.md`](huong-dan-console.md) |

---

## 10. Những gì chưa làm, và vì sao

Yêu cầu yêu cầu chủ động thu hẹp phạm vi và giải thích lý do. Danh sách đã bỏ:

| Bỏ gì | Lý do |
|---|---|
| **Read replica** cho báo cáo | Bị chặn ở cấp tổ chức (SCP), IT tài khoản không cấp được. Báo cáo chạy trên bản chính với mốc chốt rõ ràng, vẫn đạt yêu cầu #10 |
| **Cognito** (đăng nhập) | Yêu cầu không nhắc tới đăng nhập. Người nhập đơn là nhân viên nội bộ, không có khách hàng tự đăng nhập |
| **WAF, GuardDuty** | Ngoài phạm vi 2 tuần, và tốn thêm ~30 USD/tháng. Khuyến nghị cho giai đoạn sau |
| **CI/CD đầy đủ** | Yêu cầu chỉ yêu cầu mức ý tưởng. Đã hiện thực phần cốt lõi: đóng gói có phiên bản, thay máy từng nửa, có cổng kiểm tra sức khoẻ |
| **X-Ray** (truy vết phân tán) | Mã theo suốt request trong log đã đủ để truy vết một giao dịch |
| **Chứng chỉ HTTPS riêng (ACM)** | Không có quyền. Dùng chứng chỉ mặc định của CloudFront, vẫn được trình duyệt tin cậy |

---

*Yêu cầu dự án*
