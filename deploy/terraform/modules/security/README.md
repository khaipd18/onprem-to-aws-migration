# `security`

Sáu security group xâu chuỗi theo tầng. Không tầng nào mở cổng trực tiếp ra ngoài trừ ALB.

## Chuỗi cho phép

```
Internet (0.0.0.0/0)
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

## Vì sao tham chiếu security group chứ không viết CIDR

Mỗi luật vào đều lấy nguồn là **ID của security group tầng trên**, không phải dải IP. Đổi subnet, thêm AZ, tăng số instance đều không phải sửa luật. Và không có cách nào một máy lạ trong VPC chạm được RDS chỉ vì nó ở đúng dải IP — nó phải được gắn đúng security group.

## Vì sao có cả `rds_from_proxy` lẫn `rds_from_app`

Đường chính là qua RDS Proxy: proxy giữ sẵn pool kết nối, nên lúc RDS failover Multi-AZ ứng dụng không phải mở lại kết nối từ đầu — đây là phần đỡ cho ràng buộc #5.

`rds_from_app` là đường dự phòng, dùng khi proxy chưa được tạo (`create_proxy = false`) hoặc khi cần nối thẳng để chẩn đoán. Bỏ luật này thì môi trường không có proxy sẽ chết ngay.

## Mỗi luật viết thành một khối riêng

Có 9 luật vào, mỗi luật một `resource` riêng, tên nói rõ đi từ đâu tới đâu: `rds_from_proxy`, `fileserver_from_app`… Đọc file là thấy ngay ai được gọi ai, không phải giải một vòng `for_each` trong đầu.

Chỉ luật ra (`allow_all`) dùng `for_each`, vì 6 luật đó giống hệt nhau, chỉ khác security group.

## Khi bật CloudFront

ALB đang mở 80 và 443 cho `0.0.0.0/0`. Khi CloudFront chạy thật, nên đổi `cidr_ipv4 = "0.0.0.0/0"` trong `alb_public_http` và `alb_public_https` thành `prefix_list_id = "pl-31a34658"` (prefix list `com.amazonaws.global.cloudfront.origin-facing` ở ap-southeast-1). Lúc đó không ai gọi thẳng DNS của ALB để đi vòng qua CDN được nữa. Chưa làm vì CloudFront chưa bật.

## `sg-admin-client` không có luật vào

Đúng như vậy, và nó không thừa. Security group này tồn tại để **được tham chiếu làm nguồn** — máy trạm quản trị hoặc DataSync agent gắn nó vào, rồi các tầng khác mở cổng cho nó. Bản thân nó không cần ai gọi vào.

## Egress

Một luật `allow_all` chung cho tất cả: mọi security group được ra hết. Chặn chiều ra ở tầng security group không thêm bao nhiêu an toàn ở quy mô này, trong khi làm hỏng những thứ khó đoán như gọi API AWS, cập nhật gói, gửi log. Việc chặn đường ra đã do route table của tầng `data` lo (không có NAT, không có IGW).

## Tài nguyên tạo ra

- `aws_security_group.admin_client`
- `aws_security_group.alb_public`
- `aws_security_group.app`
- `aws_security_group.fileserver`
- `aws_security_group.rds`
- `aws_security_group.rds_proxy`
- `aws_vpc_security_group_egress_rule.allow_all`
- `aws_vpc_security_group_ingress_rule.alb_public_http`
- `aws_vpc_security_group_ingress_rule.alb_public_https`
- `aws_vpc_security_group_ingress_rule.app_from_alb_public`
- `aws_vpc_security_group_ingress_rule.fileserver_from_admin_client`
- `aws_vpc_security_group_ingress_rule.fileserver_from_app`
- `aws_vpc_security_group_ingress_rule.rds_from_app`
- `aws_vpc_security_group_ingress_rule.rds_from_proxy`
- `aws_vpc_security_group_ingress_rule.rds_proxy_from_app`

## Biến

| Tên | Mô tả | Mặc định |
|---|---|---|
| `name_prefix` | Prefix applied to every resource name in this module. | **bắt buộc** |
| `vpc_id` | VPC the security groups belong to. | **bắt buộc** |

## Đầu ra

| Tên | Mô tả |
|---|---|
| `admin_client_id` | Security group of the administrative workstation and DataSync agent. |
| `alb_public_id` | Security group of the public load balancer. |
| `app_arn` | ARN of the application tier security group, the form DataSync expects. |
| `app_id` | Security group of the application tier instances and workers. |
| `fileserver_id` | Security group of the file server. |
| `rds_id` | Security group of the database instances. |
| `rds_proxy_id` | Security group of the database proxy. |
