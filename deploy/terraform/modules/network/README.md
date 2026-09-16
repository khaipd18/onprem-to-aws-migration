# `network`

Mạng nền: VPC hai vùng sẵn sàng, ba tầng subnet, đường ra internet.

## Kiến trúc

```
                        Internet
                            │
                      Internet Gateway
                            │
  ┌─────────────────────────┴─────────────────────────┐
  │  public   10.0.0.0/24              10.0.1.0/24    │   ALB, NAT Gateway
  │              │                                     │   → IGW
  │           NAT GW ──────────┐                       │
  ├──────────────────────────┬─┴───────────────────────┤
  │  private  10.0.10.0/24   │        10.0.11.0/24     │   EC2 App tier
  │                          └── ra internet qua NAT   │   → NAT, một chiều
  ├──────────────────────────────────────────────────  ┤
  │  data     10.0.20.0/24             10.0.21.0/24    │   RDS, EFS, DMS
  │           route table chỉ có "local"               │   → không có
  └────────────────────────────────────────────────────┘
        ap-southeast-1a           ap-southeast-1b
```

## Ba tầng khác nhau ở chỗ nào

| Tầng | Ra internet | Vào từ internet | Chứa gì |
|---|---|---|---|
| public | qua IGW | qua ALB | ALB public, NAT Gateway |
| private | qua NAT, một chiều | không | EC2 App tier |
| data | **không** | không | RDS, RDS Proxy, EFS mount target, DMS |

Điều phân biệt `private` với `data` là **route table**, không phải cái tên. Tầng `data` chỉ có route `local`, không gắn IGW cũng không gắn NAT. Gộp hai tầng lại thì RDS có đường ra internet — mất hẳn tính tách biệt.

## Vì sao dùng `for_each` theo AZ chứ không dùng `count`

Địa chỉ trong state là `aws_subnet.private["ap-southeast-1a"]` chứ không phải `[0]`. Sau này bỏ hay chèn một AZ sẽ không làm dịch chỉ số rồi destroy nhầm subnet đang chạy.

## Một NAT Gateway, không phải hai

Một NAT duy nhất đặt ở AZ `nat_az` (mặc định `ap-southeast-1a`), rẻ hơn khoảng 43 USD mỗi tháng so với mỗi AZ một cái. Cả hai route table private đều trỏ về NAT này.

Đánh đổi: AZ chứa NAT chết thì cả hai AZ mất đường ra internet. Không ảnh hưởng luồng nhận đơn — traffic vào đi qua ALB, không qua NAT. Chỉ ảnh hưởng lúc ASG scale out phải tải artifact, mà việc đó đã đi qua S3 Gateway Endpoint.

Muốn mỗi AZ một NAT thì phải sửa code: đổi `aws_eip.nat` và `aws_nat_gateway.this` sang `for_each` theo AZ, rồi cho mỗi route private trỏ về NAT cùng AZ. Trước đây module có cờ `single_nat_gateway` làm việc này, nhưng đã bỏ vì không ai bật và nó kéo theo ba biểu thức khó đọc.

Tắt NAT tạm thời cho đỡ tốn tiền (dữ liệu không mất):

```bash
terraform destroy -target=module.network.aws_nat_gateway.this -target=module.network.aws_eip.nat
```

Route private trỏ vào NAT bị xoá theo. `terraform apply` lần sau dựng lại cả ba.

## S3 Gateway Endpoint

Miễn phí. Đưa lưu lượng S3 ra khỏi NAT Gateway, nên phần phí xử lý dữ liệu của NAT giảm hẳn — instance tải artifact lúc boot đi qua đây.

Khác với interface endpoint (khoảng 7 USD mỗi AZ mỗi tháng), loại đó đắt hơn cả NAT ở quy mô này.

## Tài nguyên tạo ra

- `aws_eip.nat`
- `aws_internet_gateway.this`
- `aws_nat_gateway.this`
- `aws_route.private_nat`
- `aws_route.public_internet`
- `aws_route_table.data`
- `aws_route_table.private`
- `aws_route_table.public`
- `aws_route_table_association.data`
- `aws_route_table_association.private`
- `aws_route_table_association.public`
- `aws_subnet.data`
- `aws_subnet.private`
- `aws_subnet.public`
- `aws_vpc.this`
- `aws_vpc_endpoint.s3`

## Biến

| Tên | Mô tả | Mặc định |
|---|---|---|
| `data_subnets` | Isolated subnets, keyed by availability zone. Hosts the database and the file server. | **bắt buộc** |
| `name_prefix` | Prefix applied to every resource name in this module. | **bắt buộc** |
| `nat_az` | Availability zone holding the single NAT gateway. Must be one of the public subnet keys. | `"ap-southeast-1a"` |
| `private_subnets` | Private subnets, keyed by availability zone. Hosts the application instances. | **bắt buộc** |
| `public_subnets` | Public subnets, keyed by availability zone. Hosts the load balancer and the NAT gateway. | **bắt buộc** |
| `region` | Region the VPC lives in. Used to name the S3 endpoint service. | **bắt buộc** |
| `vpc_cidr` | CIDR block of the VPC. | **bắt buộc** |

## Đầu ra

| Tên | Mô tả |
|---|---|
| `data_subnet_arns` | Isolated subnet ARNs, the form DataSync expects. |
| `data_subnet_ids` | Isolated subnet IDs. |
| `nat_gateway_id` | ID of the NAT gateway. |
| `private_subnet_ids` | Private subnet IDs. |
| `public_subnet_ids` | Public subnet IDs. |
| `vpc_id` | ID of the VPC. |
