# Phương án thực thi và kế hoạch triển khai

Chia giai đoạn, mốc quyết định, và timeline thực tế.

---

## 1. Cách tiếp cận: chuyển từng phần, không chuyển một lượt

Ba cách chuyển một hệ thống lên cloud:

| | Big-bang | **Từng phần** | Song song lâu dài |
|---|---|---|---|
| Cách làm | Dựng hết, đổi một lần | Dựng nền trước, chuyển dần từng workload | Chạy hai nơi nhiều tháng |
| Rủi ro | Cao, hỏng là hỏng tất cả | Thấp, hỏng phần nào lùi phần đó | Thấp nhưng tốn gấp đôi |
| Thời gian | Ngắn | Trung bình | Dài |

**Chọn chuyển từng phần.** Dựng hạ tầng nền trước, chuyển file server trước
(rủi ro thấp), database sau cùng (rủi ro cao nhất).

Lý do: file server rollback chỉ là đổi điểm mount về chỗ cũ. Database thì sau khi
đổi connection string, đơn mới đã ghi vào RDS, quay lại phải trích ngược.

Làm phần dễ trước để cả nhóm quen nhịp cutover.

---

## 2. Bốn giai đoạn

### Giai đoạn 1 — Nền tảng

**Mục tiêu:** có hạ tầng trống nhưng đúng hình dạng.

```
VPC, subnet 3 tầng, NAT, S3 endpoint
6 security group
IAM role
RDS Multi-AZ (chưa có dữ liệu)
SQS, DynamoDB
```

**Xong khi:** `terraform apply` sạch, RDS ở trạng thái `available`.

**Rủi ro:** thiếu quyền AWS. Đã xảy ra thật — mất 5 lượt xin IT.

---

### Giai đoạn 2 — Ứng dụng

**Mục tiêu:** ứng dụng chạy trên AWS, chưa có dữ liệu thật.

```
Đóng gói artifact lên S3
Launch template + ASG + warm pool
ALB + target group, health check /ready
S3 + CloudFront cho SPA
CloudWatch: alarm, metric filter, dashboard
```

**Xong khi:** mở trang web thấy giao diện, tạo được đơn thử, đơn vào database.

**Rủi ro:** instance không qua health check. Thường do user-data lỗi hoặc không
đọc được SSM.

---

### Giai đoạn 3 — Chuyển dữ liệu

**Mục tiêu:** dữ liệu thật nằm trên AWS.

```
3a. File server    chép lên S3 → DataSync → EFS → phục hồi quyền → đối chiếu
3b. Database       full load → CDC bám thay đổi → chờ latency về 0
```

Hai phần **làm song song được**, nhưng cutover thì tách ra.

**Xong khi:** đối chiếu hai đầu khớp, `diff` manifest rỗng.

**Rủi ro:** quên đặt lại sequence (database), mất quyền POSIX (file server). Chi
tiết ở [`migration/`](migration/).

---

### Giai đoạn 4 — Cutover và ổn định

```
4a. Cutover file server    rủi ro thấp, làm trước
4b. Cutover database       trong cửa sổ bảo trì
4c. Theo dõi 1 tuần        giữ nguồn cũ ở chế độ chỉ đọc
4d. Dọn dẹp                xoá DMS, xoá bucket trung gian
```

**Xong khi:** hệ thống cũ tắt hẳn mà mọi chức năng vẫn chạy — đây là ràng buộc #1.

---

## 3. Mốc quyết định go/no-go

Trước mỗi cutover, phải **đủ hết** mới được bấm. Thiếu một là hoãn.

### Trước cutover file server

- [ ] DataSync chạy xong, `FilesTransferred` khớp số file nguồn
- [ ] `diff manifest-nguon.txt manifest-dich.txt` rỗng
- [ ] `diff checksum-nguon.txt checksum-dich.txt` rỗng
- [ ] Thử quyền: phòng A không đọc được thư mục phòng B
- [ ] Đã thử rollback ít nhất một lần

### Trước cutover database

- [ ] Full load xong, mọi bảng "Table completed"
- [ ] `CDCLatencySource` và `CDCLatencyTarget` đều **< 5 giây**
- [ ] Validation không có dòng lệch
- [ ] Đã chuẩn bị sẵn SQL đặt lại sequence
- [ ] Đã thử rollback ở môi trường test
- [ ] Có người trực cả hai phía
- [ ] Đã thông báo người dùng về cửa sổ bảo trì

**Ai quyết định:** SA và CE cùng ký. Một người phản đối là hoãn.

---

## 4. Timeline 10 ngày

Yêu cầu cho 2 tuần. Dưới đây là kế hoạch, cột cuối là **thực tế đã diễn ra**.

| Ngày | SA | CE | Thực tế |
|---|---|---|---|
| 1–2 | Khảo sát, kiến trúc sơ bộ | Góp ý khả thi, dựng môi trường on-premise giả lập | Dựng docker compose mô phỏng 3 server vật lý |
| 3–4 | Hoàn thiện kiến trúc, báo giá | **Giai đoạn 1** — mạng, security, IAM, RDS | Terraform 11 module, plan sạch |
| **5** | **Chốt phạm vi — go/no-go chung** | | Đổi Web tier sang SPA, bớt 2 EC2 và 1 ALB |
| 6–7 | Hỗ trợ giải thích ràng buộc | **Giai đoạn 2** — ứng dụng, CloudWatch. Viết bộ test | Apply thật 165 tài nguyên, destroy sạch |
| 8 | Review kết quả so thiết kế | Chạy toàn bộ test, thu bằng chứng | 58/58 ở local + 7 bài trên AWS thật, log trong `evidence/` |
| 9 | Hoàn thiện báo cáo, slide | Hoàn thiện tài liệu bàn giao | 17 file tài liệu |
| 10 | Trình bày và demo | | |

### Mốc ngày 5 — điểm quyết định

Yêu cầu ghi rõ *"chốt phạm vi và giai đoạn triển khai, mốc quyết định chung"*.

Quyết định thật đã ra ở mốc này: **bỏ tầng Web EC2, chuyển giao diện thành SPA
tĩnh**. Lý do là ALB cần chứng chỉ TLS mà tài khoản không có quyền ACM.

Kết quả: bớt 2 EC2 và 1 ALB, chi phí từ 256,19 xuống **207,82 USD/tháng**, và
giải quyết luôn bài toán HTTPS.

---

## 5. Rủi ro và cách xử lý

| Rủi ro | Khả năng | Ảnh hưởng | Cách xử lý | Đã xảy ra? |
|---|---|---|---|---|
| Thiếu quyền AWS | Cao | Không apply được | Dò quyền bằng script trước khi viết module, xin theo lô | **Có**, 5 lượt xin |
| Vượt trần ngân sách | Trung bình | Bị nhắc nhở | Thu nhỏ cấu hình, tắt khi không dùng | **Có**, 1.100 → 208 USD |
| SCP chặn dịch vụ | Trung bình | Mất một ràng buộc | Tìm đường vòng, ghi rõ vào báo cáo | **Có**, read replica |
| Cutover mất đơn | Thấp | Nghiêm trọng | Full load + CDC, đối chiếu bốn chỉ số, có rollback | Không |
| Quên đặt lại sequence | Cao | Hệ thống chết sau cutover | SQL quét toàn bộ sequence, không liệt kê tay | **Có**, ở môi trường test |
| Mất quyền POSIX khi chép file | Cao | Mất ràng buộc #7 | DataSync `PRESERVE`, đối chiếu manifest | Không |
| Instance không qua health check | Trung bình | ASG giết máy liên tục | Health check `/ready` không chạm database | Không |

Bốn rủi ro đã xảy ra thật đều xử lý được, và đã ghi vào tài liệu để lần sau
tránh.

---

## 6. Phân công

| Việc | SA | CE |
|---|---|---|
| Kiến trúc tổng thể, chọn dịch vụ | **chủ trì** | phản hồi khả thi |
| Báo giá cho khách | **chủ trì** | cấp số liệu sizing |
| Dựng hạ tầng bằng Terraform | | **chủ trì** |
| Thiết kế và chạy test | góp ý kịch bản ưu tiên | **chủ trì** |
| Kế hoạch migration | duyệt | **chủ trì** |
| Quyết định go/no-go | **cùng ký** | **cùng ký** |
| Tài liệu bàn giao | phần thiết kế | phần triển khai và vận hành |
