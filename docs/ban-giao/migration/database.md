# Migration database PostgreSQL

On-premise → RDS PostgreSQL, **không được mất đơn, không được trùng đơn**, ngừng
dịch vụ tối đa 15 phút.

Viết cho người chưa từng làm migration bao giờ.

---

## 1. Vì sao không chỉ `pg_dump` rồi `pg_restore`

Cách đơn giản nhất là: khoá hệ thống, dump ra file, restore vào RDS, mở lại.

Vấn đề: **thời gian khoá bằng thời gian dump cộng restore**. Với 200 GB thì mất
vài giờ. Khách hàng không chấp nhận ngừng bán hàng vài giờ.

Và trong lúc dump, hệ thống cũ **vẫn nhận đơn** — những đơn đó nằm ngoài file
dump, chuyển xong là mất.

## 2. Ba chiến lược, chọn cái nào

| | Big-bang | **Full load + CDC** | Dual-write |
|---|---|---|---|
| Cách làm | Khoá, dump, restore, mở | Chép nền trước, bám thay đổi, cutover ở phút cuối | Ghi đồng thời hai nơi |
| Downtime | vài giờ | **vài giây tới vài phút** | gần 0 |
| Phải sửa ứng dụng | không | **không** | **có** |
| Rủi ro | mất đơn phát sinh trong lúc dump | thấp | cao, lệch dữ liệu khó phát hiện |

**Chọn full load + CDC.** Dual-write nghe hay nhưng phải sửa ứng dụng để ghi hai
nơi, và khi hai nơi lệch nhau thì rất khó biết bên nào đúng.

### CDC là gì

**Change Data Capture** — bám theo thay đổi. PostgreSQL ghi mọi thay đổi vào
**WAL** (Write-Ahead Log) trước khi ghi vào bảng. Công cụ migration đọc WAL đó và
áp dụng lại lên đích.

Nhờ vậy nguồn **vẫn chạy bình thường** trong lúc chép, và đích bám theo chỉ chậm
vài giây.

---

## 3. Chuẩn bị phía nguồn — làm trước, không làm là hỏng

### 3.1 Bật logical replication

Sửa `postgresql.conf`:

```conf
wal_level = logical              # mặc định là replica, không đủ để CDC
max_replication_slots = 5        # mỗi luồng chép chiếm 1 slot
max_wal_senders = 5              # số tiến trình gửi WAL đồng thời
```

**Phải restart PostgreSQL.** Đây là tham số static, không đổi nóng được.

Kiểm tra:

```sql
SHOW wal_level;                  -- phải ra 'logical'
```

### 3.2 Tạo user cho migration

```sql
CREATE USER dms_user WITH REPLICATION LOGIN PASSWORD '<mat-khau-manh>';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO dms_user;
GRANT USAGE ON SCHEMA public TO dms_user;
```

Quyền `REPLICATION` là bắt buộc để đọc WAL.

### 3.3 Mọi bảng phải có khoá chính

CDC nhận diện dòng cần cập nhật qua khoá chính. Bảng không có khoá chính thì
`UPDATE` và `DELETE` **không đồng bộ được** — chỉ `INSERT` chạy.

Kiểm tra bảng nào thiếu:

```sql
SELECT c.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind = 'r' AND n.nspname = 'public'
   AND NOT EXISTS (
     SELECT 1 FROM pg_constraint
      WHERE conrelid = c.oid AND contype = 'p');
```

Ra bảng nào thì phải thêm khoá chính **trước khi** bắt đầu.

### 3.4 Mạng

DMS nằm trong VPC, phải tới được PostgreSQL on-premise. Ba cách:

| Cách | Khi nào |
|---|---|
| Site-to-Site VPN | Chính thức, có mã hoá |
| Direct Connect | Khi cần băng thông lớn và ổn định |
| Public IP + security group giới hạn | Chỉ cho môi trường thực hành |

### 3.5 Tạo schema ở đích TRƯỚC

```bash
psql "postgresql://abcapp:<pw>@<rds-endpoint>:5432/abcsales?sslmode=require" \
  -f db/01-schema.sql
```

**Đừng để DMS tự tạo bảng.** Nó suy ra kiểu dữ liệu từ dữ liệu nguồn và hay ra
kiểu rộng hơn cần thiết, mất luôn constraint và index. Vì vậy task đặt
`TargetTablePrepMode = DO_NOTHING`.

---

## 4. Dựng DMS

### 4.1 Hai role bắt buộc, tên cố định

AWS đòi đúng hai tên này, không đổi được:

| Role | Policy |
|---|---|
| `dms-vpc-role` | `AmazonDMSVPCManagementRole` |
| `dms-cloudwatch-logs-role` | `AmazonDMSCloudWatchLogsRole` |

Thiếu thì báo lỗi đánh lừa:

```
AccessDeniedFault: The IAM Role arn:aws:iam::<account>:role/dms-vpc-role
is not configured properly.
```

Đọc như thiếu quyền, thực ra là thiếu role. Tạo xong **chờ 1–2 phút** cho IAM lan
truyền rồi mới tạo replication instance.

Terraform: `create_dms_service_roles = true`.

### 4.2 Replication instance

| Tham số | Giá trị | Vì sao |
|---|---|---|
| Class | `dms.t3.micro` | Đủ cho dữ liệu thực hành. Production 200 GB thì `dms.t3.medium` |
| Storage | 50 GB | Tối thiểu. Chứa WAL đệm khi đích chậm hơn nguồn |
| Multi-AZ | tắt | Chỉ chạy vài giờ, hỏng thì tạo lại |
| Public | không | Nằm trong subnet data |

Tạo mất khoảng 10 phút.

### 4.3 Hai endpoint

Source trỏ PostgreSQL on-premise, target trỏ RDS. Tạo xong **bấm Run test cho cả
hai, phải xanh**. Không xanh thì đừng đi tiếp — hầu hết lỗi ở đây là mạng hoặc
quyền user.

### 4.4 Task — ba tham số quyết định thành bại

| Tham số | Giá trị | Không đặt thì sao |
|---|---|---|
| Migration type | **Full load + CDC** | Chỉ full load thì mất đơn phát sinh sau |
| `TargetTablePrepMode` | **`DO_NOTHING`** | DMS tự tạo bảng, sai kiểu dữ liệu |
| `ApplyErrorPolicy` | **`STOP_TASK`** | Mặc định bỏ qua dòng lỗi và đi tiếp — **mất dữ liệu âm thầm** |
| Validation | **bật, `ROW_LEVEL`** | Không có bằng chứng đối chiếu |

`ApplyErrorPolicy` là chỗ nguy hiểm nhất. Mặc định của DMS là `LOG_ERROR` — ghi
log rồi đi tiếp. Chạy xong thấy "thành công" mà thiếu vài trăm dòng.

**Tạo task ở trạng thái dừng.** Start là bắt đầu ghi vào database đích.

---

## 5. Chạy và theo dõi

```bash
aws dms start-replication-task \
  --replication-task-arn <arn> \
  --start-replication-task-type start-replication
```

### Hai giai đoạn

```
Full load    chép toàn bộ dữ liệu hiện có
             nguồn VẪN chạy bình thường, mất bao lâu cũng được
                    ↓
CDC          bám thay đổi liên tục từ WAL
             độ trễ vài giây
```

### Ba số phải nhìn

| Metric | Ý nghĩa | Ngưỡng |
|---|---|---|
| `FullLoadThroughputRowsTarget` | Tốc độ chép nền | Càng cao càng tốt |
| **`CDCLatencySource`** | Nguồn sinh thay đổi nhanh hơn DMS đọc bao nhiêu giây | Phải về gần 0 trước cutover |
| **`CDCLatencyTarget`** | DMS ghi vào đích chậm bao nhiêu giây | Phải về gần 0 trước cutover |

**Hai số CDC latency là điều kiện để bấm cutover.** Còn cao nghĩa là đích đang
tụt lại, cắt lúc đó là mất đơn.

### Table statistics

Tab **Table statistics** trong DMS console cho biết từng bảng chép được bao nhiêu
dòng, và validation khớp hay lệch. Đây là bằng chứng để chụp màn hình.

---

## 6. Cutover — kịch bản theo phút

Điều kiện trước khi bắt đầu, thiếu một cái là **hoãn**:

- [ ] Full load đã xong, mọi bảng ở trạng thái "Table completed"
- [ ] `CDCLatencySource` và `CDCLatencyTarget` đều **< 5 giây**
- [ ] Validation không có dòng lệch
- [ ] Đã thử rollback ít nhất một lần ở môi trường test
- [ ] Có người trực cả hai phía

```
T+0    Bật maintenance page trên ALB
       (listener rule fixed-response 503, ưu tiên cao nhất)
       → ngừng nhận đơn mới

T+1    Đợi request đang chạy dở hoàn tất
       kiểm: ALB ActiveConnectionCount về 0

T+2    Chờ CDC latency về 0
       aws dms describe-replication-tasks --query '...CDCLatencyTarget'

T+5    Dừng DMS task
       aws dms stop-replication-task --replication-task-arn <arn>

T+6    ĐẶT LẠI SEQUENCE  ← xem mục 7, bước dễ quên nhất

T+8    Đối chiếu số liệu
       số đơn hai đầu, tổng tiền hai đầu, đếm mã trùng

T+10   Đổi connection string sang RDS Proxy
       aws ssm put-parameter --name /abc-migration-dev/db/host \
         --value <proxy-endpoint> --overwrite
       rồi thay instance để đọc lại cấu hình

T+12   Smoke test: tạo một đơn thật, đọc lại, sửa nó

T+14   Gỡ maintenance page

T+15   Theo dõi 30 phút: error rate, p95, DLQ
```

Ngân sách 15 phút. Đo thực tế với dữ liệu thực hành: **1,1 giây**.

Vì sao nhanh vậy: **full load đã chạy xong từ trước**, lúc cutover chỉ còn khoá
ghi và đổi endpoint. Với 200 GB thì full load lâu hơn nhiều nhưng **thời gian
ngừng không đổi**, vì full load chạy lúc hệ thống còn đang phục vụ.

---

## 7. Cái bẫy lớn nhất: sequence

**DMS chép dữ liệu, KHÔNG chép giá trị hiện tại của sequence.**

Sequence là bộ đếm sinh khoá chính tự tăng. Ở nguồn, `orders_id_seq` đang ở
15.000. Sau khi chép, đích có 15.000 dòng nhưng sequence vẫn ở **1**.

Đơn đầu tiên sau cutover xin id = 1, mà id 1 đã tồn tại:

```
ERROR: duplicate key value violates unique constraint "orders_pkey"
```

Hệ thống chết ngay sau khi cutover, đúng lúc không ai muốn.

### Cách xử lý đúng: quét toàn bộ, không liệt kê tay

```sql
DO $$
DECLARE r RECORD; m BIGINT;
BEGIN
  FOR r IN
    SELECT c.oid::regclass AS tbl,
           a.attname       AS col,
           pg_get_serial_sequence(c.oid::regclass::text, a.attname) AS seq
      FROM pg_class c
      JOIN pg_attribute a ON a.attrelid = c.oid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND pg_get_serial_sequence(c.oid::regclass::text, a.attname) IS NOT NULL
  LOOP
    EXECUTE format('SELECT COALESCE(MAX(%I),0) FROM %s', r.col, r.tbl) INTO m;
    PERFORM setval(r.seq, m + 1, false);
  END LOOP;
END $$;
```

**Vì sao phải quét tự động:** trong dự án này đã từng liệt kê tay và sót ba bảng
`order_items`, `order_events`, `report_runs`. Ba bài test sau đó fail, mất thời
gian mới tìm ra nguyên nhân.

Chạy xong kiểm lại:

```sql
SELECT sequencename, last_value FROM pg_sequences WHERE schemaname='public';
```

---

## 8. Đối chiếu — bằng chứng không mất, không trùng

Chạy **cùng lúc** ở cả hai đầu rồi so:

```sql
-- số đơn đã xác nhận
SELECT count(*) FROM orders WHERE status='CONFIRMED';

-- tổng tiền, bắt được cả trường hợp đủ số dòng nhưng sai giá trị
SELECT sum(total_amount) FROM orders WHERE status='CONFIRMED';

-- mã đơn trùng, phải bằng 0
SELECT count(*) FROM (
  SELECT order_no FROM orders GROUP BY order_no HAVING count(*)>1) t;

-- idempotency key trùng, phải bằng 0
SELECT count(*) FROM (
  SELECT idempotency_key FROM orders
   GROUP BY idempotency_key HAVING count(*)>1) t;
```

Kết quả đo được trong dự án:

| Chỉ số | Nguồn | Đích |
|---|---|---|
| Đơn CONFIRMED | 3.587 | **3.587** |
| Tổng tiền | 322.187.632.386,00 | **khớp tuyệt đối** |
| `order_no` trùng | 0 | **0** |
| `idempotency_key` trùng | 0 | **0** |

**Tổng tiền quan trọng hơn số dòng.** Đủ dòng mà sai vài giá trị thì đếm dòng
không phát hiện được.

---

## 9. Rollback — hỏng ở phút thứ 10 thì sao

Điểm không quay lại được là **T+10**, lúc đổi connection string. Trước đó quay
lại dễ, sau đó thì khó.

### Hỏng trước T+10

```
1. Gỡ maintenance page
2. Hệ thống cũ chạy lại như chưa có gì
3. Điều tra, sửa, hẹn cutover lần sau
```

Không mất gì, vì chưa đơn nào ghi vào đích.

### Hỏng sau T+10

Lúc này đơn mới đã vào RDS, nguồn cũ thiếu những đơn đó.

```
1. Đổi connection string về lại nguồn cũ
2. Trích các đơn đã ghi vào RDS sau mốc T
     SELECT * FROM orders WHERE created_at >= '<T>';
3. Chèn ngược vào nguồn cũ, ON CONFLICT DO NOTHING
4. Đối chiếu lại
```

**Vì vậy phải ghi lại chính xác mốc T.** Không có nó thì không biết trích từ đâu.

### Giảm rủi ro

Giữ DMS task **theo chiều ngược** (RDS → on-premise) chạy song song vài giờ sau
cutover. Nếu phải quay lại thì nguồn cũ đã có sẵn dữ liệu mới.

---

## 10. Phương án hai: PostgreSQL logical replication

Khi không có quyền DMS, hoặc muốn không tốn tiền.

| | DMS | Logical replication |
|---|---|---|
| Chi phí | ~0,22 USD cho 6 giờ | **0** |
| Báo cáo đối chiếu | **có sẵn** | tự viết SQL |
| Giao diện theo dõi | Console | truy vấn `pg_stat_replication` |
| Cài thêm gì | không | không |

### Cách làm

Ở **nguồn**:

```sql
CREATE PUBLICATION abc_pub FOR ALL TABLES;
```

Ở **đích** (RDS cần `rds.logical_replication = 1` trong parameter group):

```sql
CREATE SUBSCRIPTION abc_sub
  CONNECTION 'host=<nguon> port=5432 dbname=abcsales user=dms_user password=<pw>'
  PUBLICATION abc_pub;
```

Theo dõi độ trễ ở nguồn:

```sql
SELECT application_name,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS bytes_behind
  FROM pg_stat_replication;
```

`bytes_behind` về gần 0 là đích đã bắt kịp.

Cutover xong, ở đích:

```sql
DROP SUBSCRIPTION abc_sub;
```

Rồi **vẫn phải đặt lại sequence** như mục 7 — logical replication cũng không chép
sequence.

### Đây là cách bài test A1 thực tế dùng

`scripts/test-a1-migration-cutover.sh` chạy bằng logical replication vì lúc đó
chưa có quyền DMS. Kết quả: **downtime 1,1 giây**, 3.587 đơn khớp, 0 trùng.

**Chốt phương án:** dùng **DMS** cho lần chuyển chính thức vì có Data Validation
Report làm bằng chứng bàn giao. Logical replication là đường lui khi DMS không
dựng được, và là cách đã đo được số thật.

---

## 11. Sau khi cutover xong

| Việc | Khi nào |
|---|---|
| Theo dõi error rate, p95, DLQ | 30 phút đầu |
| Giữ nguồn cũ ở chế độ chỉ đọc | ít nhất 1 tuần |
| Xoá DMS replication instance | sau khi chắc chắn không rollback |
| Chụp Table statistics + validation report | trước khi xoá task |

**Xoá replication instance sớm** vì nó tính tiền theo giờ liên tục, mà cutover
xong là hết việc.
