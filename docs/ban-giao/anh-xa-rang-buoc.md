# Ánh xạ 10 ràng buộc → cơ chế → cách chứng minh

Đây là tài liệu để trả lời phản biện. Với mỗi ràng buộc ở Mục 3.1 của yêu cầu:
làm bằng cách nào, code nằm ở đâu, và chứng minh bằng gì.

Nguyên tắc chung: **không viết "đạt" khi chưa đo.** Mọi con số dưới đây đều
lấy từ một lần chạy thật, ghi trong `evidence/`.

---

## #1 — Vận hành hoàn toàn trên AWS

**Yêu cầu:** Web, Application, PostgreSQL, File Server phải hoạt động độc lập
sau khi ngắt môi trường nguồn. Không hybrid.

**Cơ chế:** Môi trường đích không có tham chiếu nào ngược về nguồn — không
VPN, không DNS trỏ về on-prem, không job đồng bộ hai chiều. Sau cutover,
connection string đổi sang RDS Proxy và hệ thống nguồn chỉ còn để đối chiếu.

**Chứng minh:** Test A7 — dừng toàn bộ profile `onprem`, hệ thống đích vẫn
phục vụ đủ chức năng.

```bash
docker compose -f deploy/local/docker-compose.yml --profile onprem down
bash scripts/test-all.sh      # vẫn phải PASS toàn bộ
```

---

## #2 — Migration khi vẫn phát sinh giao dịch

**Yêu cầu:** Downtime ≤ 15 phút, không mất hoặc trùng giao dịch đã xác nhận.

**Cơ chế:** DMS Full load + CDC. Full load chạy trước nhiều giờ, CDC bám
realtime. Cửa sổ downtime chỉ dùng để chờ CDC latency về 0 và đổi endpoint.

Điều kiện phía nguồn (đã bật sẵn trong `deploy/local/docker-compose.yml`):

```
wal_level = logical, max_replication_slots >= 5, max_wal_senders >= 5
```

**Chứng minh:** `scripts/order-generator.py` ghi **sổ cái** từng đơn đã gửi —
kèm idempotency key, thời điểm, order_id, mã HTTP. Sau cutover, chế độ
`--verify` đối chiếu từng dòng sổ cái với hệ thống đích.

Điểm này quan trọng: đối chiếu **từng đơn**, không phải so tổng số. So tổng số
sẽ không phát hiện được trường hợp mất 3 đơn và tạo trùng 3 đơn khác.

```bash
# cửa sổ 1 — bơm đơn vào nguồn suốt 15 phút
python3 scripts/order-generator.py --url http://localhost:18080 \
    --rate 2 --duration 900 --ledger evidence/cutover-ledger.jsonl

# cửa sổ 2 — chạy cutover

# sau đó — đối chiếu
python3 scripts/order-generator.py --verify evidence/cutover-ledger.jsonl \
    --url http://localhost:8080
```

---

## #3 — Đảm bảo tính đúng đắn

Ràng buộc này gồm ba mệnh đề riêng biệt, cần ba cơ chế khác nhau.

### 3a. Không tạo đơn trùng khi người dùng gửi lại

**Hai tuyến phòng thủ**, cố ý không dựa vào một tuyến duy nhất:

| Tuyến | Cơ chế | Chặn được gì |
|---|---|---|
| 1 — App tier | Accept store, `PutItem` có `ConditionExpression` (DynamoDB) hoặc `INSERT ... ON CONFLICT` (PostgreSQL) | Chặn ngay ở biên, không tạo message thừa trong hàng đợi. **Vẫn hoạt động khi RDS chết.** |
| 2 — Database | `UNIQUE (idempotency_key)` + `INSERT ... ON CONFLICT DO NOTHING` | Chặn cả trường hợp SQS giao lại message (at-least-once) |

Cần cả hai vì chúng chặn hai thứ khác nhau: tuyến 1 chặn client gửi lại, tuyến
2 chặn hạ tầng giao lại.

**Code:** `app/common/store.py`, `orders.persist_order`
**Chứng minh:** `scripts/test-a2-idempotency.sh` — gửi 5 lần, DB có đúng 1 dòng.

### 3b. Không âm thầm ghi đè khi nhiều người cùng cập nhật

**Cơ chế:** Optimistic locking. Cột `version`, mọi `UPDATE` kèm
`WHERE version = $expected`. Khớp 0 dòng → HTTP 409 kèm version hiện tại.

Chọn optimistic thay vì `SELECT FOR UPDATE` vì đây là chỉnh sửa qua giao diện
người dùng: khoá bi quan sẽ giữ khoá suốt thời gian người dùng đang gõ, và
người bỏ giữa chừng sẽ khoá luôn đơn hàng.

**Code:** `orders.update_order`
**Chứng minh:** `scripts/test-a3-concurrent-update.sh` — 10 request đồng thời
cùng version, đúng 1 thắng, 9 nhận 409, version chỉ tăng 1.

### 3c. Xác định được trạng thái khi mất kết nối

**Cơ chế:** Máy trạng thái tường minh `PENDING → CONFIRMED | FAILED` và
`GET /orders/{id}` luôn trả lời được. Khi RDS chết, endpoint này rơi xuống
accept store (nằm ngoài RDS) và trả `PENDING` kèm `persisted: false` —
không trả 404 gây hiểu nhầm là đơn không tồn tại.

---

## #4 — Chịu tải và sự cố

**Yêu cầu:** 5x tải trong 30 phút, p95 ≤ 2s, lỗi ≤ 1%. Một thành phần Web hoặc
App chết → gián đoạn ≤ 2 phút.

**Cơ chế:**
- Tách Web/App tier, mỗi tier một ASG riêng → scale độc lập theo nút thắt thật.
- Ghi đi qua hàng đợi → spike ghi được hấp thụ, không dồn hết vào DB.
- Target tracking trên `ALBRequestCountPerTarget` (không dùng CPU — phản ứng
  quá trễ cho spike), cộng step scaling để bắt kịp cú nhảy 5x.
- Health check: interval 10s × threshold 2 → phát hiện target chết trong ~20s.

**Chứng minh:** `loadtest/k6/order-load.js`. Threshold đặt đúng bằng ngưỡng
yêu cầu nên k6 tự chấm đạt/không đạt.

Lưu ý khi chạy trên AWS: đặt load generator **ngoài VPC** để không tự làm
nhiễu kết quả đo.

---

## #5 — Xử lý gián đoạn Database

**Yêu cầu (nguyên văn):** "Khi Application mất kết nối với PostgreSQL trong
3 phút, hệ thống không được thông báo thành công cho giao dịch chưa được ghi
nhận. Khi kết nối phục hồi, ứng dụng phải tự hoạt động trở lại, không cần khởi
động lại thủ công, không mất giao dịch đã xác nhận và không tạo đơn trùng."

Đây là ràng buộc khó nhất và là chỗ dễ mất điểm nhất.

**Cơ chế — tất cả bắt nguồn từ đúng một quy tắc:**

> Worker chỉ xoá message khỏi hàng đợi **sau khi** transaction đã commit.

| Mệnh đề trong yêu cầu | Suy ra từ quy tắc trên |
|---|---|
| Không báo thành công khống | API trả `202 Accepted` + `PENDING`. Chỉ worker mới đặt `CONFIRMED`, và chỉ sau khi commit. |
| Tự hoạt động trở lại | Worker bắt `DatabaseUnavailable` rồi tiếp tục vòng lặp — không thoát process. Không có process chết thì không cần ai restart. |
| Không mất giao dịch | Commit fail → không xoá message → message quay lại sau visibility timeout → xử lý lại khi DB hồi. |
| Không tạo đơn trùng | Message bị giao lại → `ON CONFLICT DO NOTHING` trên `idempotency_key`. |

Thêm một lớp nữa trên AWS: **RDS Proxy**. Proxy giữ client connection xuyên
suốt failover và tự nối lại backend, nên ứng dụng không nhìn thấy đứt kết nối.
Không có Proxy thì phải tự viết logic retry/reconnect trong app và rất khó
chứng minh khi demo.

**Code:** `app/worker/main.py`, `app/common/db.py`
**Chứng minh:** `scripts/test-b4-db-outage.sh`

Kết quả đo được (sự cố 180 giây, xem `evidence/b4-db-outage-*.log`):

| Tiêu chí | Kết quả |
|---|---|
| Đơn tiếp nhận trong lúc sự cố | 12 |
| Đơn được báo `CONFIRMED` sai trong lúc sự cố | **0** |
| Đơn được ghi đủ sau khi hồi phục | 12/12 |
| Thời gian tự drain sau khi nối lại | **8,9 giây** (đo từ `confirmed_at`) |
| Đơn trùng | **0** |
| Số lần phải restart app/worker | **0** (đối chiếu `State.StartedAt` trước/sau) |

---

## #6 — Phục hồi dữ liệu

**Yêu cầu:** RPO ≤ 5 phút, RTO ≤ 30 phút, bảo toàn giao dịch hợp lệ ngoài
phạm vi sự cố.

**Cơ chế:** RDS PITR, retention 7 ngày. Latest restorable time ≈ hiện tại − 5
phút → đáp ứng RPO.

Mấu chốt: **không restore đè lên production.** Yêu cầu yêu cầu bảo toàn giao
dịch hợp lệ phát sinh sau thời điểm sự cố; restore đè sẽ xoá mất chúng. Quy
trình đúng là restore ra instance tạm rồi chèn ngược phần bị ảnh hưởng.

**Chứng minh:** quy trình 6 bước, bấm giờ thật — xem `runbook.md`.

---

## #7 — File Server và phân quyền

**Yêu cầu:** Giữ nguyên nội dung, cấu trúc thư mục và quyền theo phòng ban.
Thu hồi quyền có hiệu lực trong ≤ 5 phút.

**Cơ chế:** nguồn là file server Linux, quyền theo phòng ban làm bằng POSIX
group + mode `2770` (bit setgid để file tạo mới thừa kế group). DataSync copy
sang EFS giữ nguyên owner, group và mode. Ở đích, mỗi phòng ban một EFS
Access Point ép sẵn UID/GID và root directory.

**Bẫy phải biết trước:** bỏ user khỏi POSIX group **không có hiệu lực ngay**
với phiên đang mở — group membership phân giải lúc thiết lập phiên, tiến
trình đang chạy vẫn giữ danh sách cũ. Muốn đạt mốc 5 phút thì gỡ
`elasticfilesystem:ClientMount`/`ClientWrite` khỏi IAM role của Access Point,
hoặc gỡ security group của client khỏi rule 2049 của mount target — cách sau
cắt ở tầng mạng nên chắc chắn có hiệu lực ngay.

**Chưa kiểm chứng:** IAM authorization của EFS xét lúc mount; client đang
mount sẵn có bị cắt ngay không thì phải đo thật. Đừng ghi "tức thì" vào báo
cáo khi chưa có số.

**Chứng minh:**
- Nội dung + cấu trúc: `scripts/make-fileshare.sh` sinh manifest checksum;
  chạy lại trên đích rồi `diff` hai file.
- Thời gian thu hồi: bấm giờ thật, quay video có đồng hồ. **Đừng ghi "đạt"
  khi chưa đo** — đây là dạng câu người review sẽ hỏi vặn.

---

## #8 — Truy vết và vận hành

**Yêu cầu:** Truy vết một giao dịch qua các thành phần. Triển khai lại môi
trường từ hồ sơ bàn giao, không phụ thuộc cấu hình lưu trên máy cá nhân.

**Cơ chế truy vết:** ALB tự sinh header `X-Amzn-Trace-Id`. Mọi tier đọc nó,
ghi vào **mọi** dòng log dưới field `correlation_id`, và truyền tiếp xuống
tier sau qua HTTP header và message attribute của SQS.

Log ra stdout dạng JSON một dòng → CloudWatch Agent gom về log group. Truy vấn:

```
fields @timestamp, tier, level, event, order_id, @message
| filter correlation_id = "Root=1-abc..."
| sort @timestamp asc
```

Thêm một đường độc lập với log: bảng `order_events` ghi hành trình nghiệp vụ
của từng đơn (`ACCEPTED → PERSISTED → UPDATED → CONFLICT → FAILED`), truy được
qua `GET /orders/{id}/trace` kể cả khi log đã hết retention.

**Cơ chế triển khai lại:** Terraform. Ràng buộc này **không thể đạt nếu không
có IaC** — chưa dựng, xem phần "Việc còn lại" trong README.

---

## #9 — Kiểm soát chi phí

CE cung cấp số liệu sizing đầu vào; báo giá là deliverable của SA.
Xem `thong-so-ky-thuat.md` §11.

Khi ngân sách bị cắt 20%, thứ tự đòn bẩy:

1. Bỏ read replica — tiết kiệm ~60 USD. Đánh đổi: job báo cáo chạy trên
   primary, rủi ro vi phạm ràng buộc #10.
3. Savings Plan 1 năm cho EC2 — tiết kiệm ~28 USD, không ảnh hưởng kỹ thuật.

**Tuyệt đối không đề xuất bỏ Multi-AZ.** Nó phá trực tiếp ràng buộc #5 mà đề
bài coi là bắt buộc.

---

## #10 — Xử lý tác vụ đồng thời

**Yêu cầu:** Job báo cáo chạy song song tải giao dịch, OLTP vẫn đạt ngưỡng
hiệu năng ở #4. Báo cáo nhất quán với dữ liệu tại thời điểm chốt, không thiếu
hoặc đếm trùng.

**Ba cơ chế, thiếu một là hỏng:**

1. **Chạy trên read replica** — tải báo cáo không đụng vào OLTP.
2. **`REPEATABLE READ`** — mọi câu query trong job nhìn cùng một snapshot.
   Không có nó thì query đếm số đơn và query tính doanh thu chạy cách nhau vài
   giây sẽ nhìn hai tập dữ liệu khác nhau → tổng không khớp chi tiết.
3. **Chờ replica replay qua mốc chốt** — điều kiện dễ bị bỏ sót nhất.

Về điểm 3: read replica là **bất đồng bộ**. Tại thời điểm chốt mốc `T` trên
primary, replica có thể còn chậm vài giây. Chạy báo cáo ngay lúc đó thì
`created_at < T` trên replica trả về ít đơn hơn thực tế — báo cáo **thiếu
đơn**, đúng thứ ràng buộc này cấm.

> Đây không phải suy đoán. Lần chạy B8 đầu tiên trong repo này ra 2788 đơn
> trong khi primary có 2846 tại cùng mốc chốt — **thiếu 18 đơn** vì replica
> đang lag. Cả 5 job đều đồng thuận với nhau, nên nếu chỉ kiểm tra "các job có
> khớp nhau không" thì lỗi này lọt lưới hoàn toàn.

Cách xử lý: trước khi mở snapshot, poll `pg_last_xact_replay_timestamp()` trên
standby cho tới khi vượt qua mốc chốt. Quá thời gian chờ thì **báo lỗi 503**
chứ không xuất báo cáo thiếu. Trên AWS đặt thêm alarm trên metric `ReplicaLag`.

**Bằng chứng nhất quán:** mỗi báo cáo trả về một `checksum` tính từ danh sách
id đã sắp xếp. Cùng `cutoff` phải ra cùng `checksum`, bất kể chạy lúc nào hay
chạy song song bao nhiêu job.

**Code:** `orders.daily_report`, `orders._wait_for_replica_catchup`
**Chứng minh:** `scripts/test-b8-report-consistency.sh`

Kết quả đo được:

| Tiêu chí | Kết quả |
|---|---|
| 5 job song song, cùng `order_count` | 2846 — khớp cả 5 |
| 5 job song song, cùng `checksum` | `b5694451...` — khớp cả 5 |
| Khớp số liệu primary tại mốc chốt | 2846 = 2846 |
| 38 đơn tạo sau mốc chốt lọt vào báo cáo | 0 |
| p95 tạo đơn khi job báo cáo đang chạy | **32 ms** (ngưỡng 2000 ms) |
