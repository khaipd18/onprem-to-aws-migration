# Luồng đi xuyên hạ tầng

README từng module mô tả chính nó. File này mô tả **cái gì đi qua đâu**, và khi
hỏng thì rẽ hướng nào. Mọi con số lấy từ cấu hình thật trong `modules/`.

---

## 1. Người dùng mở trang

```
Trình duyệt
   │ GET https://dxxxx.cloudfront.net/
   ▼
CloudFront                                          modules/cdn
   │ default behavior, cache CachingOptimized
   │ viewer_protocol_policy = redirect-to-https
   ▼
S3 abc-migration-dev-assets-<account>            modules/static
   │ bucket đóng hoàn toàn, chỉ CloudFront đọc được
   │ qua Origin Access Control
   ▼
index.html + JS + CSS
```

**Mở thẳng `/orders/123`** thì S3 không có object đó, trả 403. CloudFront ánh xạ
403 và 404 thành **200 + `/index.html`**, SPA tự điều hướng. `error_caching_min_ttl
= 10` để lúc vừa deploy không giữ trạng thái lỗi lâu.

**Không có EC2 nào phục vụ trang.** Đây là điểm khác so với thiết kế hai tầng ban
đầu.

---

## 2. Tạo một đơn hàng — đường thành công

```
Trình duyệt
   │ POST /api/orders
   │ header Idempotency-Key: <uuid lưu trong localStorage>
   ▼
CloudFront  behavior /api/*                         modules/cdn
   │ cache CachingDisabled
   │ origin request policy AllViewerExceptHostHeader
   │   → chuyển tiếp hết header, cookie, query string TRỪ Host
   │   → nhờ vậy Idempotency-Key đi qua được
   ▼ HTTP 80
ALB abc-migration-dev-public                     modules/compute
   │ sg-alb-public, nhận 80 từ 0.0.0.0/0 hoặc prefix list CloudFront
   │ drop_invalid_header_fields = true
   ▼ HTTP 8080, target group health check /ready
EC2 App tier (2-6 máy, private subnet)              modules/compute
   │ sg-app, chỉ nhận 8080 từ sg-alb-public
   │
   ├─ (1) ghi bản nhận vào DynamoDB                 modules/queue
   │      PutItem ConditionExpression attribute_not_exists(idempotency_key)
   │      → gửi lại lần 2 bị chặn NGAY ĐÂY, chưa sinh message
   │
   ├─ (2) đẩy message vào SQS FIFO                  modules/queue
   │      MessageGroupId = mã khách hàng
   │      MessageDeduplicationId = Idempotency-Key
   │
   └─ (3) trả 202 Accepted + order_id + status PENDING
          KHÔNG trả "thành công"

          ─────────── tách rời ───────────

Worker (chạy cùng máy, systemd unit riêng)          modules/compute
   │ long polling SQS 20 giây
   ▼ 5432
RDS Proxy abc-migration-dev-proxy                modules/data
   │ sg-rds-proxy, require_tls, tối đa 90% kết nối
   ▼ 5432
RDS PostgreSQL 16.10 Multi-AZ                       modules/data
   │ sg-rds, chỉ nhận từ sg-rds-proxy và sg-app
   │ INSERT ... ON CONFLICT (idempotency_key) DO NOTHING
   ▼ commit xong
Worker xoá message khỏi SQS
   │
   ▼
Đơn chuyển PENDING → CONFIRMED
```

**Quy tắc bất di bất dịch:** worker **chỉ xoá message sau khi transaction
commit**. Đảo thứ tự là mất đơn.

---

## 3. Ba tuyến chống đơn trùng

Cùng một `Idempotency-Key` gửi 5 lần, bị chặn ở tuyến nào:

| Tuyến | Ở đâu | Chặn được gì | Module |
|---|---|---|---|
| 1 | `PutItem` có điều kiện trên DynamoDB | Lần 2–5 chặn ngay tại App tier, chưa sinh message | `queue` |
| 2 | `MessageDeduplicationId` của SQS FIFO | Trùng trong cửa sổ 5 phút, nếu lọt tuyến 1 | `queue` |
| 3 | `UNIQUE (idempotency_key)` + `ON CONFLICT DO NOTHING` | Tuyến cuối ở tầng DB | `data` |

Mã lưu trong `localStorage` nên **sống sót qua F5**.

---

## 4. Database chết — luồng rẽ hướng

```
Worker  ──5432──▶ RDS Proxy ──▶ RDS  ✗ không tới được
   │
   ├─ transaction KHÔNG commit
   ├─ worker KHÔNG xoá message
   └─ message quay lại SQS sau visibility timeout 180 giây

App tier vẫn sống:
   POST /api/orders  → vẫn ghi DynamoDB, vẫn đẩy SQS, vẫn trả 202
   GET  /api/orders/{id} → đọc DynamoDB (NGOÀI RDS) → trả PENDING
                           không trả 404, không trả 500
```

**Vì sao App tier không chết theo:** target group của ALB kiểm `/ready`, không
kiểm `/health`.

| Endpoint | Kiểm gì | Gắn vào target group |
|---|---|---|
| `/ready` | Tiến trình còn nhận request không | **có** |
| `/health` | Có tới được database không | không |

Nếu gắn `/health`: mọi máy rớt health check → ALB rút sạch target → ASG với
`health_check_type = ELB` coi là hỏng → **giết rồi tạo máy mới, máy mới cũng
hỏng y hệt**. Đơn đang xử lý mất.

**Khi database quay lại:** worker đang chạy, nhận lại message, commit, xoá
message. Không ai phải restart. Đo được **13 giây**.

**Nếu message hỏng vĩnh viễn** (sai SKU, sai mã khách): sau `max_receive_count = 5`
lần nhận không xoá, SQS đẩy sang DLQ. Alarm `dlq_not_empty` bắn ngay.

---

## 5. Một máy App tier chết

```
t+0s    máy chết
t+10s   health check /ready lần 1 fail
t+20s   lần 2 fail → ngưỡng unhealthy_threshold = 2 đạt
        ALB ngừng gửi request vào máy đó
        máy còn lại phục vụ tiếp
t+20s   ASG (health_check_type = ELB) đánh dấu unhealthy
        bắt đầu thay máy
t+50s   máy từ warm pool (trạng thái Stopped) bật lên
t+~90s  qua health check, vào lại target group
```

Người dùng thấy gì: **không thấy gì**. Request đang dở trên máy đó hỏng, request
tiếp theo đi sang máy còn lại.

`deregistration_delay = 30` giây: lúc rút máy ra, ALB chờ 30 giây cho request
đang chạy dở hoàn tất. Mặc định 300 giây, quá lâu cho release.

---

## 6. Tải tăng — scale out

```
Target tracking: 600 request/máy/phút

tải tăng → CloudWatch thấy ALBRequestCountPerTarget > 600
        → ASG tăng desired capacity
        → lấy máy từ warm pool (Stopped)   30-40 giây
        → nếu warm pool hết, tạo máy mới    2-3 phút
        → tối đa 6 máy
```

Warm pool giữ **2 máy Stopped**, chỉ tính tiền EBS khoảng 0,6 USD/tháng. Đây là
cách đạt ngưỡng gián đoạn ≤ 2 phút mà không trả tiền cho máy chạy không.

`reuse_on_scale_in = true`: lúc thu nhỏ, máy quay lại pool thay vì bị xoá.

---

## 7. Release

```
1. đóng gói app-<commit>.tar.gz  →  S3 artifacts (versioning bật)
2. sửa con trỏ current.txt       →  trỏ sang commit mới
3. aws autoscaling start-instance-refresh

   ASG thay từng nửa      min_healthy_percentage = 50
   chờ máy mới ổn định    instance_warmup = 120 giây
   rồi mới thay tiếp

4. máy mới không qua health check → refresh DỪNG, giữ nguyên bản cũ
```

Máy mới lúc boot đọc `current.txt` từ S3 qua **S3 Gateway Endpoint**, không đi
qua NAT. Cấu hình đọc từ SSM Parameter Store, không hardcode, không access key.

**Rollback** = sửa `current.txt` về commit cũ rồi refresh lại.

---

## 8. Báo cáo chạy song song

```
Job báo cáo
   │ chốt mốc thời gian T
   ▼
chờ replica replay tới T     pg_last_xact_replay_timestamp() >= T
   │ không kịp trong timeout → TRẢ LỖI, không xuất báo cáo thiếu
   ▼
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY
   │ mọi truy vấn trong job nhìn cùng một ảnh chụp
   ▼
WHERE created_at < T
```

Hai điều kiện để "không thiếu, không đếm trùng": **mốc chốt tường minh** và **một
ảnh chụp duy nhất**. Thiếu bước chờ replica thì báo cáo **thiếu đơn** vì replica
chậm vài giây so với primary.

Đo được: nhập đơn vẫn **p95 = 61 ms** trong lúc báo cáo chạy.

---

## 9. File server

```
EC2 App tier (sg-app)
   │ NFS 2049, bắt buộc TLS
   ▼
mount target ở mỗi AZ (subnet data)                 modules/fileserver
   │
   ▼ mount qua access point, KHÔNG mount gốc
EFS
   /sales       uid 6001 gid 5001  mode 0770
   /finance     uid 6002 gid 5002
   /hr          uid 6003 gid 5003
   /production  uid 6004 gid 5004
   /purchasing  uid 6005 gid 5005
   /shared      uid 6000 gid 5000 + secondary_gids = gid của cả 5 phòng
```

Access point **ép danh tính từ phía AWS**: quyết định máy mount qua nó *là ai*,
bất kể tiến trình chạy dưới uid nào, **kể cả `root`**.

File system policy có hai điều kiện, thiếu một là hỏng cả cơ chế:

| Điều kiện | Thiếu thì sao |
|---|---|
| `aws:SecureTransport = true` | Mount không mã hoá vẫn được chấp nhận |
| Bắt buộc có `elasticfilesystem:AccessPointArn` | Máy có quyền IAM rộng mount thẳng gốc, đọc hết mọi phòng ban |

**Thu hồi quyền** (hai bước, đo thật 12/09/2026 — `evidence/aws-A6-efs-revoke-*.log`):

1. Xoá access point → chặn mount mới ngay, không phải chờ cache credential hết hạn.
2. Ép `umount -f -l` qua SSM `send-command` trên máy đang mount.

Bước 1 một mình **không đủ**: đo được mount đang mở vẫn đọc ghi bình thường suốt
283 giây sau khi xoá access point. EFS xét access point lúc mount, không xét lại ở
từng thao tác I/O.

---

## 10. Truy vết một giao dịch

```
ALB sinh header X-Amzn-Trace-Id
   ▼
App tier đọc, đặt làm correlation_id
   ├─ ghi vào MỌI dòng log        → CloudWatch Logs
   ├─ gắn vào message SQS         → worker nhận lại đúng id
   └─ ghi vào bảng order_events   → lịch sử trong DB
```

Bốn truy vấn lưu sẵn trong CloudWatch Logs Insights:

| Tên | Dùng khi |
|---|---|
| `truy-vet-mot-giao-dich` | Có correlation id, xem toàn bộ chặng |
| `truy-vet-theo-ma-don` | Chỉ có mã đơn khách đọc qua điện thoại |
| `loi-gan-day` | Vừa nhận alarm, muốn biết lỗi gì |
| `request-cham` | p95 vượt ngưỡng, muốn biết endpoint nào |

---

## 11. Thứ tự phụ thuộc giữa các module

Terraform tự suy ra, nhưng biết thì đọc `plan` dễ hơn:

```
network ──┬──▶ security ──┬──▶ compute ──▶ observability
          │               │        ▲
          │               ├──▶ data┤
          │               │        │
          │               └──▶ fileserver
          │
iam ──────┴──▶ data, queue, compute, fileserver, migration
                    │
static ──▶ cdn      └──▶ compute (user-data cần tên bảng DynamoDB)
             ▲
             └── compute (cdn cần DNS của ALB)
```

Hai chỗ dễ vướng:

**`cdn` cần DNS của ALB** → phải apply hai bước: lần đầu không bật CloudFront,
lấy DNS, rồi apply lại với `create_cloudfront = true`.

**`compute` cần tên bảng DynamoDB** từ `queue` để ghi vào user-data. Nên thiếu
quyền tạo SQS là launch template và ASG cũng đứng theo.

---

## 12. Nơi tiền chảy

| Thành phần | USD/tháng | Ghi chú |
|---|---|---|
| RDS `db.t4g.micro` Multi-AZ | ~25 | Phần lớn hoá đơn |
| 2 × EC2 `t4g.small` | ~24 | |
| NAT Gateway | ~43 | Một cái, không phải hai |
| ALB | ~20 | |
| EFS, S3, SQS, DynamoDB, CloudWatch | ~10 | Nhỏ |
| Warm pool 2 máy Stopped | ~0,6 | Chỉ tiền EBS |

Hạ ASG về 0 và dừng RDS bằng `scripts/aws-env.sh down` còn khoảng 13 USD/tháng
tiền lưu trữ.
