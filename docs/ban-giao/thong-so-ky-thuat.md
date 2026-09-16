# AWS Services & Thông số kỹ thuật — Vai trò Cloud Engineer

**Dự án:** Migration ABC Manufacturing (on-premise → AWS)
**Vai trò:** Cloud Engineer (Infra/DevOps) — 40% điểm, trong đó Kết quả 20%
**Region:** `ap-southeast-1` (Singapore)

> Tài liệu này là **spec để dựng**. Mọi con số lấy từ giá trị mặc định trong `deploy/terraform/` — sửa một bên thì phải sửa bên kia.
>
> Kiến trúc chi tiết từng module: [`deploy/terraform/README.md`](../../deploy/terraform/README.md) · Các bước bấm Console tương ứng: [`huong-dan-console.md`](huong-dan-console.md) · Chi phí: [`chi-phi.md`](chi-phi.md)

---

## 0. Giả định

Yêu cầu cho phép tự đặt giả định. Danh sách đầy đủ ở [`gia-dinh.md`](gia-dinh.md); phần dùng cho sizing:

| Hạng mục | Quy mô production (bản SA) | Quy mô thực hành (bản triển khai) |
|---|---|---|
| Số user | 150 (1 HQ + 2 chi nhánh) | như trên |
| Tải bình thường | 50 req/s | 50 req/s |
| Tải cao điểm | 250 req/s trong 30 phút | 250 req/s trong 30 phút |
| Dung lượng PostgreSQL | 200 GB | 20 GB, autoscale tới 100 |
| Dung lượng File Server | 500 GB | 20–50 GB |
| Số phòng ban | 5 | 5 |
| Chi phí tháng | **1.100,51 USD** | **207,82 USD** |

Yêu cầu cho phép "thu nhỏ dung lượng dữ liệu thực hành nhưng phải giữ đầy đủ các hành vi". Nghĩa là: **giảm data, không giảm test case**. Bản 208 USD giữ nguyên Multi-AZ, RDS Proxy, warm pool, DMS, DataSync — không bỏ ràng buộc nào.

Hai giả định ảnh hưởng trực tiếp tới lựa chọn service:

- **File server chạy Linux, chia sẻ qua NFS, phân quyền POSIX** → EFS + Access Point, không phải FSx for Windows.
- **Xác thực người dùng nằm ngoài phạm vi.** Yêu cầu chỉ nói tới file server dùng chung, không nói tới đăng nhập. Người nhập đơn là nhân viên nội bộ, nhập thay cho khách hàng — không có khách hàng tự đăng nhập, nên không cần Cognito.

---

## 1. Networking → `modules/network`, `modules/security`

| Thành phần | Thông số |
|---|---|
| VPC CIDR | `10.0.0.0/16` |
| AZ | 2 (`ap-southeast-1a`, `ap-southeast-1b`) — bắt buộc cho Multi-AZ và ràng buộc #4 |
| Public subnet | `10.0.0.0/24`, `10.0.1.0/24` — ALB, NAT Gateway |
| Private subnet | `10.0.10.0/24`, `10.0.11.0/24` — EC2 App tier |
| Data subnet | `10.0.20.0/24`, `10.0.21.0/24` — RDS, RDS Proxy, EFS mount target, DMS. **Route table chỉ có `local`** |
| NAT Gateway | **1 cái** (single-AZ) — rẻ hơn ~43 USD/tháng |
| VPC Endpoint (Gateway) | **S3** — miễn phí, bật |
| VPC Endpoint (Interface) | **không dùng.** `ssm` + `ssmmessages` + `ec2messages` × 2 AZ ≈ 44 USD/tháng, đắt hơn cả NAT ở quy mô này |

**Điều phân biệt tầng `private` với tầng `data` là route table, không phải cái tên.** Tầng data không gắn IGW cũng không gắn NAT. Gộp hai tầng thì RDS có đường ra internet, mất hẳn tính tách biệt.

**Đánh đổi của một NAT:** AZ chứa NAT chết thì cả hai AZ mất đường ra internet. Không ảnh hưởng luồng nhận đơn — traffic vào đi qua ALB. Chỉ ảnh hưởng lúc ASG scale out phải tải artifact, mà việc đó đã đi qua S3 Gateway Endpoint.

### Security Group — xâu chuỗi, không dùng CIDR mở

```
Internet (0.0.0.0/0, hoặc prefix list CloudFront pl-31a34658)
        │ 80
        ▼
  sg-alb-public
        │ 8080
        ▼
     sg-app  ────────── 2049 ──────────▶ sg-fileserver
        │                                    (EFS)
        │ 5432                    ┌── 5432 ──┐
        ▼                         │          │
  sg-rds-proxy ──── 5432 ────▶ sg-rds ◀──────┘
                                       (đường dự phòng từ sg-app)

  sg-admin-client — không có luật vào, chỉ để được tham chiếu làm nguồn
```

| SG | Inbound | Port | Source |
|---|---|---|---|
| `sg-alb-public` | HTTP | 80 | `0.0.0.0/0`, hoặc prefix list CloudFront |
| `sg-app` | Custom TCP | **8080** | `sg-alb-public` |
| `sg-rds-proxy` | PostgreSQL | 5432 | `sg-app` |
| `sg-rds` | PostgreSQL | 5432 | `sg-rds-proxy` **và** `sg-app` |
| `sg-fileserver` | NFS | 2049 | `sg-app`, `sg-admin-client` |
| `sg-admin-client` | — | — | không có |

Ba điểm hay bị hỏi:

- **Chỉ port 80, không có 443.** CloudFront chấm dứt TLS ở edge. Tài khoản không có quyền ACM nên ALB không gắn được chứng chỉ. Có ACM thì thêm listener 443 và đổi `origin_protocol_policy` sang `https-only`.
- **`sg-rds` có hai nguồn.** Đường chính qua RDS Proxy; đường từ `sg-app` là dự phòng khi chưa dựng proxy và để chẩn đoán.
- **`sg-admin-client` không có rule vào mà vẫn cần.** Nó tồn tại để **được tham chiếu làm nguồn**.

Mọi luật đều lấy nguồn là **ID của security group tầng trên**, không phải dải IP. Đổi subnet, thêm AZ, tăng số instance đều không phải sửa luật.

Outbound: một luật cho phép tất cả. Chặn chiều ra ở tầng SG không thêm bao nhiêu an toàn trong khi làm hỏng những thứ khó đoán (gọi API AWS, cập nhật gói, gửi log). Việc chặn đường ra đã do route table của tầng data lo.

**Không mở SSH (22).** Truy cập bằng SSM Session Manager.

---

## 2. Front-end và App tier → `modules/static`, `modules/cdn`, `modules/compute`

### Kiến trúc SPA — vì sao không còn Web tier chạy EC2

Bản ban đầu có hai tầng EC2 (Web + App) và hai ALB. Theo khuyến nghị của SA, giao diện chuyển thành **SPA tĩnh trên S3, phục vụ qua CloudFront**.

| | Hai tầng EC2 | SPA + CloudFront |
|---|---|---|
| EC2 | 4 máy | 2 máy |
| ALB | 2 | 1 |
| Chi phí/tháng | 256,19 USD | **207,82 USD** |
| HTTPS tin cậy | cần ACM (không có quyền) | có sẵn `*.cloudfront.net` |
| CORS | có | không — cùng một origin |

Tách biệt Web/App **vẫn giữ**, chỉ là ranh giới nằm giữa CloudFront/S3 và ALB/EC2 thay vì giữa hai tầng EC2.

### CloudFront

| Tham số | Giá trị |
|---|---|
| Origin 1 | S3 `<prefix>-assets-<account-id>`, qua **Origin Access Control** |
| Origin 2 | ALB `<prefix>-public`, `origin_protocol_policy = http-only` |
| Default behavior | → S3, cache `CachingOptimized`, origin request `CORS-S3Origin` |
| Behavior `/api/*` | → ALB, cache **`CachingDisabled`**, origin request **`AllViewerExceptHostHeader`** |
| Viewer protocol | `redirect-to-https` |
| Custom error 403, 404 | → **200** + `/index.html`, TTL 10s |
| Price class | `PriceClass_200` (có edge châu Á) |
| Certificate | mặc định của CloudFront |

**Vì sao bắt buộc có CloudFront:** không phải để tăng tốc, mà vì **chứng chỉ TLS**. Không có quyền ACM thì đây là đường duy nhất có HTTPS được trình duyệt tin cậy, miễn phí và không cần quyền gì thêm.

`CachingDisabled` cho `/api/*` là bắt buộc — cache một POST tạo đơn hoặc một GET trạng thái đơn thì người dùng thấy dữ liệu cũ, vi phạm ràng buộc #3.

`AllViewerExceptHostHeader` chuyển tiếp toàn bộ header, cookie, query string xuống ALB **trừ** `Host`. Header `Idempotency-Key` đi qua được nhờ policy này.

Ánh xạ 403/404 → 200 + `index.html` là để SPA tự xử lý đường dẫn khi người dùng mở thẳng `/orders/123`.

### S3 chứa SPA

Block all public access, versioning bật, SSE-S3. **Không bật Static website hosting** — endpoint đó chỉ chạy HTTP và bắt buộc bucket public.

Terraform quản từng file bằng `aws_s3_object` với `for_each` qua `fileset()`, nên `plan` cho thấy chính xác file nào thêm/sửa/xoá. `content_type` tra từ map theo đuôi file — thiếu đuôi trong map thì object nhận `application/octet-stream` và trình duyệt tải file về thay vì hiển thị.

### App tier — EC2 + ASG

| Tham số | Giá trị |
|---|---|
| Instance type | **`t4g.small`** (2 vCPU, 2 GB, Graviton — rẻ hơn ~20%) |
| Fallback nếu app không chạy ARM | `t3.small` |
| `min_size` / `desired` / `max_size` | **2 / 2 / 6** |
| Trải AZ | 2 AZ, `balanced-best-effort` |
| Health check type | `ELB` |
| Health check grace period | 120s |
| Warm Pool | **2** instance ở trạng thái `Stopped`, `reuse_on_scale_in` |
| Instance refresh | Rolling, `min_healthy_percentage = 50`, `instance_warmup = 120` |
| Metadata | **IMDSv2 required** |

**Một launch template, hai systemd unit** — App tier và worker chạy chung máy. Ở quy mô này tách ASG riêng cho worker chỉ tốn thêm 2 instance mà không giải quyết vấn đề gì.

**Warm pool:** máy Stopped chỉ tính tiền EBS (~0,6 USD/tháng cho 8 GB), không tính giờ chạy. Scale out từ máy stopped mất 30–40 giây thay vì 2–3 phút. Đây là cách đạt "gián đoạn ≤ 2 phút" của ràng buộc #4 mà không trả tiền cho máy chạy không.

> **Bẫy về tag:** `default_tags` của provider **không** với tới ba chỗ — instance/volume/ENI do launch template tạo (phải khai `tag_specifications` cho từng loại), instance do ASG tạo (phải có `propagate_at_launch = true`), và snapshot tự động (phải `copy_tags_to_snapshot`). Công ty bắt buộc tag `owner`, nên bỏ sót là trượt.

### Chính sách scale

**Target tracking:** metric `ALBRequestCountPerTarget`, target value **600 req/target/phút** (≈10 req/s/target).

> Con số này **phải đo lại bằng load test**, đừng copy nguyên. Cách đo: chạy 1 instance duy nhất, tăng tải đến khi p95 chạm 1,5s → đó là ngưỡng an toàn.

Không dùng CPU-based scaling cho web spike — phản ứng quá trễ.

`lifecycle.ignore_changes = [desired_capacity]` trong Terraform: Terraform quản min/max, autoscaling quản desired. Không có dòng này thì mỗi `apply` kéo số máy về lại giá trị trong code, huỷ kết quả của target tracking.

### ALB (chỉ một, public)

| Tham số | Giá trị | Lý do |
|---|---|---|
| Scheme | `internet-facing` | |
| Listener | HTTP **80** → forward target group `app` | 443 chờ ACM |
| Target group port | **8080** | |
| **Health check path** | **`/ready`** | xem khung dưới |
| Interval / Timeout | **10** / 5 giây | |
| Healthy / Unhealthy threshold | **2 / 2** | phát hiện target chết trong **~20 giây** |
| Matcher | `200` | |
| `deregistration_delay` | **30s** (mặc định 300s) | rút ngắn rolling deploy |
| `drop_invalid_header_fields` | bật | bỏ header dị dạng thay vì chuyển xuống app |
| Access logs | → S3 `<prefix>-alb-logs-<account-id>` | bằng chứng cho test p95 và error rate |

> ### Health check phải là `/ready`, không phải `/health`
>
> Đây là quyết định quan trọng nhất của tầng compute, và nó đến từ ràng buộc #5.
>
> - `/health` chạm tới database.
> - `/ready` chỉ khẳng định tiến trình còn nhận được request.
>
> Nếu ALB kiểm `/health` thì lúc RDS chết 3 phút, **mọi** instance rớt health check, ALB rút sạch target, và ASG với `health_check_type = ELB` terminate rồi tạo máy mới — máy mới cũng hỏng y hệt vì database vẫn chưa lên. Đơn đang xử lý mất, test B4 fail.
>
> Với `/ready`, tiến trình sống, trả 503 trung thực, đưa đơn vào SQS, và tự hoạt động lại khi DB quay về. Test B4 xác nhận App tier và Worker **không hề restart** trong suốt 60 giây mất kết nối.
>
> `/health` vẫn hữu ích — chẩn đoán tay và làm nguồn cho alarm, chỉ là không gắn vào target group.

**→ Đáp ứng ràng buộc #4** (gián đoạn ≤ 2 phút): 20 giây phát hiện + instance còn lại phục vụ ngay = gián đoạn thực tế gần 0.

### Quy trình release

Yêu cầu nêu vấn đề "release thủ công, dễ sai sót". Cách xử lý:

1. Đẩy `app-<commit>.tar.gz` lên bucket artifact (versioning bật)
2. Cập nhật con trỏ `current.txt`
3. Gọi `start-instance-refresh`
4. ASG thay từng nửa nhóm, chờ máy mới qua health check 120 giây rồi mới thay tiếp
5. Máy mới không qua health check → refresh dừng, nhóm giữ nguyên bản cũ

Rollback = sửa `current.txt` về mã commit cũ rồi refresh lại. Chi tiết ở [`quy-trinh-release.md`](quy-trinh-release.md).

> **Không dùng AWS MGN.** MGN tạo instance nằm ngoài Terraform → xung đột trực tiếp với ràng buộc #8. Chỉ migrate *dữ liệu* (DMS + DataSync), compute dựng lại bằng IaC.

---

## 3. Database → `modules/data`

### RDS for PostgreSQL

| Tham số | Giá trị | Ràng buộc |
|---|---|---|
| Engine | PostgreSQL **16.10** (ghim tới minor) | #8 — dựng lại ra đúng engine |
| Instance class | **`db.t4g.micro`** | nâng nếu load test fail |
| **Multi-AZ** | **Bật** (instance deployment) | #5, #6 — failover 60–120s |
| Storage | `gp3`, **20 GB**, autoscaling max **100 GB** | |
| Backup retention | **7 ngày** | #6 — PITR |
| Backup window | 17:00–18:00 UTC (ngoài giờ VN) | |
| Maintenance window | CN 18:30–19:30 UTC | |
| Encryption at rest | bật, key mặc định `aws/rds` | |
| Deletion protection | bật | |
| Performance Insights | bật | #10 — bằng chứng khi chạy job báo cáo |
| Log exports | `postgresql`, `upgrade` | |

**Multi-AZ ghi đồng bộ sang standby ở AZ khác**, nên RPO = 0 cho sự cố mất AZ, failover tự động thường xong trong 60–120 giây — thừa so với RTO 30 phút của ràng buộc #6. Backup 7 ngày phủ trường hợp còn lại: hỏng dữ liệu do lỗi ứng dụng, khôi phục theo thời điểm với độ chi tiết 5 phút.

> **Multi-AZ instance (60–120s)** vs **Multi-AZ DB Cluster (~35s)**: cluster nhanh hơn nhưng tốn 3 instance. Ràng buộc #5 chỉ yêu cầu "tự phục hồi" nên instance deployment là đủ và rẻ hơn.

### Parameter group

| Tham số | Giá trị | Áp dụng | Lý do |
|---|---|---|---|
| `rds.force_ssl` | `1` | pending-reboot | Từ chối kết nối không mã hoá — không có cách nào client quên bật TLS mà vẫn vào được |
| `rds.logical_replication` | `1` | pending-reboot | Cần cho cutover bằng logical replication |
| `log_min_duration_statement` | `500` | immediate | Nguồn dữ liệu để truy p95 khi vượt ngưỡng (#4) |
| `log_lock_waits` | `1` | immediate | Dấu hiệu báo cáo đang chặn OLTP (#10) |
| `idle_in_transaction_session_timeout` | `60000` | immediate | Cắt phiên mở transaction rồi bỏ đó quá 60 giây |

Hai tham số đầu là static — gắn xong phải reboot instance.

### Mật khẩu

`random_password` sinh mật khẩu lúc apply rồi ghi vào **hai chỗ**, vì hai người dùng khác nhau:

| Chỗ lưu | Ai đọc |
|---|---|
| SSM Parameter Store `/<prefix>/db/password` (SecureString) | **Ứng dụng** — rẻ, đọc nhiều |
| Secrets Manager `<prefix>/db/master` | **RDS Proxy** — nó không hỗ trợ Parameter Store |

Không ai gõ mật khẩu vào `terraform.tfvars`, không mật khẩu nào đi qua Git. Nó vẫn nằm trong state file — đó là lý do state phải để trên S3 có mã hoá và versioning.

### RDS Proxy — service then chốt cho ràng buộc #5

| Tham số | Giá trị |
|---|---|
| Engine family | POSTGRESQL |
| Auth | Secrets Manager |
| **Security group** | **`sg-rds-proxy`** — không dùng chung `sg-rds` |
| `MaxConnectionsPercent` | 90 |
| `RequireTLS` | true |

> **Security group của proxy phải là `sg-rds-proxy`.** Đặt proxy vào `sg-rds` thì chính nó trở thành thứ mà `sg-rds` không cho phép kết nối vào — `sg-rds` chỉ nhận từ `sg-rds-proxy` và `sg-app`. Proxy sẽ không chạm được database.

Hai việc proxy làm:

1. **Gộp connection.** `db.t4g.micro` chỉ chịu khoảng 85 kết nối; ASG scale lên 6 máy mà mỗi máy tự mở pool riêng là chạm trần.
2. **Giữ kết nối xuyên failover.** Ứng dụng thấy câu lệnh chậm chứ không thấy kết nối đứt, nên không trả "thành công giả" cho đơn chưa ghi được. Không có Proxy thì phải tự viết retry/reconnect trong app và rất khó chứng minh.

Chi phí ≈ 22 USD/tháng.

### Read Replica — bị SCP chặn

`rds:CreateDBInstanceReadReplica` bị **SCP của Organization** từ chối. Đây là chặn ở cấp tổ chức — IT của tài khoản không cấp được, khác hẳn việc thiếu quyền trong identity policy.

Ràng buộc #10 xử lý bằng cách chạy job báo cáo trên primary trong transaction `REPEATABLE READ` với mốc chốt tường minh. Bảng `report_runs` có cột `ran_on` ghi rõ đã chạy ở đâu.

Đường vòng nếu cần: `rds:CreateDBCluster` **được phép**, nên Multi-AZ DB Cluster có reader endpoint là phương án thay thế.

Khi có replica, điểm chốt là **chờ replica replay tới mốc chốt trước khi query**: `pg_last_xact_replay_timestamp()` phải vượt qua cutoff. Replica là bất đồng bộ; chạy báo cáo ngay lúc chốt mốc thì `created_at < T` trên replica trả về **ít đơn hơn thực tế** — báo cáo thiếu đơn, đúng thứ ràng buộc #10 cấm. Code ở `app/common/orders.py::_wait_for_replica_catchup`, thà trả 503 còn hơn xuất báo cáo thiếu.

---

## 4. Migration dữ liệu → `modules/migration`

### AWS DMS — cho PostgreSQL (ràng buộc #2)

| Tham số | Giá trị |
|---|---|
| Replication instance | **`dms.t3.micro`**, 50 GB, **Single-AZ** |
| Loại task | **Full load + CDC** |
| Source endpoint | PostgreSQL on-prem (giả lập bằng EC2 ở VPC riêng) |
| Target endpoint | RDS PostgreSQL |
| `TargetTablePrepMode` | **`DO_NOTHING`** |
| **Data Validation** | **bật**, `ValidationMode = ROW_LEVEL` |
| `ApplyErrorPolicy` | **`STOP_TASK`** |
| Start task on create | **tắt** |
| CloudWatch logs | bật |

Ba thiết lập đáng giải thích:

| Thiết lập | Vì sao |
|---|---|
| Validation `ROW_LEVEL` | DMS đọc lại từng dòng ở hai đầu và so sánh — bằng chứng "không mất giao dịch" thay vì chỉ tin là xong |
| `ApplyErrorPolicy = STOP_TASK` | Gặp dòng lỗi thì dừng hẳn. Mặc định là bỏ qua và đi tiếp — mất dữ liệu âm thầm, đúng thứ #2 cấm |
| `TargetTablePrepMode = DO_NOTHING` | Không tự tạo hay xoá bảng ở đích. Schema do `db/01-schema.sql` tạo; để DMS tự tạo sẽ ra kiểu dữ liệu lệch |

**Task tạo ra ở trạng thái dừng.** Start là bắt đầu ghi vào database đích — chạy nhầm lúc `terraform apply` sẽ đụng dữ liệu thật.

**Yêu cầu phía source:** `wal_level = logical`, `max_replication_slots ≥ 5`, `max_wal_senders ≥ 5`, user có quyền `REPLICATION`.

**Quy trình cutover ≤ 15 phút:**

1. Full load chạy trước nhiều giờ, CDC bám realtime
2. `T+0` — bật maintenance page trên ALB (fixed-response rule), ngừng nhận đơn mới
3. `T+2` — chờ `CDCLatencySource` và `CDCLatencyTarget` về 0
4. `T+5` — dừng DMS task, chạy Data Validation
5. `T+6` — **reset toàn bộ sequence ở đích**
6. `T+8` — đổi connection string sang RDS Proxy (SSM Parameter)
7. `T+10` — smoke test
8. `T+12` — gỡ maintenance page

> **Việc DMS không làm: sequence.** DMS chép dữ liệu chứ không chép giá trị hiện tại của sequence. Cutover xong mà không reset thì `INSERT` đầu tiên đâm vào khoá chính đã tồn tại — `UniqueViolation` trên `orders_pkey`. Bước reset phải quét **toàn bộ** sequence qua `pg_get_serial_sequence`, không liệt kê tay từng bảng: liệt kê tay đã từng bỏ sót `order_items`, `order_events`, `report_runs`.

**Kết quả đo được** (bằng logical replication, cùng nguyên lý — `scripts/test-a1-migration-cutover.sh`): downtime **0,8 giây**, 2.086 đơn khớp, **0 đơn trùng**.

> **Phương án thay thế: PostgreSQL native logical replication** — miễn phí, PG→PG rất mượt, và đó là cách bài test A1 đang dùng. DMS cho báo cáo Data Validation sẵn nên bằng chứng đẹp hơn khi demo. Nêu cả hai trong báo cáo.

### AWS DataSync — cho File Server (ràng buộc #7)

| Tham số | Giá trị |
|---|---|
| Source location | **S3** (bản sao file server) |
| Destination | **EFS** |
| **Agent** | **không cần** — S3→EFS chạy agentless |
| `PreserveDeletedFiles` | `PRESERVE` |
| **POSIX permissions** | **`PRESERVE`** — giữ owner, group, mode, kể cả bit setgid |
| `posix_uid` / `posix_gid` | `INT_VALUE` — giữ nguyên số uid/gid |
| `VerifyMode` | `POINT_IN_TIME_CONSISTENT` |
| Chi phí | 0,0125 USD/GB truyền, **không có phí instance** |

**Agent chỉ bắt buộc khi nguồn là NFS hoặc SMB tự quản.** Ở đây cả hai đầu đều là dịch vụ AWS nên DataSync chạy thẳng. Với vài chục MB tài liệu thì phần file gần như miễn phí — dựng thêm một EC2 agent là lãng phí.

> `PRESERVE` là điểm mấu chốt. Không có nó, mọi file sang EFS đều thuộc về cùng một owner và toàn bộ phân quyền theo phòng ban trở thành vô nghĩa.

---

## 5. File Server → `modules/fileserver`

### EFS + Access Point

| Service | Thông số |
|---|---|
| **EFS** | General Purpose, Elastic throughput, encryption at rest bằng key `aws/elasticfilesystem` |
| Lifecycle | → Infrequent Access sau **30 ngày** không truy cập |
| Mount target | mỗi AZ một cái, trong subnet `data-*`, SG `sg-fileserver` |
| AWS Backup | bật |

Instance trong một AZ phải nối tới mount target trong **chính AZ đó** — đi chéo AZ vừa tốn phí truyền dữ liệu vừa mất khả năng chịu lỗi.

Lifecycle sang IA: file tài liệu cũ chuyển sang lớp rẻ hơn ~90%, phí truy cập cao hơn khi cần đọc lại. Hợp với file server: phần lớn file ghi một lần rồi hiếm khi mở lại.

### Access Point theo phòng ban

| Phòng ban | UID / GID | Root directory | Quyền |
|---|---|---|---|
| sales | 6001 / 5001 | `/sales` | `0770` |
| finance | 6002 / 5002 | `/finance` | `0770` |
| hr | 6003 / 5003 | `/hr` | `0770` |
| production | 6004 / 5004 | `/production` | `0770` |
| purchasing | 6005 / 5005 | `/purchasing` | `0770` |
| dùng chung | 6000 / 5000 | `/shared` | `0770` |

Access point `shared` khai thêm **secondary GIDs** là gid của cả năm phòng ban.

UID/GID khớp đúng với `deploy/local/fileserver-entrypoint.sh` ở nguồn, nên `diff` hai bản kiểm kê là so được trực tiếp.

**Access point ép danh tính từ phía server:** `posix_user` quyết định máy mount qua nó **là ai**, bất kể tiến trình chạy dưới uid nào — kể cả khi có `root` trên EC2. Client không có cách nào tự khai mình thuộc phòng khác.

### File system policy — hai điều kiện bắt buộc

1. **`aws:SecureTransport = true`** — từ chối mount không có TLS.
2. **Mount phải qua access point** — từ chối request không mang `elasticfilesystem:AccessPointArn`.

> Không có điều kiện thứ hai thì một máy có quyền IAM đủ rộng vẫn mount thẳng gốc file system và đọc hết mọi phòng ban, vô hiệu hoá toàn bộ phần phân quyền ở trên.

### Thu hồi quyền trong ≤ 5 phút

Bỏ user khỏi POSIX group **không có hiệu lực ngay** với phiên đang mở: group membership được phân giải lúc thiết lập phiên.

Đã đo trên AWS thật ngày 12/09/2026, `evidence/aws-A6-efs-revoke-*.log`:

| Cách | Hiệu lực đo được |
|---|---|
| Xoá access point của phòng đó | chặn mount mới ngay. **Không cắt phiên đang mount** — đo 283 giây vẫn đọc ghi bình thường |
| Gỡ `elasticfilesystem:ClientMount`/`ClientWrite` khỏi IAM role | chưa đo. IAM cũng xét lúc mount nên nhiều khả năng giống hàng trên |
| Gỡ SG của client khỏi rule 2049 của mount target | cắt được, nhưng NFS block chứ không lỗi → `/ready` quá hạn → ASG thay máy sau 13–52 giây. **Không dùng** |
| Đổi group ownership trên thư mục | chỉ chặn phiên mở sau đó — **không đủ** |

Nguyên nhân hàng đầu: NFS client giữ file handle đã mở; EFS xét access point ở thời điểm **mount**, không xét lại ở từng thao tác đọc ghi.

**Quy trình đạt ≤ 5 phút:** xoá access point (chặn mount mới) **+** ép `umount -f -l` trên các máy đang mount qua SSM `send-command`. Bước hai là bước bảo đảm thời gian, vì nó chủ động chứ không chờ client tự phát hiện.

Cảnh báo ở bản trước — "đừng ghi *tức thì* vào báo cáo khi chưa có số" — đã đúng: bản trước ghi theo suy luận và sai. Phần phân quyền vẫn đạt 30/30 (`scripts/test-a5-fileshare-perms.sh`), chỉ vế thu hồi phải sửa lại.

---

## 6. Tính đúng đắn giao dịch (ràng buộc #3, #5) → `modules/queue`

Đây là bài toán **application-level**. Infra chỉ tạo điều kiện. Nếu app viết ẩu thì test #3/#5 fail dù hạ tầng chuẩn.

### Đường đi của một đơn

```
   App tier
      │ 1. ghi bản nhận  ──▶  DynamoDB <prefix>-accept
      │ 2. đẩy message   ──▶  SQS FIFO  <prefix>-orders.fifo
      │ 3. trả 202 cho client
                                 ▼
                              Worker  ──▶ RDS
                                 │
                    quá 5 lần nhận không xong
                                 ▼
                       <prefix>-orders-dlq.fifo   (giữ 14 ngày)
```

### SQS FIFO

| Tham số | Giá trị |
|---|---|
| Loại queue | **FIFO** (`<prefix>-orders.fifo`) |
| `ContentBasedDeduplication` | false — dùng `MessageDeduplicationId` = Idempotency-Key từ client |
| Cửa sổ khử trùng lặp | 5 phút (cố định của FIFO) |
| **`DeduplicationScope`** | **`messageGroup`** |
| **`FifoThroughputLimit`** | **`perMessageGroupId`** |
| `MessageGroupId` | `order-{customer_code}` — song song hoá theo khách hàng |
| `VisibilityTimeout` | 180s (≥ 6× thời gian xử lý worker) |
| `MessageRetentionPeriod` | **14 ngày** (tối đa) |
| `ReceiveMessageWaitTime` | 20s — long polling |
| Encryption | **SSE-SQS** — key do SQS quản lý, không tính tiền |
| **DLQ** | `<prefix>-orders-dlq.fifo`, `maxReceiveCount = 5`, giữ 14 ngày |

> **Hai tham số `DeduplicationScope` và `FifoThroughputLimit` phải đặt cùng nhau**, đặt một cái AWS từ chối. Mặc định FIFO giới hạn 300 message/giây trên toàn queue; theo message group thì lên 3.000. Vì `MessageGroupId` là mã khách hàng nên các khách khác nhau không chờ nhau — đây là phần đáp ứng ràng buộc #4.

**Vì sao FIFO chứ không Standard:** Standard có thể giao một message nhiều lần và không giữ thứ tự. FIFO cho hai thứ mà ràng buộc #3 cần — khử trùng lặp trong 5 phút theo `MessageDeduplicationId`, và thứ tự trong cùng một message group để bản sửa cũ không đè bản mới.

**DLQ giữ 14 ngày** để có đủ thời gian điều tra rồi redrive lại. Alarm bắn ngay khi DLQ có message — DLQ có message nghĩa là có đơn chưa vào được database.

### DynamoDB — accept store

| Tham số | Giá trị |
|---|---|
| Table | `<prefix>-accept` |
| Partition key | **`idempotency_key`** (String) |
| GSI | **`order_id-index`**, hash key `order_id`, projection ALL |
| TTL attribute | **`expires_at`** (app ghi mốc 24 giờ) |
| Billing | **PAY_PER_REQUEST** |
| Encryption | AWS owned key (mặc định của DynamoDB) |
| Point-in-time recovery | bật |

> Ba tên trên do ứng dụng gọi cứng trong `app/common/store.py`. Đặt sai tên là app chạy nhưng hỏng ở đúng lúc cần nhất.

**Vì sao DynamoDB chứ không phải S3 hay một bảng trong RDS:**

| | RDS | S3 | DynamoDB |
|---|---|---|---|
| Còn đọc được khi RDS chết | không | có | có |
| Chặn trùng bằng ghi có điều kiện | có | không | có |
| Tra theo `order_id` | có | không | có, qua GSI |

`PutItem` với `ConditionExpression = attribute_not_exists(idempotency_key)`. Client bấm gửi lại 5 lần cùng một Idempotency-Key thì lần 2–5 bị chặn ngay tại App tier, chưa kịp sinh message vào hàng đợi.

### Cách ba ràng buộc được đáp ứng

| Ràng buộc | Cơ chế |
|---|---|
| Không tạo đơn trùng khi user gửi lại | Client sinh `Idempotency-Key` (UUID, lưu trong `localStorage` để sống sót qua F5) → dùng làm điều kiện `PutItem` trên DynamoDB (tuyến 1), `MessageDeduplicationId` của SQS (tuyến 2), và `UNIQUE` + `ON CONFLICT DO NOTHING` trên bảng `orders` (tuyến 3) |
| Không âm thầm ghi đè khi nhiều người cùng sửa | Cột `version INT` + `UPDATE ... WHERE version = $expected` → 0 row affected = trả HTTP 409, ghi `CONFLICT` vào `order_events`, không ghi đè |
| Xác định trạng thái khi mất kết nối | Đơn vào SQS trước → API trả **`202 Accepted`** + `order_id`, **không trả "thành công"**. Client poll `GET /orders/{id}` để biết `PENDING`/`CONFIRMED`/`FAILED`. Bản ghi accept nằm ngoài RDS nên khi RDS chết, GET vẫn trả `PENDING` thay vì 404 hay 500 |
| DB chết 3 phút → không báo thành công khống | Worker chỉ xoá message **sau khi** transaction commit. Không commit được → message quay lại queue → đơn giữ `PENDING`. DB hồi → worker tự drain → **không mất, không trùng, không cần restart tay** |

> Điểm mấu chốt: **API không được trả 200 "đơn đã tạo" trước khi DB commit.** Đây chính là thứ ràng buộc #5 kiểm tra.

---

## 7. Backup & khôi phục (ràng buộc #6 — RPO 5 phút / RTO 30 phút)

| Service | Thông số |
|---|---|
| **RDS PITR** | Retention 7 ngày. Latest restorable time ≈ hiện tại − 5 phút → **đáp ứng RPO 5 phút** |
| **RDS Multi-AZ** | RPO = 0 cho sự cố mất AZ (ghi đồng bộ sang standby) |
| **EFS Backup** | AWS Backup, daily |
| **DynamoDB PITR** | bật |
| **S3** (ALB logs, artifact, assets) | Versioning bật, lifecycle dọn bản cũ |

### Kịch bản khôi phục đơn hàng bị xoá nhầm (demo bắt buộc)

Không restore đè lên production — sẽ mất các giao dịch hợp lệ sau thời điểm sự cố (yêu cầu yêu cầu "bảo toàn giao dịch hợp lệ ngoài phạm vi sự cố").

1. `T+0` — phát hiện sự cố, ghi lại `T_incident`
2. `T+2` — RDS PITR restore về `T_incident − 1 phút` ra **instance mới** `<prefix>-db-restore`
3. `T+15` — instance mới sẵn sàng
4. `T+20` — `pg_dump` chỉ các row bị ảnh hưởng từ instance tạm
5. `T+25` — `INSERT ... ON CONFLICT DO NOTHING` vào production
6. `T+28` — đối chiếu số lượng, xoá instance tạm

**Đo thật trên AWS ngày 12/09/2026** (`evidence/aws-B6-pitr-restore-20260912T150205Z.log`):
RTO **12 phút 49 giây** / ngân sách 30 phút, RPO **5–7 phút** / ngân sách 5 phút,
khôi phục đủ **50/50** đơn. Riêng bản restore chiếm ~11 phút trong tổng số.

RPO 5–7 phút chạm sát ngưỡng yêu cầu. `LatestRestorableTime` của RDS luôn trễ hơn
hiện tại chừng đó và không chỉnh xuống được; muốn chắc dưới 5 phút thì phải đổi
sang Aurora có backtrack.

> Phần này **phải đo trên RDS thật**, không đo được ở môi trường local — PITR là tính năng của dịch vụ.

---

## 8. Observability & truy vết (ràng buộc #8) → `modules/observability`

| Service | Thông số |
|---|---|
| **CloudWatch Agent** | Trên mọi EC2: log app, `/var/log/messages` |
| **CloudWatch Logs** | Log group `/<prefix>/app`, retention **30 ngày** |
| **CloudWatch Logs Insights** | 4 truy vấn lưu sẵn (bảng dưới) |
| **Metric filter** | Đếm dòng log `ERROR`/`CRITICAL` |
| **SNS** | Topic `<prefix>-alerts` → email |
| **ALB access logs** | → S3, dùng Athena tính p95 và error rate |
| **CloudTrail** | Bật ở cấp tài khoản |
| **X-Ray** | Không dùng — correlation-ID trong log đã đủ cho yêu cầu truy vết |
| **Synthetics canary** | Không dùng — canary 1 phút/lần không đủ phân giải cho ngân sách 2 phút; dùng vòng lặp curl 1 giây |

### Correlation ID — cách rẻ nhất đạt yêu cầu truy vết

ALB tự sinh header `X-Amzn-Trace-Id`. App đọc và ghi vào **mọi** dòng log, kèm cả `order_id`. Bảng `order_events` lưu thêm hành trình trong DB.

```
fields @timestamp, @message
| filter correlation_id = "Root=1-abc..."
| sort @timestamp asc
```

→ Ra toàn bộ hành trình một giao dịch qua các tier.

### Truy vấn Logs Insights lưu sẵn

| Tên | Dùng khi |
|---|---|
| `<prefix>/truy-vet-mot-giao-dich` | Có `correlation_id`, xem toàn bộ chặng |
| `<prefix>/truy-vet-theo-ma-don` | Chỉ có mã đơn khách hàng đọc qua điện thoại |
| `<prefix>/loi-gan-day` | Vừa nhận alarm, muốn biết lỗi gì |
| `<prefix>/request-cham` | p95 vượt ngưỡng, muốn biết endpoint nào chậm |

### Metric filter — phải là JSON pattern

```
{ ($.level = "ERROR") || ($.level = "CRITICAL") }
```

> Ứng dụng ghi log JSON. Dùng text pattern `"?ERROR ?CRITICAL"` thì filter vẫn khớp dòng log, nhưng nếu metric có dimension theo field JSON (`$.tier`) thì giá trị trích ra rỗng — metric ra rỗng, alarm không bao giờ bắn.

### Tám alarm

| Alarm | Thống kê | Ngưỡng | Chu kỳ | Missing data | Ràng buộc |
|---|---|---|---|---|---|
| ALB `TargetResponseTime` | **p95** | > **2** giây | 2 × 60s | notBreaching | #4 |
| 5XX ÷ RequestCount × 100 | metric math | > **1** % | 2 × 60s | notBreaching | #4 |
| ALB `UnHealthyHostCount` | Maximum | > 0 | 1 × 60s | notBreaching | #4 |
| RDS `DatabaseConnections` | Average | > **68** (80% của 85) | 3 × 60s | missing | #5 |
| RDS `CPUUtilization` | Average | > 80 % | 5 × 60s | missing | #10 |
| RDS `FreeStorageSpace` | Minimum | < **2 GB** | 1 × 300s | missing | #6 |
| SQS `ApproximateAgeOfOldestMessage` | Maximum | > **300** giây | 2 × 60s | notBreaching | #3 |
| DLQ `ApproximateNumberOfMessagesVisible` | Maximum | > 0 | 1 × 60s | notBreaching | #3 |

Hai ngưỡng đầu lấy thẳng từ yêu cầu.

Ba chi tiết dễ sai:

- **p95, không phải Average.** 95 request 100 ms và 5 request 10 giây cho trung bình 595 ms — nghe ổn, trong khi 5% người dùng chờ 10 giây. CloudWatch tính percentile phải khai bằng `extended_statistic`.
- **Tỉ lệ lỗi không có metric sẵn**, phải ghép bằng metric math.
- **`treat_missing_data` khác nhau.** ALB và SQS: không có request thì không có metric, im lặng là bình thường → `notBreaching`, để không báo động mỗi đêm. RDS luôn phát metric khi còn sống, metric biến mất nghĩa là có vấn đề → `missing`.

> **Bẫy SNS:** email subscription tạo ra ở trạng thái `PendingConfirmation`. Chưa bấm link xác nhận thì alarm vẫn bắn, vẫn đổi trạng thái, chỉ là không ai biết.

---

## 9. IaC & CI/CD

### Terraform — bắt buộc, không phải tuỳ chọn

Ràng buộc #8 ghi rõ: *"Có thể triển khai lại môi trường từ hồ sơ bàn giao mà không phụ thuộc vào cấu hình chỉ lưu trên máy cá nhân."* Không có IaC = không đạt.

```
deploy/terraform/
├── versions.tf      ghim terraform >= 1.9, provider aws ~> 6.0
├── providers.tf     provider + default_tags
├── variables.tf     biến chung + tham số mạng
├── locals.tf        name_prefix, common_tags
├── main.tf          gọi module
├── outputs.tf
└── modules/
    ├── network/         VPC, subnet 3 tầng, IGW, NAT, S3 endpoint
    ├── security/        6 security group xâu chuỗi
    ├── iam/             role EC2, role RDS Proxy, policy least privilege
    ├── data/            RDS Multi-AZ, parameter group, SSM, RDS Proxy
    ├── queue/           SQS FIFO + DLQ, DynamoDB accept store
    ├── compute/         ALB, target group, launch template, ASG + warm pool
    ├── static/          S3 chứa SPA
    ├── cdn/             CloudFront + OAC
    ├── observability/   SNS, 8 alarm, metric filter, truy vấn lưu sẵn, dashboard
    ├── fileserver/      EFS + access point theo phòng ban
    └── migration/       DMS + DataSync
```

| Tham số | Giá trị |
|---|---|
| Terraform version | `>= 1.9` — hỗ trợ S3 native state locking (`use_lockfile`), khỏi cần bảng DynamoDB |
| AWS provider | **`~> 6.0`** |
| State backend | S3, versioning + encryption bật |
| Tag bắt buộc | **`owner`** (yêu cầu của công ty), kèm `Project`, `Environment`, `ManagedBy` |

Mỗi module có `README.md` riêng mô tả kiến trúc, quyết định thiết kế và lý do. **Không có comment trong file `.tf`** — code nói *cái gì*, README nói *vì sao*.

Ba cờ bật tắt còn lại, mỗi cờ ứng với một quyết định thật: `create_migration` (DMS chỉ chạy lúc cutover), `create_cloudfront` (cần DNS của ALB trước), `create_rds_proxy` (để so sánh có/không proxy).

**Bằng chứng cần demo:** `terraform destroy` rồi `terraform apply` dựng lại từ đầu, quay video. Kèm `.terraform.lock.hcl` để ghim provider tới từng checksum.

### CI/CD — chỉ cần mức concept

Yêu cầu Mục 4.2: *"không yêu cầu pipeline hoàn chỉnh, chỉ cần thể hiện đúng ý tưởng vận hành"*.

| Thành phần | Lựa chọn |
|---|---|
| Source | GitHub |
| CI | **GitHub Actions** + **OIDC** → IAM role (không dùng access key tĩnh) |
| Build | Đóng gói artifact `app-<commit>.tar.gz` → S3, cập nhật `current.txt` |
| Deploy | `start-instance-refresh` trên ASG, rolling 50%, health check gate |

Quy trình chi tiết: [`quy-trinh-release.md`](quy-trinh-release.md).

> **Không dùng CodeCommit** — AWS đã ngừng nhận khách hàng mới từ 07/2024.
> **Không dùng ECR.** Ứng dụng là một tiến trình Python chạy bằng systemd; cài Docker daemon lên mỗi instance chỉ để chạy một tiến trình là thừa.

---

## 10. Bảo mật & truy cập

| Service | Thông số |
|---|---|
| **SSM Session Manager** | Thay hoàn toàn bastion/SSH. Role `AmazonSSMManagedInstanceCore` |
| **IMDSv2 required** | Chặn cả một lớp lỗ hổng SSRF đọc trộm credential từ metadata endpoint |
| **Secrets Manager** | Mật khẩu master cho RDS Proxy đọc |
| **SSM Parameter Store** | Cấu hình ứng dụng; mật khẩu để SecureString, mã hoá bằng key `aws/ssm` |
| **KMS** | Không tạo CMK. Mỗi dịch vụ dùng key mặc định của nó — xem ghi chú dưới |
| **ACM** | **Không có quyền.** HTTPS lấy từ chứng chỉ mặc định của CloudFront |
| **IAM** | Một role cho EC2 + một role cho RDS Proxy, least privilege. Không dùng user + access key |

**Vì sao không tạo CMK:** dữ liệu vẫn mã hoá at-rest ở mọi chỗ bằng key mặc định của từng dịch vụ (`aws/rds`, `aws/ssm`, `aws/elasticfilesystem`, `aws/secretsmanager`, SSE-SQS, AWS owned key của DynamoDB). Cái mất là quyền sửa key policy và dùng chung một key — không phải mức bảo mật.

Đổi lại, CMK kéo theo chuỗi quyền `kms:CreateKey` → `TagResource` → `EnableKeyRotation` → `Encrypt`, và **xoá lại cần `kms:ScheduleKeyDeletion`** vốn không nằm trong nhóm đó. Lần dựng ngày 12/09/2026 để lại hai key mồ côi 1 USD/tháng không tự dọn được. Không đáng cho môi trường thực hành.

Đánh đổi trong IAM policy: không có ARN cố định để trỏ vào, nên `kms:Decrypt` cấp trên `*` kèm điều kiện `kms:ViaService` giới hạn đúng bốn dịch vụ `ssm`, `sqs`, `dynamodb`, `s3`.

**Không có access key ở bất kỳ file nào.** Provider lấy credential từ profile `abc-migration` của AWS CLI; kiểm tra bằng `aws --profile abc-migration sts get-caller-identity` phải ra `assumed-role`, không phải `user`.

Cắt được nếu thiếu thời gian: WAF, GuardDuty, Security Hub. Nêu trong báo cáo là "ngoài phạm vi, khuyến nghị giai đoạn sau".

---

## 11. Chi phí

Số liệu đầy đủ: [`chi-phi.md`](chi-phi.md) · Theo ngày/tuần: [`chi-phi-ngay-tuan.md`](chi-phi-ngay-tuan.md)

| Bản | Cấu hình | USD/tháng |
|---|---|---|
| **Quy mô production (SA)** | `db.t4g.large` Multi-AZ 200 GB, EFS 500 GB, DMS liên tục, WAF, 2 NAT | **1.100,51** |
| **Quy mô thực hành** | `db.t4g.micro` Multi-AZ 20 GB, EFS nhỏ, DMS chạy 6 giờ, 1 NAT, SPA thay Web tier | **207,82** |
| Chỉ chạy giờ làm việc | 8 giờ × 5 ngày, dùng `scripts/aws-env.sh` | **~72** |

Tài khoản có trần **350 USD/tháng cho toàn bộ resource**, dùng chung với người khác — nên bản production của SA gấp 3,1 lần trần, không dựng được nguyên trạng.

**Đã đưa về 208 USD mà không bỏ ràng buộc nào**: thu nhỏ dữ liệu thực hành theo đúng cho phép của yêu cầu, giữ nguyên Multi-AZ, giữ RDS Proxy, giữ DMS và DataSync.

### Khi ngân sách bị cắt 20% (ràng buộc #9)

Từ 209 xuống 167, thứ tự đòn bẩy:

| Hành động | Tiết kiệm | Ảnh hưởng cam kết kỹ thuật |
|---|---|---|
| Chỉ chạy trong giờ làm việc | ~137 | Không ảnh hưởng gì với môi trường thực hành. **Đòn bẩy mạnh nhất** |
| Bỏ warm pool | ~1 | Scale out chậm lại 2–3 phút → rủi ro chạm ngưỡng 2 phút của #4 |
| `t4g.small` → `t4g.micro` | ~12 | Phải chạy lại B1 để chứng minh vẫn đạt p95 |
| Savings Plan 1 năm cho EC2 | ~28 | Không ảnh hưởng, nhưng cam kết 1 năm |
| **RDS Multi-AZ → Single-AZ** | ~40 | RTO tăng từ ~2 phút lên ~30 phút. **Vi phạm #5 — không khuyến nghị** |

**Khi ngân sách bị cắt 20%:** đòn bẩy đầu tiên là lịch chạy, không phải cấu hình — môi trường thực hành không cần chạy 24/7, và hạ xuống 8 giờ/ngày làm việc đã vượt xa mức cắt 20% mà không đụng tới bất kỳ ràng buộc nào. **Tuyệt đối không đề xuất bỏ Multi-AZ** — nó phá trực tiếp ràng buộc #5.

---

## 12. Ma trận test case — deliverable chính của CE

Mỗi test phải có: bước thực hiện → kết quả đo được → bằng chứng.

### Nhóm A — Chức năng

| ID | Kịch bản | Tiêu chí đạt | Trạng thái | Ràng buộc |
|---|---|---|---|---|
| A1 | Cutover có giao dịch đang chạy | Downtime ≤ 15 phút, 0 mất, 0 trùng | **đạt 7/7** — downtime 1,1s, 3.587 đơn khớp, tổng tiền khớp | #2 |
| A2 | Gửi lại cùng `Idempotency-Key` 5 lần | Chỉ 1 đơn được tạo | **đạt 3/3** | #3 |
| A3 | 2 user cùng sửa 1 đơn | User thứ 2 nhận HTTP 409, không ghi đè | **đạt 7/7** — 10 request đồng thời: 1×200, 9×409 | #3 |
| A4 | Truy vết 1 giao dịch | Thấy đủ hành trình qua các tier | cần chạy trên AWS thật | #8 |
| A5 | Phân quyền file server theo phòng ban | Phòng A không đọc được thư mục phòng B | **đạt 30/30** | #7 |
| A6 | Thu hồi quyền user | Mất quyền trong ≤ 5 phút — bấm giờ thật | cần chạy trên EFS thật | #7 |
| A7 | Ngắt hoàn toàn môi trường nguồn | Hệ thống vẫn chạy đủ chức năng | cần chạy trên AWS thật | #1 |

### Nhóm B — Chịu tải & khắc phục sự cố

| ID | Kịch bản | Tiêu chí đạt | Trạng thái | Ràng buộc |
|---|---|---|---|---|
| B1 | Load 5x (250 req/s) trong 30 phút | p95 ≤ 2s, lỗi ≤ 1% | cần EC2 riêng làm load generator | #4 |
| B2 | `terminate` 1 instance App khi đang tải | Gián đoạn ≤ 2 phút | cần chạy trên AWS thật | #4 |
| B4 | Chặn kết nối DB 3 phút | Không đơn nào báo `CONFIRMED` sai; tự hồi phục **không restart tay** | **đạt 5/5** — hồi phục 13s, app không restart | #5 |
| B5 | `reboot --force-failover` RDS | App tự nối lại qua Proxy | cần chạy trên RDS thật | #5 |
| B6 | Xoá nhầm đơn → PITR restore | RPO ≤ 5 phút, RTO ≤ 30 phút | cần chạy trên RDS thật | #6 |
| B8 | Job báo cáo + tải bình thường song song | OLTP p95 ≤ 2s; báo cáo không thiếu/trùng | **đạt 6/6** — p95 61ms | #10 |

Sáu bài chạy được ở môi trường local đạt **58/58 kiểm chứng, 0 không đạt** (`evidence/test-report-20260910T173621Z.txt`).

Ngày 12/09/2026 đã chạy thêm **bảy bài trên AWS thật** — A2, A3, A6, B2, B4, B5, B6 — log ở `evidence/aws-*.log`. Kết quả và các điểm không đạt ghi ở README của repo.

Còn thiếu: B1 (tải gấp 5, cần EC2 riêng làm máy phát tải) và phép so sánh có/không RDS Proxy.

### Công cụ load test

| Công cụ | Ghi chú |
|---|---|
| **k6** | Script ở `loadtest/k6/`. Chạy trên 1 EC2 `c6i.large` |

Chạy load generator **ngoài VPC** (hoặc ít nhất subnet riêng) để không tự làm nhiễu kết quả. Đừng chạy từ laptop qua internet — độ trễ đường truyền làm hỏng số đo p95.

---

## 13. Ưu tiên khi thiếu thời gian

**Không được cắt:** Terraform, RDS Multi-AZ + Proxy, test A1/A2/A3/B4/B8, bằng chứng có timestamp.

**Cắt được, ghi rõ lý do trong báo cáo:** X-Ray (→ correlation-ID), Synthetics canary (→ vòng lặp curl), WAF/GuardDuty, CI/CD đầy đủ (→ concept), read replica (SCP đã chặn sẵn, phải giải thích ràng buộc #10 xử lý thế nào).

> Yêu cầu viết rõ: *"Việc chọn phạm vi hợp lý và giải thích được lý do chọn cũng là một phần được đánh giá."* Cắt có lý do > làm đủ mà hời hợt.

---

## 14. Tài liệu bàn giao

| # | Tài liệu | Ở đâu |
|---|---|---|
| 1 | Giả định | [`gia-dinh.md`](gia-dinh.md) |
| 2 | Runbook vận hành | [`runbook.md`](runbook.md) |
| 4 | Chi phí | [`chi-phi.md`](chi-phi.md), [`chi-phi-ngay-tuan.md`](chi-phi-ngay-tuan.md) |
| 5 | Quy trình release | [`quy-trinh-release.md`](quy-trinh-release.md) |
| 6 | Terraform + README từng module | [`deploy/terraform/`](../../deploy/terraform/) |
| 7 | Các bước Console tương ứng | [`huong-dan-console.md`](huong-dan-console.md) |
| 8 | Kết quả test | `evidence/`, `scripts/test-*.sh` |
| 9 | Architecture diagram | bản CE (chi tiết subnet, SG, port), khác bản SA (mức khái niệm) |

---

*Chuẩn bị cho: Yêu cầu Đánh giá Cuối kỳ Thực hành — *
