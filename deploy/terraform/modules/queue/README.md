# `queue`

Hàng đợi FIFO nhận đơn, dead letter queue cho đơn xử lý hỏng, và S3 làm sổ ghi nhận trước khi đơn vào database.

## Kiến trúc

```
   App tier
      │ 1. ghi bản nhận  ──▶  DynamoDB <prefix>-accept  (TTL 24h)
      │ 2. đẩy message   ──▶  SQS FIFO  <prefix>-orders.fifo
      │                          │  MessageGroupId = mã khách hàng
      │ 3. trả 202 cho client    │  MessageDeduplicationId = Idempotency-Key
                                 ▼
                              Worker  ──▶ RDS
                                 │
                    quá 5 lần nhận không xong
                                 ▼
                       <prefix>-orders-dlq.fifo   (giữ 14 ngày)
```

## Vì sao FIFO chứ không phải Standard

Ràng buộc #3 nói không được tạo đơn trùng và không được âm thầm ghi đè. Standard queue có thể giao một message nhiều lần và không giữ thứ tự.

FIFO cho hai thứ:
- **Khử trùng lặp trong 5 phút** theo `MessageDeduplicationId`. Client bấm gửi hai lần, cùng một `Idempotency-Key`, message thứ hai bị SQS bỏ ngay — chưa cần chạm tới worker.
- **Thứ tự trong cùng một `MessageGroupId`**. Hai lần sửa cùng một đơn được xử lý đúng thứ tự gửi, nên bản sửa cũ không đè bản mới.

## `deduplication_scope` và `fifo_throughput_limit`

Mặc định FIFO giới hạn 300 message/giây trên toàn queue. Đặt:

```
deduplication_scope   = "messageGroup"
fifo_throughput_limit = "perMessageGroupId"
```

thì giới hạn tính theo từng message group, lên tới 3.000 message/giây. Vì `MessageGroupId` là mã khách hàng, các khách khác nhau không chờ nhau. Đây là phần đáp ứng ràng buộc #4 (tải tăng 5 lần).

Hai tuỳ chọn này phải bật cùng nhau, bật một cái AWS sẽ từ chối.

## Vì sao vẫn cần accept store khi đã có SQS

SQS không đọc lại được message đã xử lý xong. Khi cần truy vết một giao dịch (ràng buộc #8), bản ghi nhận trong DynamoDB là bằng chứng "hệ thống đã nhận đơn này lúc mấy giờ, nội dung gốc ra sao", độc lập với việc worker đã ghi vào database hay chưa.

Quan trọng hơn, nó nằm **ngoài RDS**. Lúc database mất kết nối (ràng buộc #5), `GET /orders/{id}` vẫn trả `PENDING` thay vì 404 hay 500 — client biết đơn chưa thành công chứ không nhận thông báo thành công giả.

## Vì sao DynamoDB chứ không phải S3 hay một bảng trong RDS

| | RDS | S3 | DynamoDB |
|---|---|---|---|
| Còn đọc được khi RDS chết | không | có | có |
| Chặn trùng bằng ghi có điều kiện | có | không | có |
| Tra theo `order_id` | có | không | có, qua GSI |

Bảng dùng `PutItem` với `ConditionExpression = attribute_not_exists(idempotency_key)`. Client bấm gửi lại 5 lần cùng một `Idempotency-Key` thì lần 2–5 bị chặn ngay tại App tier, chưa kịp sinh message vào hàng đợi. Đây là tuyến chống trùng thứ nhất; ràng buộc `UNIQUE` trên `orders.idempotency_key` là tuyến thứ hai.

`get_by_order_id` truy vấn qua GSI **`order_id-index`** — tên này do ứng dụng gọi cứng trong `app/common/store.py`, đổi tên index là hỏng.

TTL nằm ở thuộc tính `expires_at`, ứng dụng ghi mốc 24 giờ. Bản ghi tự hết hạn, không cần job dọn dẹp.

Billing để `PAY_PER_REQUEST`: không có traffic thì không mất tiền, không phải đoán capacity.

## Dead letter queue và `max_receive_count = 5`

Message hỏng (payload sai, worker crash giữa chừng) sẽ được nhận đi nhận lại vô hạn nếu không có DLQ, khoá luôn message group đó. Sau 5 lần nhận không xoá, SQS đẩy nó sang DLQ và queue chính đi tiếp.

DLQ giữ **14 ngày** (`message_retention_seconds = 1209600`, mức tối đa) để có đủ thời gian điều tra rồi redrive lại. `aws_sqs_queue_redrive_allow_policy` cho phép đẩy ngược từ DLQ về queue chính sau khi sửa.

Alarm `dlq_not_empty` trong module `observability` bắn ngay khi DLQ có message — DLQ có message nghĩa là có đơn chưa vào được database.

## `visibility_timeout_seconds`

Phải lớn hơn thời gian worker xử lý một message. Ngắn quá thì SQS tưởng worker chết và giao message cho worker thứ hai, hai worker cùng ghi một đơn.

## Tài nguyên tạo ra

- `aws_dynamodb_table.accept`
- `aws_sqs_queue.dlq`
- `aws_sqs_queue.orders`
- `aws_sqs_queue_redrive_allow_policy.dlq`

## Biến

| Tên | Mô tả | Mặc định |
|---|---|---|
| `allow_destroy` | Turn off deletion protection on the accept store table so the environment can be torn down. | `false` |
| `max_receive_count` | Deliveries a message gets before it is moved to the dead letter queue. | `5` |
| `message_retention_seconds` | How long an unprocessed message survives. | `1209600` |
| `name_prefix` | Prefix applied to every resource name in this module. | **bắt buộc** |
| `visibility_timeout_seconds` | How long a message stays invisible after a worker picks it up. | `180` |

## Đầu ra

| Tên | Mô tả |
|---|---|
| `accept_table_arn` | ARN of the accept store table. |
| `accept_table_name` | DynamoDB table holding accepted order records. |
| `dlq_arn` | ARN of the dead letter queue. |
| `dlq_name` | Name of the dead letter queue. |
| `dlq_url` | URL of the dead letter queue. |
| `queue_arn` | ARN of the order queue. |
| `queue_name` | Name of the order queue. |
| `queue_url` | URL of the order queue. |
