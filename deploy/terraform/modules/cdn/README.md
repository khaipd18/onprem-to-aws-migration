# `cdn`

CloudFront đứng trước cả bucket tĩnh và ALB. Đây là điểm vào duy nhất của người dùng.

## Kiến trúc

```
                     người dùng
                          │  HTTPS (chứng chỉ *.cloudfront.net)
                          ▼
                   CloudFront distribution
                          │
          ┌───────────────┴────────────────┐
          │                                │
   default behavior                  /api/*
   cache: CachingOptimized           cache: CachingDisabled
          │                                │
          ▼                                ▼
   S3 assets (qua OAC)              ALB public (HTTP)
   index.html, JS, CSS              FastAPI

   403 / 404 từ S3  ──▶  200 + /index.html   (routing của SPA)
```

## Vì sao bắt buộc phải có CloudFront

Không phải để tăng tốc, mà vì **chứng chỉ TLS**. Tài khoản này không được cấp quyền ACM, nên không thể gắn chứng chỉ cho ALB. CloudFront đi kèm sẵn chứng chỉ cho domain `*.cloudfront.net`, được trình duyệt tin cậy, không tốn thêm đồng nào và không cần quyền gì.

Không có CloudFront thì hoặc phải chạy HTTP trần, hoặc phải dùng chứng chỉ tự ký và người dùng gặp cảnh báo bảo mật.

Lợi ích kèm theo: một tên miền duy nhất cho cả front-end lẫn API nên **không có CORS**; trả file tĩnh từ edge nên ALB không phải phục vụ chúng.

## Hai behavior

| | default | `/api/*` |
|---|---|---|
| origin | S3 assets | ALB |
| cache policy | `CachingOptimized` | `CachingDisabled` |
| method | GET, HEAD, OPTIONS | thêm PUT, POST, PATCH, DELETE |
| origin request policy | `CORS-S3Origin` | `AllViewerExceptHostHeader` |

`CachingDisabled` cho `/api/*` là bắt buộc. Cache một POST tạo đơn hoặc một GET trạng thái đơn thì người dùng thấy dữ liệu cũ — vi phạm ràng buộc #3 (trạng thái đơn phải xác định được).

`AllViewerExceptHostHeader` chuyển tiếp toàn bộ header, cookie, query string của người dùng xuống ALB **trừ** `Host`. Giữ nguyên `Host` thì ALB nhận host của CloudFront và routing theo host sẽ hỏng. Header `Idempotency-Key` mà ứng dụng dùng để chống đơn trùng đi qua được nhờ policy này.

## `custom_error_response` — vì sao ánh xạ 403/404 thành 200

SPA điều hướng ở phía trình duyệt. Người dùng mở thẳng `/orders/123`, CloudFront đi tìm object `orders/123` trong S3, không có, S3 trả 403 (do OAC không lộ 404). Nếu trả nguyên như vậy thì người dùng thấy trang lỗi XML.

Ánh xạ 403 và 404 thành **200 + `/index.html`** để SPA nhận được HTML rồi tự xử lý đường dẫn. `error_caching_min_ttl = 10` để lúc vừa deploy file mới, CloudFront không giữ trạng thái lỗi lâu.

## `redirect-to-https`

Cả hai behavior đặt `viewer_protocol_policy = "redirect-to-https"`. Ai gõ `http://` sẽ bị chuyển sang `https://` chứ không bị từ chối.

Phía sau, `origin_protocol_policy` mặc định là `http-only` vì ALB chưa có chứng chỉ. Đổi sang `https-only` ngay khi ACM được cấp.

## `price_class`

Mặc định `PriceClass_200`, gồm edge ở châu Á. `PriceClass_All` đắt hơn mà không có ích khi người dùng đều ở Việt Nam. Dùng `PriceClass_100` (chỉ Mỹ + châu Âu) sẽ khiến người dùng trong nước đi vòng, latency tệ hơn.

## Bucket policy nằm ở module này

`aws_s3_bucket_policy.assets` được đặt ở đây, không ở module `static`, vì nó cần ARN của distribution. Đặt ở `static` sẽ tạo phụ thuộc vòng giữa hai module.

## Tài nguyên tạo ra

- `aws_cloudfront_distribution.main`
- `aws_cloudfront_origin_access_control.assets`
- `aws_s3_bucket_policy.assets`

## Biến

| Tên | Mô tả | Mặc định |
|---|---|---|
| `alb_domain_name` | DNS name of the public load balancer, used as the origin for everything that is not a static asset. | **bắt buộc** |
| `assets_bucket_arn` | ARN of the asset bucket. | **bắt buộc** |
| `assets_bucket_id` | Name of the bucket holding the front end. | **bắt buộc** |
| `assets_bucket_regional_domain_name` | Regional domain name of the asset bucket, used as the origin for /static/*. | **bắt buộc** |
| `name_prefix` | Prefix applied to every resource name in this module. | **bắt buộc** |
| `origin_protocol_policy` | How the distribution talks to the load balancer. Set to https-only once the load balancer has a certificate. | `"http-only"` |
| `price_class` | Edge locations the distribution uses. | `"PriceClass_200"` |

## Đầu ra

| Tên | Mô tả |
|---|---|
| `distribution_arn` | ARN of the distribution, referenced by the asset bucket policy. |
| `distribution_id` | ID of the distribution. |
| `domain_name` | Hostname users open. Served over HTTPS with the certificate AWS provides for this domain. |
| `static_base_url` | Value for the STATIC_BASE_URL environment variable of the web tier. |
