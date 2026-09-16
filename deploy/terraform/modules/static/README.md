# `static`

Bucket chứa file tĩnh của SPA. Chỉ CloudFront đọc được, không mở public.

## Kiến trúc

```
   thư mục local (build/spa)
        │  aws_s3_object.assets — for_each qua fileset()
        ▼
   S3 bucket "<prefix>-assets"
        │  public access block: chặn hết
        │  versioning: bật
        │  SSE-S3 (AES256)
        ▼
   chỉ CloudFront đọc được, qua Origin Access Control
   (bucket policy do module cdn tạo, không phải module này)
```

## Vì sao bucket không bật website hosting

S3 static website endpoint chỉ chạy HTTP, không có HTTPS, và bắt buộc bucket phải public. Ở đây bucket đóng hoàn toàn; CloudFront ký request bằng **Origin Access Control** để đọc — người dùng không có đường nào chạm thẳng vào bucket.

Đổi lại, phần xử lý "route của SPA không phải là file có thật" chuyển sang CloudFront (`custom_error_response`), xem README của module `cdn`.

## `aws_s3_object` với `for_each` qua `fileset()`

Terraform quản luôn từng file trong `source_dir`, nên `terraform plan` cho thấy chính xác file nào thêm, sửa, xoá. Không cần chạy `aws s3 sync` riêng.

`etag = filemd5(...)` để Terraform phát hiện file đổi nội dung dù tên không đổi.

`content_type` tra từ một map theo đuôi file. Thiếu đuôi trong map thì object nhận `application/octet-stream` và trình duyệt tải file về thay vì hiển thị — lỗi này từng xảy ra với chính `index.html`.

Cách này hợp với SPA vài chục file. Với hàng nghìn file thì `plan` chậm, lúc đó nên tách sang bước sync riêng trong pipeline.

## Versioning

Bật versioning cộng lifecycle xoá bản cũ sau `noncurrent_version_expiration_days`. Deploy nhầm bản front-end thì khôi phục được version trước, không phải build lại.

## `allow_destroy`

Mặc định `false`, tức `force_destroy = false`: `terraform destroy` sẽ báo lỗi nếu bucket còn object. Bật `true` khi thực sự muốn dọn môi trường.

## Tài nguyên tạo ra

- `aws_s3_bucket.assets`
- `aws_s3_bucket_lifecycle_configuration.assets`
- `aws_s3_bucket_ownership_controls.assets`
- `aws_s3_bucket_public_access_block.assets`
- `aws_s3_bucket_server_side_encryption_configuration.assets`
- `aws_s3_bucket_versioning.assets`
- `aws_s3_object.assets`

## Biến

| Tên | Mô tả | Mặc định |
|---|---|---|
| `allow_destroy` | Let buckets be deleted while they still hold objects. | `false` |
| `assets_dir` | Local directory whose contents are uploaded to the bucket. Paths inside it become object keys. | **bắt buộc** |
| `name_prefix` | Prefix applied to every resource name in this module. | **bắt buộc** |
| `noncurrent_version_retention_days` | Days an overwritten object version is kept before it is deleted. | `30` |

## Đầu ra

| Tên | Mô tả |
|---|---|
| `bucket_arn` | ARN of the asset bucket. |
| `bucket_name` | Name of the asset bucket. |
| `bucket_regional_domain_name` | Regional domain name, used as the distribution origin. |
| `object_count` | Number of objects uploaded from the local directory. |
