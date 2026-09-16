# `observability`

Cảnh báo, truy vết và dashboard. Module này biến các con số trong yêu cầu thành alarm cụ thể.

## Kiến trúc

```
   ALB ─┐
   RDS ─┼──▶ CloudWatch Metrics ──▶ 8 alarm ──┐
   SQS ─┘                                     │
                                              ├──▶ SNS topic ──▶ email
   App logs (JSON) ──▶ metric filter ──▶ alarm ┘
        │
        └──▶ 4 truy vấn Logs Insights lưu sẵn
        └──▶ CloudWatch dashboard
```

## Tám alarm và ràng buộc chúng phục vụ

| Alarm | Metric | Ngưỡng | Ràng buộc |
|---|---|---|---|
| `response_time` | `TargetResponseTime` p95 | > 2 giây, 2 chu kỳ 60s | #4 |
| `error_rate` | 5XX ÷ RequestCount | > 1%, 2 chu kỳ | #4 |
| `unhealthy_hosts` | `UnHealthyHostCount` | > 0, 1 chu kỳ | #4 |
| `db_connections` | `DatabaseConnections` | > 80% trần instance, 3 chu kỳ | #5 |
| `db_cpu` | `CPUUtilization` | > 80%, 5 chu kỳ | #10 |
| `db_storage` | `FreeStorageSpace` | < 2 GB | #6 |
| `queue_backlog` | `ApproximateAgeOfOldestMessage` | > ngưỡng, 2 chu kỳ | #3 |
| `dlq_not_empty` | DLQ có message | > 0, 1 chu kỳ | #3 |

Hai ngưỡng đầu lấy thẳng từ yêu cầu: p95 ≤ 2s và tỉ lệ lỗi ≤ 1%.

## `extended_statistic = "p95"` chứ không phải `Average`

p95 nghĩa là 95% request nhanh hơn con số đó. Trung bình che mất phần đuôi: 100 request trong đó 95 cái 100 ms và 5 cái 10 giây cho trung bình 595 ms — nghe ổn, trong khi 5% người dùng đang chờ 10 giây.

CloudWatch tính percentile phải khai bằng `extended_statistic`, không phải `statistic`.

## `treat_missing_data` — vì sao mỗi alarm một kiểu

- ALB và SQS dùng `notBreaching`: không có request nào thì không có metric, và im lặng ở đây là bình thường. Đặt `breaching` sẽ báo động mỗi đêm.
- RDS dùng `missing`: RDS luôn phát metric khi còn sống. Metric biến mất nghĩa là instance có vấn đề, nên giữ trạng thái alarm trước đó thay vì tự coi là OK.

## `error_rate` dùng metric math

Không có metric "tỉ lệ lỗi" sẵn. Alarm này ghép hai metric bằng expression:

```
(HTTPCode_Target_5XX_Count / RequestCount) * 100
```

`RequestCount` = 0 sẽ chia cho 0, nên biểu thức dùng dạng an toàn và `treat_missing_data = "notBreaching"` đỡ nốt.

## Metric filter phải là JSON pattern

Ứng dụng ghi log dạng JSON. Filter dùng:

```
{ ($.level = "ERROR") || ($.level = "CRITICAL") }
```

Trước đó từng dùng text pattern `"?ERROR ?CRITICAL"`. Nó vẫn khớp dòng log, nhưng khi metric có `dimensions = { tier = "$.tier" }` thì text pattern không trích được giá trị field — metric ra rỗng, alarm không bao giờ bắn. Text pattern và dimension theo field JSON không đi cùng nhau được.

## Bốn truy vấn Logs Insights lưu sẵn

Đây là phần cho ràng buộc #8 (truy vết một giao dịch từ đầu đến cuối):

| Tên | Dùng khi |
|---|---|
| `truy-vet-mot-giao-dich` | Có `correlation_id`, muốn xem toàn bộ chặng: web → app → worker → DB |
| `truy-vet-theo-ma-don` | Chỉ có mã đơn khách hàng đọc qua điện thoại |
| `loi-gan-day` | Vừa nhận alarm, muốn biết lỗi gì |
| `request-cham` | p95 vượt ngưỡng, muốn biết endpoint nào chậm |

Lưu sẵn để lúc sự cố không phải gõ lại cú pháp Logs Insights.

## `alert_email` và bẫy xác nhận

SNS email subscription tạo xong ở trạng thái **PendingConfirmation**. Phải có người bấm link trong email thì alarm mới tới nơi. Output `email_subscription_pending` nhắc điều này.

Chưa xác nhận thì alarm vẫn bắn, vẫn đổi trạng thái, chỉ là không ai biết.

## `dimensions` và `default_value` loại trừ nhau

`metric_transformation` không cho đặt cùng lúc hai thuộc tính này:

```
InvalidParameterException: Invalid metric transformation:
dimensions and default value are mutually exclusive properties
```

Ở đây chọn `dimensions` để tách metric theo tier, nên bỏ `default_value`.

Đánh đổi: khoảng thời gian không có dòng log nào khớp thì metric **không có điểm
dữ liệu**, thay vì có điểm giá trị 0. Vì vậy alarm dựa trên metric này phải đặt
`treat_missing_data = "notBreaching"`, nếu không nó sẽ báo động mỗi đêm khi hệ
thống rảnh.

Lỗi này `terraform validate` và `plan` đều không bắt được, chỉ lộ lúc apply.

## Tài nguyên tạo ra

- `aws_cloudwatch_dashboard.main`
- `aws_cloudwatch_log_metric_filter.errors`
- `aws_cloudwatch_metric_alarm.db_connections`
- `aws_cloudwatch_metric_alarm.db_cpu`
- `aws_cloudwatch_metric_alarm.db_storage`
- `aws_cloudwatch_metric_alarm.dlq_not_empty`
- `aws_cloudwatch_metric_alarm.error_rate`
- `aws_cloudwatch_metric_alarm.queue_backlog`
- `aws_cloudwatch_metric_alarm.response_time`
- `aws_cloudwatch_metric_alarm.unhealthy_hosts`
- `aws_cloudwatch_query_definition.errors_last_hour`
- `aws_cloudwatch_query_definition.slow_requests`
- `aws_cloudwatch_query_definition.trace_by_correlation_id`
- `aws_cloudwatch_query_definition.trace_by_order_id`
- `aws_sns_topic.alerts`
- `aws_sns_topic_subscription.email`

## Biến

| Tên | Mô tả | Mặc định |
|---|---|---|
| `alarm_email` | Address alarms are sent to. | `""` |
| `db_instance_identifier` | Database instance the alarms watch. | **bắt buộc** |
| `db_max_connections` | Connection ceiling of the instance class. | `85` |
| `dlq_name` | Name of the dead letter queue. | **bắt buộc** |
| `error_rate_threshold_percent` | Ceiling for the share of requests answered with a server error. The brief sets one percent. | `1` |
| `log_group_name` | CloudWatch log group the application writes to. | **bắt buộc** |
| `name_prefix` | Prefix applied to every resource name in this module. | **bắt buộc** |
| `public_alb_arn_suffix` | Suffix CloudWatch uses to identify the internet facing load balancer. | **bắt buộc** |
| `queue_age_threshold_seconds` | How old the oldest unprocessed message may get before the alarm fires. | `300` |
| `queue_name` | Name of the order queue. | **bắt buộc** |
| `response_time_threshold_seconds` | Ceiling for the ninety fifth percentile of response time. The brief sets two seconds. | `2` |
| `target_group_arn_suffix` | Suffix CloudWatch uses to identify the application target group. | **bắt buộc** |

## Đầu ra

| Tên | Mô tả |
|---|---|
| `alarm_names` | Every alarm this module creates. |
| `dashboard_name` | Dashboard showing the numbers the brief sets thresholds on. |
| `subscription_pending` | True when an email subscription was created. It stays pending until someone clicks the confirmation link, and alarms reach nobody before that. |
| `topic_arn` | Topic every alarm publishes to. |
