# `compute`

Tầng ứng dụng: một ALB public, Auto Scaling group chạy launch template, cộng hai bucket cho artifact và access log.

## Kiến trúc

```
   CloudFront  ──/api/*──▶  ALB public (subnet public, 2 AZ)
                                 │  :80  → target group "app"
                                 │  health check GET /ready
                                 ▼
              ┌──────────────────────────────────┐
              │  Auto Scaling group "app"        │  subnet private
              │  min 2 / desired 2 / max 6       │
              │  t4g.small (Graviton)            │
              │  warm pool: 2 máy Stopped        │
              └──────────────────────────────────┘
                       │            │
                    SQS/RDS      S3 artifacts (tải lúc boot)
                                 CloudWatch Logs /<prefix>/app
```

## Vì sao health check là `/ready` chứ không phải `/health`

Đây là chi tiết quan trọng nhất của module, và nó đến từ ràng buộc #5.

- `/health` trả 200 khi **tiến trình còn sống**.
- `/ready` trả 200 khi **máy này sẵn sàng nhận request**.

Nếu health check của ALB kiểm tra cả kết nối database, thì lúc RDS mất kết nối 3 phút, cả 2 máy đều fail health check, ALB rút hết target ra khỏi group, và người dùng nhận 503 từ ALB. Tệ hơn: ASG với `health_check_type = "ELB"` sẽ coi cả hai máy là hỏng và **terminate rồi tạo máy mới** — mất luôn dữ liệu trong bộ nhớ, và máy mới cũng fail y hệt vì database vẫn chưa lên.

Vì vậy `/ready` chỉ khẳng định tiến trình web nhận được request. Việc database không truy cập được do chính ứng dụng xử lý: trả lỗi rõ ràng cho client, đưa đơn vào SQS, không trả "thành công giả". Test `B4` xác nhận điều này — App tier và Worker không hề restart trong suốt 60 giây mất kết nối.

## `deregistration_delay = 30`

Khi rút một máy khỏi target group, ALB chờ 30 giây cho request đang chạy dở hoàn tất rồi mới cắt. Mặc định là 300 giây, quá lâu cho việc release. Ngắn hơn 30 thì có nguy cơ cắt giữa một request đang ghi đơn.

## Warm pool

`warm_pool_size = 2` giữ sẵn 2 máy ở trạng thái **Stopped**. Máy stopped chỉ tính tiền EBS (khoảng 0,6 USD/tháng cho 8 GB), không tính tiền giờ chạy.

Lợi ích: scale out từ máy stopped mất khoảng 30–40 giây thay vì 2–3 phút (không phải chờ tải AMI, chạy user-data, cài đặt). Ràng buộc #4 yêu cầu gián đoạn ≤ 2 phút khi một thành phần chết — warm pool là cách đạt được con số đó mà không phải trả tiền cho máy chạy không.

`reuse_on_scale_in = true`: lúc thu nhỏ, máy quay lại pool thay vì bị xoá.

## `instance_refresh` — cách release

`strategy = "Rolling"`, `min_healthy_percentage = 50`, `instance_warmup = 120`.

Release là: đẩy artifact mới lên S3, cập nhật `current.txt`, rồi gọi `start-instance-refresh`. ASG thay từng nửa nhóm một, chờ máy mới qua health check 120 giây rồi mới thay tiếp. Máy nào không qua được health check thì refresh dừng lại và nhóm giữ nguyên bản cũ.

Đây là câu trả lời cho "release thủ công, dễ sai sót" trong yêu cầu. Quy trình đầy đủ ở `../../../../docs/ban-giao/quy-trinh-release.md`.

## `tag_specifications` và `propagated_tags` — bẫy về tag

Công ty bắt buộc mọi tài nguyên có tag `owner`. Có hai chỗ `default_tags` của provider **không** với tới:

1. **Launch template**: tag của launch template không tự chảy xuống instance/volume/ENI mà nó tạo. Phải khai `tag_specifications` cho từng loại — ở đây là ba khối viết riêng cho `instance`, `network-interface`, `volume`, cùng dùng `local.instance_tags`.
2. **Auto Scaling group**: ASG không phải tài nguyên chịu `default_tags` như các tài nguyên khác, và tag của ASG chỉ chảy xuống instance khi `propagate_at_launch = true` — không chảy xuống volume.

`propagated_tags` là biến để root module truyền `default_tags` xuống, đảm bảo cả instance lẫn EBS volume đều có `owner`.

## Một nhóm máy, viết thẳng tên `app`

Trước đây launch template, ASG, scaling policy và log group đều `for_each` qua một map `capacity` theo tier (`web`, `app`, `worker`). Kiến trúc SPA chỉ còn tier `app`, worker chạy chung máy, nên map đó chỉ còn một phần tử mà vẫn bắt đọc `each.key`, `each.value.max`. Đã viết lại thành resource đơn: `aws_launch_template.app`, `aws_autoscaling_group.app`, với `min_size`, `desired_capacity`, `max_size` là biến thường.

## `lifecycle.ignore_changes = [desired_capacity]`

Không có dòng này, mỗi lần `terraform apply` sẽ kéo số máy về lại `desired` trong code, huỷ kết quả của target tracking policy đang chạy. Terraform quản min/max, autoscaling quản desired.

## `metadata_options`

IMDSv2 bắt buộc (`http_tokens = "required"`). Chặn cả một lớp lỗ hổng SSRF đọc trộm credential từ metadata endpoint.

## Hai bucket

- **artifacts**: bật versioning, instance tải file `.tar.gz` từ đây lúc boot theo con trỏ `current.txt`. Versioning cho phép rollback bằng cách trỏ `current.txt` về bản cũ.
- **alb-logs**: ALB ghi access log vào đây, có lifecycle xoá sau N ngày. Bucket policy phải cho account ID của ELB ở region ghi vào — đó là lý do có `aws_s3_bucket_policy.alb_logs`.

`drop_invalid_header_fields = true` trên ALB: bỏ header dị dạng thay vì chuyển tiếp xuống ứng dụng.

## Tài nguyên tạo ra

- `aws_autoscaling_group.app`
- `aws_autoscaling_policy.app_requests`
- `aws_cloudwatch_log_group.app`
- `aws_launch_template.app`
- `aws_lb.public`
- `aws_lb_listener.public`
- `aws_lb_target_group.app`
- `aws_s3_bucket.alb_logs`
- `aws_s3_bucket.artifacts`
- `aws_s3_bucket_lifecycle_configuration.alb_logs`
- `aws_s3_bucket_policy.alb_logs`
- `aws_s3_bucket_public_access_block.alb_logs`
- `aws_s3_bucket_public_access_block.artifacts`
- `aws_s3_bucket_server_side_encryption_configuration.artifacts`
- `aws_s3_bucket_versioning.artifacts`

## Biến

| Tên | Mô tả | Mặc định |
|---|---|---|
| `accept_store_driver` | Where accepted orders are recorded before they reach the database. | `"dynamodb"` |
| `accept_store_name` | DynamoDB table holding accepted order records. | `""` |
| `alb_security_group_id` | Security group of the public load balancer. | **bắt buộc** |
| `allow_destroy` | Let buckets be deleted while they still hold objects. | `false` |
| `allowed_origins` | Origins the application accepts browser requests from. | `"*"` |
| `app_port` | Port the application listens on. | `8080` |
| `app_security_group_id` | Security group of the application instances. | **bắt buộc** |
| `desired_capacity` | Instances the group starts with. Target tracking adjusts it afterwards. | `2` |
| `dlq_url` | URL of the dead letter queue. | **bắt buộc** |
| `instance_profile_name` | Instance profile giving the instances their permissions. | **bắt buộc** |
| `instance_type` | Instance type. Graviton is about twenty percent cheaper and the application is pure Python. | `"t4g.small"` |
| `log_retention_days` | Days CloudWatch keeps application logs. | `30` |
| `max_receive_count` | Deliveries a message gets before it is moved to the dead letter queue. Must match the queue setting. | `5` |
| `max_size` | Most instances the group scales out to. | `6` |
| `min_size` | Fewest instances the group keeps running. | `2` |
| `name_prefix` | Prefix applied to every resource name in this module. | **bắt buộc** |
| `private_subnet_ids` | Private subnets holding the application instances. | **bắt buộc** |
| `propagated_tags` | Tags copied onto every instance the group launches. | `{}` |
| `public_subnet_ids` | Public subnets holding the internet facing load balancer. | **bắt buộc** |
| `queue_url` | URL of the order queue. | **bắt buộc** |
| `requests_per_target` | Target tracking goal: requests per minute each instance should carry before the group scales out. | `600` |
| `visibility_timeout_seconds` | How long a message stays invisible after a worker picks it up. Must match the queue setting. | `180` |
| `vpc_id` | VPC the load balancer and instances run in. | **bắt buộc** |
| `warm_pool_size` | Stopped instances kept ready so a scale out takes seconds instead of minutes. | `2` |

## Đầu ra

| Tên | Mô tả |
|---|---|
| `artifact_bucket` | Bucket the instances download the application from at boot. |
| `autoscaling_group_name` | Name of the Auto Scaling group. |
| `log_group_name` | CloudWatch log group the application writes to. |
| `public_alb_arn_suffix` | Suffix CloudWatch uses to identify the internet facing load balancer. |
| `public_alb_dns_name` | Hostname of the internet facing load balancer. |
| `target_group_arn_suffix` | Suffix CloudWatch uses to identify the application target group. |
