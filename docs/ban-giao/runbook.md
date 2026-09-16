# Runbook vận hành — Hệ thống bán hàng ABC Manufacturing

Tài liệu cho người trực vận hành. Viết để người **không trực tiếp dựng hệ
thống** vẫn xử lý được sự cố.

---

## 1. Bản đồ nhanh

| Thành phần | Vai trò | Chết thì sao |
|---|---|---|
| CloudFront | Điểm vào duy nhất, HTTPS, phục vụ SPA | Người dùng không mở được trang |
| S3 assets | Chứa SPA tĩnh | CloudFront trả lỗi cho trang, `/api/*` vẫn chạy |
| ALB public | Nhận `/api/*` từ CloudFront | Không gọi được API, trang vẫn mở |
| App tier (ASG) | Business logic, tầng duy nhất chạm DB | Không nhận đơn mới; đơn đang trong hàng đợi vẫn an toàn |
| Worker | Ghi đơn vào DB | Đơn dồn trong hàng đợi ở trạng thái PENDING, **không mất** |
| SQS FIFO | Đệm bền giữa App và Worker | Không nhận được đơn mới |
| RDS Proxy | Giữ connection xuyên failover | App mất kết nối DB → xem sự cố #2 |
| RDS Multi-AZ | Dữ liệu | Xem sự cố #2 |
| Read replica | Job báo cáo | Báo cáo trả 503, OLTP không ảnh hưởng |
| EFS | File server | Không truy cập được tài liệu; đơn hàng không ảnh hưởng |

**Nguyên tắc số một khi phân loại sự cố:**

> Đơn ở trạng thái `PENDING` **chưa** phải giao dịch thành công. Việc có nhiều
> đơn PENDING không phải là mất dữ liệu — đó là hệ thống đang làm đúng.
> Chỉ khi một đơn từng `CONFIRMED` mà biến mất thì mới là sự cố dữ liệu.

---

## 1b. Quy tắc chung khi động vào hệ thống

Hạ tầng do Terraform quản. Ba quy tắc, vi phạm là mất dấu vết hoặc mất luôn thay
đổi:

| Việc | Làm thế nào | Đừng làm |
|---|---|---|
| Đổi cấu hình (cỡ máy, ngưỡng alarm, số máy tối đa) | Sửa trong `deploy/terraform/`, chạy `terraform apply` | Sửa trực tiếp trên Console — lần apply sau sẽ đưa về như cũ, và không ai biết vì sao |
| Xử lý sự cố khẩn (đổi desired capacity, restart) | AWS CLI hoặc Console, **rồi ghi lại** và đưa vào Terraform sau | Để trôi, quên mất đã sửa gì |
| Dựng lại môi trường | `terraform apply` | Bấm tay từ đầu |

Runbook này cố tình **không phụ thuộc Terraform**: mọi lệnh kiểm tra và xử lý sự
cố đều dùng AWS CLI, chạy được kể cả khi người trực không biết Terraform.

Ranh giới: **chẩn đoán và cấp cứu** dùng CLI, **thay đổi lâu dài** dùng Terraform.

---

## 2. Kiểm tra sức khoẻ hệ thống

```bash
SITE=https://<cloudfront-domain>

curl -s $SITE/api/ready      | jq   # tiến trình còn sống (ALB kiểm cái này)
curl -s $SITE/api/health     | jq   # kiểm sâu: có tới được database không
curl -s $SITE/api/ops/queue  | jq   # độ sâu hàng đợi + DLQ
curl -s $SITE/api/ops/info   | jq   # cấu hình đang chạy
```

> `/ready` và `/health` khác nhau có chủ đích. Target group của ALB kiểm `/ready`
> — chỉ hỏi "tiến trình còn nhận request không". `/health` chạm tới database,
> dùng để chẩn đoán tay, **không** gắn vào target group: nếu gắn thì lúc RDS
> chết mọi instance đều rớt health check và ASG sẽ giết sạch máy.

Đọc kết quả:

| Dấu hiệu | Nghĩa là |
|---|---|
| `/health` trả 503, detail "database unavailable" | App không tới được DB → sự cố #2 |
| `ops/queue.visible` tăng đều không giảm | Worker không xử lý kịp hoặc đang chết → sự cố #3 |
| `ops/queue.dlq >= 1` | Có message hỏng vĩnh viễn → sự cố #4 |
| `ops/queue.oldest_age_seconds > 300` | Vi phạm SLA xử lý đơn → điều tra ngay |

---

## 3. Danh sách alarm và hành động

| Alarm | Ngưỡng | Việc phải làm |
|---|---|---|
| `TargetResponseTime` p95 | > 2s trong 2 chu kỳ 1 phút | Kiểm tra ASG đã scale chưa; xem Performance Insights tìm câu truy vấn chậm |
| `HTTPCode_Target_5XX_Count` | > 1% tổng request | Xem log tier nào lỗi, lọc theo `correlation_id` |
| `UnHealthyHostCount` | ≥ 1 | ASG tự thay thế. Nếu > 1 phút không tự khỏi → xem user-data / log khởi động |
| `DatabaseConnections` | > 80% max | Kiểm tra `MaxConnectionsPercent` của RDS Proxy; tìm connection leak |
| `ApproximateAgeOfOldestMessage` | > 300s | Sự cố #3 |
| DLQ `ApproximateNumberOfMessagesVisible` | ≥ 1 | Sự cố #4 |
| `ReplicaLag` | > 60s | Báo cáo sẽ trả 503. Kiểm tra tải ghi trên primary |
| `FreeStorageSpace` (RDS) | < 10 GB | Kiểm tra storage autoscaling; dọn log cũ |

Tất cả gửi về SNS → email đội trực.

---

## 4. Sự cố thường gặp

### Sự cố #1 — Một instance App tier ngừng hoạt động

**Triệu chứng:** alarm `UnHealthyHostCount > 0`.

**Đánh giá:** đây là trường hợp hệ thống được thiết kế để tự xử lý. Với health
check interval 10s và unhealthy threshold 2, ALB phát hiện trong ~20 giây và
ngừng gửi traffic; instance còn lại phục vụ tiếp.

**Việc phải làm:**
1. Xác nhận `min_size ≥ 2` và các instance trải trên 2 AZ.
2. Để ASG tự thay thế. **Không** can thiệp tay trong 5 phút đầu.
3. Nếu sau 5 phút không tự khỏi: xem log khởi động của instance mới
   (`/var/log/cloud-init-output.log`) — thường là lỗi user-data hoặc không lấy
   được secret.

**Ngưỡng cam kết:** gián đoạn ≤ 2 phút (ràng buộc #4).

---

### Sự cố #2 — Application mất kết nối PostgreSQL

**Triệu chứng:** `/health` trả 503 "database unavailable"; đơn mới vẫn nhận
được (202) nhưng đứng ở `PENDING`; `ops/queue.visible` tăng dần.

**Đánh giá:** **Đây không phải sự cố mất dữ liệu.** Hệ thống đang hoạt động
đúng thiết kế: từ chối xác nhận thứ chưa ghi được, giữ đơn trong hàng đợi.

**Việc phải làm:**
1. Xác định nguyên nhân:
   - RDS đang failover? → xem event của RDS instance. Multi-AZ mất 60–120 giây.
   - Security group bị sửa? → kiểm tra rule 5432 trên `sg-rds` từ `sg-rds-proxy`.
   - Cạn connection? → xem metric `DatabaseConnections` và `MaxConnectionsPercent`.
2. **Không restart App tier hay Worker.** Chúng được thiết kế để tự nối lại.
   Restart chỉ làm mất log điều tra và không nhanh hơn.
3. Khi kết nối hồi phục, worker tự drain hàng đợi. Theo dõi
   `ops/queue.visible` về 0.
4. Đối chiếu: mọi đơn `PENDING` phải chuyển thành `CONFIRMED`.

```sql
-- đơn còn kẹt PENDING quá 10 phút — cần điều tra
SELECT id, order_no, created_at, now() - created_at AS tuoi
  FROM orders
 WHERE status = 'PENDING' AND created_at < now() - INTERVAL '10 minutes'
 ORDER BY created_at;
```

**Thời gian hồi phục đã đo:** 8,9 giây sau khi kết nối trở lại (sự cố 180 giây,
12 đơn trong hàng đợi). Xem `evidence/b4-db-outage-*.log`.

---

### Sự cố #3 — Hàng đợi dồn ứ, đơn không chuyển sang CONFIRMED

**Triệu chứng:** `ApproximateAgeOfOldestMessage > 300s`, `visible` tăng đều.

**Chẩn đoán theo thứ tự:**

1. Worker còn sống không? → `systemctl status abc-worker` trên App tier, hoặc
   tìm log `worker.started` / `worker.idle` trong CloudWatch.
2. Worker sống nhưng không xử lý được? → tìm `worker.db_unavailable` → quay về
   sự cố #2.
3. Worker xử lý được nhưng không kịp? → so `visible` với tốc độ `worker.processed`.
   Nếu thiếu năng lực: tăng `desired_capacity` của App tier ASG, hoặc tăng
   `WORKER_BATCH`.
4. Có message độc làm worker chết lặp? → tìm `worker.permanent_failure`, xem
   `receive_count`. Message sẽ tự vào DLQ sau 5 lần.

---

### Sự cố #4 — Có message trong DLQ

**Triệu chứng:** alarm DLQ ≥ 1.

**Đánh giá:** message vào DLQ nghĩa là lỗi **vĩnh viễn** — thử lại bao nhiêu
lần cũng thế. Thường là dữ liệu sai (SKU không tồn tại, mã khách hàng sai),
không phải lỗi hạ tầng.

**Việc phải làm:**
1. Đọc nội dung message và `last_error`:
   ```sql
   SELECT dedup_id, body, last_error, moved_at
     FROM order_queue_dlq ORDER BY moved_at DESC LIMIT 20;
   ```
   Trên AWS: nhận message từ DLQ bằng console hoặc `aws sqs receive-message`.
2. Phân loại:
   - **Dữ liệu sai từ client** → liên hệ nghiệp vụ, không redrive. Ghi nhận
     đơn ở trạng thái `FAILED`, báo khách hàng.
   - **Lỗi do bug đã sửa** → redrive lại hàng đợi chính sau khi deploy bản vá.
3. Ghi lại vào sổ sự cố: mỗi message DLQ là một đơn hàng khách hàng không nhận
   được — phải có người chịu trách nhiệm đóng.

---

### Sự cố #5 — Xoá hoặc sửa nhầm đơn hàng

**Triệu chứng:** nghiệp vụ báo mất đơn, hoặc số liệu báo cáo sai lệch.

**Ràng buộc:** RPO ≤ 5 phút, RTO ≤ 30 phút, và **phải bảo toàn giao dịch hợp
lệ phát sinh sau thời điểm sự cố**.

> **Tuyệt đối không restore đè lên production.** Restore đè sẽ đưa database về
> thời điểm trước sự cố và xoá mất mọi đơn hợp lệ tạo ra sau đó. Yêu cầu yêu cầu
> rõ phải giữ lại chúng.

**Quy trình (bấm giờ thật, quay video):**

| Mốc | Việc |
|---|---|
| T+0 | Ghi lại `T_incident` chính xác. Dừng job/thao tác đang gây hại. |
| T+2 | RDS PITR restore về `T_incident − 1 phút` ra **instance mới** `rds-restore-tmp` |
| T+15 | Instance tạm sẵn sàng (dataset nhỏ thì nhanh hơn) |
| T+20 | `pg_dump` **chỉ các row bị ảnh hưởng** từ instance tạm |
| T+25 | `INSERT ... ON CONFLICT DO NOTHING` vào production |
| T+28 | Đối chiếu số lượng, xoá instance tạm |

```bash
# bước T+2
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier abc-prod-db \
  --target-db-instance-identifier rds-restore-tmp \
  --restore-time 2026-09-07T07:15:00Z \
  --db-subnet-group-name abc-db-subnet-group \
  --no-multi-az

# bước T+20 — chỉ lấy phần bị ảnh hưởng, không dump cả database
pg_dump -h rds-restore-tmp... -U abcapp -d abcsales \
  --data-only -t orders -t order_items \
  --where="created_at BETWEEN '2026-09-07T06:00:00Z' AND '2026-09-07T07:15:00Z'" \
  > /tmp/recover.sql

# bước T+25 — ON CONFLICT DO NOTHING: đơn còn nguyên thì không bị đụng tới
psql -h abc-rds-proxy... -U abcapp -d abcsales -f /tmp/recover.sql
```

**Đối chiếu sau khi khôi phục:**

```sql
-- số đơn theo ngày, so với báo cáo đã lưu trước sự cố
SELECT date_trunc('day', created_at) AS ngay, count(*), sum(total_amount)
  FROM orders WHERE status = 'CONFIRMED'
   AND created_at >= '2026-09-07' GROUP BY 1 ORDER BY 1;

-- xác nhận không có đơn trùng sinh ra từ quá trình khôi phục
SELECT idempotency_key, count(*) FROM orders
 GROUP BY idempotency_key HAVING count(*) > 1;
```

**Số đo thật trên AWS ngày 12/09/2026** (`evidence/aws-B6-pitr-restore-20260912T150205Z.log`):

| | Đo được | Ngân sách yêu cầu |
|---|---|---|
| RTO | **12 phút 49 giây** | 30 phút |
| RPO | **5–7 phút** (độ trễ `LatestRestorableTime`) | 5 phút |
| Đơn khôi phục | **50/50** | — |

Riêng bản restore mất ~11 phút trong tổng 12 phút 49 giây, phần còn lại là đối
chiếu và chèn ngược.

RPO 5–7 phút **chạm sát ngưỡng 5 phút** của yêu cầu. `LatestRestorableTime` của
RDS luôn trễ hơn hiện tại chừng đó, không chỉnh xuống được. Muốn chắc chắn dưới
5 phút thì phải đổi sang Aurora có backtrack, hoặc chấp nhận và ghi rõ trong
cam kết dịch vụ.

---

### Sự cố #6 — Thu hồi quyền file server của một phòng ban trong ≤ 5 phút

Dùng khi một phòng ban hoặc một nhân sự phải bị cắt quyền gấp.

**Hai bước, không được bỏ bước hai.**

```bash
# Bước 1 — chặn mọi mount MỚI
aws efs delete-access-point --profile abc-migration --access-point-id <fsap-...>

# Bước 2 — ép các máy đang mount nhả ra
aws ssm send-command --profile abc-migration \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Name,Values=abc-migration-dev-app" \
  --parameters 'commands=["umount -f -l /mnt/<phòng> || true"]' \
  --query 'Command.CommandId' --output text

# xác nhận đã nhả
aws ssm send-command --profile abc-migration \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Name,Values=abc-migration-dev-app" \
  --parameters 'commands=["mount | grep /mnt/<phòng> || echo DA-NHA"]'
```

**Vì sao bước hai là bắt buộc.** Đo thật ngày 12/09/2026
(`evidence/aws-A6-efs-revoke-20260912T142127Z.log`): sau khi xoá access point,
mount đang mở vẫn đọc ghi bình thường suốt 283 giây, không hỏng lần nào. EFS xét
access point ở thời điểm **mount**, không xét lại ở từng thao tác I/O. Bước một
một mình không đáp ứng được cam kết 5 phút.

**Không dùng cách gỡ rule 2049 khỏi security group.** Cũng đo thật: NFS không
báo lỗi mà **block**, tiến trình uvicorn treo theo, `/ready` quá hạn, ALB đánh
unhealthy, ASG giết và thay máy sau 13–52 giây. Thu hồi được quyền nhưng kéo
sập cả app tier.

**Cấp lại quyền:** tạo lại access point với đúng `posix_user` và
`root_directory` cũ (xem `deploy/terraform/modules/fileserver/`), rồi `mount`
lại trên máy. Thư mục và dữ liệu không bị đụng tới khi xoá access point.

---

## 5. Truy vết một giao dịch

Khi khách hàng hỏi "đơn của tôi đâu rồi":

```bash
# 1. Trạng thái hiện tại và correlation id
curl -s https://<alb>/api/orders/<order_id> | jq

# 2. Hành trình nghiệp vụ đầy đủ
curl -s https://<alb>/api/orders/<order_id>/trace | jq
```

```sql
-- 3. Trong DB
SELECT o.*, c.code FROM orders o JOIN customers c ON c.id = o.customer_id
 WHERE o.id = '<order_id>';
SELECT * FROM order_events WHERE order_id = '<order_id>' ORDER BY created_at;
```

```
-- 4. Toàn bộ log xuyên các tier (CloudWatch Logs Insights)
fields @timestamp, tier, level, event, order_id, @message
| filter correlation_id = "Root=1-abc..."
| sort @timestamp asc
```

Đọc chuỗi sự kiện:

| Chuỗi thấy được | Kết luận |
|---|---|
| `order.accepted` → `order.confirmed` | Bình thường |
| `order.accepted`, không có `order.confirmed` | Còn trong hàng đợi hoặc worker đang kẹt → sự cố #3 |
| `order.deduped` | Client gửi lại, hệ thống chặn đúng — không phải lỗi |
| `order.version_conflict` | Hai người cùng sửa, người sau bị từ chối — không phải lỗi |
| `worker.db_unavailable` lặp lại | Sự cố #2 |
| `worker.permanent_failure` | Dữ liệu sai → sự cố #4 |

---

## 6. Deploy và rollback

**Deploy** (CodeDeploy blue/green lên ASG):
1. GitHub Actions build artifact, đẩy lên S3, gọi CodeDeploy.
2. Deployment group tạo target group mới, health check `/health` phải xanh.
3. Chuyển traffic. `deregistration_delay = 30s` nên rolling nhanh.
4. Theo dõi alarm 5XX và p95 trong 10 phút sau khi chuyển.

**Rollback:** CodeDeploy giữ nguyên target group cũ trong thời gian chờ →
`aws deploy stop-deployment --auto-rollback-enabled`. Nếu đã qua thời gian chờ,
deploy lại revision trước đó.

**Rollback schema database:** mọi migration phải tương thích ngược ít nhất một
phiên bản (thêm cột trước, dùng sau; bỏ cột ở bản sau nữa). Không có bước này
thì blue/green không rollback được.

---

## 7. Việc định kỳ

| Tần suất | Việc |
|---|---|
| Hàng ngày | Xem dashboard: p95, tỷ lệ lỗi, độ sâu hàng đợi, DLQ |
| Hàng tuần | Kiểm tra backup chạy đủ; xem báo cáo Cost Explorer theo tag |
| Hàng tháng | **Diễn tập khôi phục** — restore thật ra instance tạm và bấm giờ |
| Hàng quý | Kiểm tra xoay vòng secret; rà soát IAM least-privilege |

Diễn tập khôi phục hàng tháng là mục dễ bị bỏ nhất và cũng là mục khiến RTO
30 phút trở thành con số thật thay vì con số trên giấy.
