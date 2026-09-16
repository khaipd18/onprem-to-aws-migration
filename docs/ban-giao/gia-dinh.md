# Giả định đã chốt

Yêu cầu cho phép nhóm tự đặt thêm giả định hợp lý, miễn **ghi rõ trong bài làm
và giữ nhất quán**. Đây là bản chốt. Mọi con số trong báo cáo, báo giá, test và
mã nguồn đều phải khớp với bảng dưới — nếu thay đổi, sửa ở đây trước.

## Quy mô nghiệp vụ

| Hạng mục | Giả định production | Quy mô demo |
|---|---|---|
| Số người dùng | 150 (1 HQ + 2 chi nhánh) | 60 khách hàng, 5 phòng ban |
| Tải bình thường | 50 req/s | 50 req/s |
| Tải cao điểm (5x) | 250 req/s trong 30 phút | 250 req/s trong 30 phút |
| Dung lượng PostgreSQL | 50 GB | 2–5 GB (mặc định seed ~11 MB) |
| Dung lượng File Server | 500 GB | 20–50 GB (mặc định script ~50 MB) |
| Số phòng ban (ACL group) | 5 | 5 |
| Ngân sách tháng | ~1.500 USD | — |

Yêu cầu cho phép "thu nhỏ dung lượng dữ liệu thực hành nhưng phải giữ đầy đủ
các hành vi". Diễn giải đã chốt: **giảm dữ liệu, không giảm test case.**
Số phòng ban, độ sâu cây thư mục, số trạng thái đơn hàng, số tier — giữ nguyên.

## Giả định kỹ thuật

| Câu hỏi | Đã chốt | Vì sao |
|---|---|---|
| Region | `ap-southeast-1` (Singapore) | Gần VN nhất, đủ dịch vụ (RDS Proxy, EFS, DMS) |
| File Server nguồn chạy trên gì | **Linux**, quyền POSIX theo phòng ban; dùng EFS + Access Point ở đích | Yêu cầu không nêu hệ điều hành. Chốt Linux: rẻ hơn ~7 lần so với FSx + Managed AD (~18 USD so với ~128 USD/tháng) và Access Point chặn được ở tầng dịch vụ, `root` trên EC2 cũng không lách. Nhánh Windows/SMB đã bỏ khỏi phạm vi |
| Ứng dụng có chạy được ARM không | Có → dùng Graviton `t4g` | Rẻ hơn ~20%. Ứng dụng là Python thuần, không có binary phụ thuộc kiến trúc |
| Đơn vị tiền | VND, hiển thị nguyên đồng | Khớp bối cảnh khách hàng Việt Nam |
| Ứng dụng nguồn | 1 web app + 1 backend (2 server vật lý) | Đúng nguyên văn bối cảnh Mục 1 |
| Loại giao dịch cần bảo toàn | Đơn hàng bán (`orders`) | Ràng buộc #2/#3/#5/#6 đều nói về "đơn hàng" |
| Ai dùng ứng dụng | **Nhân viên nội bộ** nhập đơn hộ khách hàng | Màn hình nhập đơn đổ toàn bộ danh sách khách vào dropdown — chỉ có nghĩa với người dùng nội bộ. `customers.branch` là chi nhánh của ABC phụ trách tài khoản, `customers.department` gắn với phòng ban nội bộ. 150 người dùng ở 3 địa điểm là nhân viên |
| Cơ chế xác thực người dùng | **Giữ nguyên như hệ thống nguồn**, ngoài phạm vi giai đoạn này | Xem mục dưới |

## Xác thực người dùng — ngoài phạm vi, có chủ ý

Yêu cầu **không nêu yêu cầu nào về xác thực**. Đã quét toàn bộ 168 dòng / 2.333
từ của yêu cầu, cả có dấu lẫn không dấu: các từ *đăng nhập, xác thực, tài khoản,
mật khẩu, danh tính, SSO, Cognito, identity, login, OAuth, OIDC, JWT, LDAP,
Active Directory, MFA, session, credential, portal* **không xuất hiện lần nào**.

Chỗ duy nhất nói về phân quyền là ràng buộc #7, và nó nằm trọn trong phạm vi
File Server:

> "7. **File Server** và phân quyền: Giữ nguyên nội dung, cấu trúc thư mục và
> quyền theo phòng ban sau chuyển đổi..."

Chỗ thứ hai là chữ "bảo mật" trong phần việc của SA, nhưng đứng chung với "khả
năng mở rộng, sẵn sàng cao" — nhóm yêu cầu phi chức năng, không phải yêu cầu
về xác thực.

**Đã chốt:** cơ chế đăng nhập giữ nguyên như hệ thống nguồn. Đây là bài chuyển
dịch hạ tầng, không phải thay đổi mô hình danh tính.

**Lý do không đưa Amazon Cognito vào kiến trúc:**

1. Yêu cầu không yêu cầu, và hệ thống hiện tại không có người dùng ngoài tổ chức.
2. Cognito lưu **danh tính đăng nhập**, không lưu hồ sơ khách hàng doanh nghiệp.
   Mã khách hàng, chi nhánh phụ trách, phòng ban, công nợ phải nằm ở PostgreSQL
   để join được với `orders` khi làm báo cáo — bảng `customers` đã làm đúng
   việc đó.
3. Thêm Cognito là ghép một cuộc chuyển dịch thứ hai vào cửa sổ downtime 15
   phút của ràng buộc #2: 150 tài khoản phải tạo lại, mật khẩu không chuyển
   được, luồng đăng nhập phải viết lại. Nguyên tắc migration: đổi nền tảng thì
   đừng đổi kiến trúc ứng dụng cùng lúc.
4. Cognito **không** giải được ràng buộc #7. EFS Access Point cần POSIX UID/GID
   chứ không đọc được JWT. Muốn có danh tính cho hệ thống tệp thì đó là
   Directory Service.

**Khi nào cần xem lại:** nếu ABC mở cổng cho khách hàng tự đặt đơn, hoặc có ứng
dụng di động dùng chung API. Lúc đó Cognito là lựa chọn đúng, và vẫn giữ bảng
`customers` — Cognito chỉ thêm lớp đăng nhập ánh xạ `sub` sang `customer_code`.
Ghi vào phần hướng phát triển tiếp của báo cáo.

## Giả định của môi trường demo local

Những điều dưới đây chỉ đúng ở local, **không** mang lên AWS:

| Ở local | Trên AWS |
|---|---|
| `POSTGRES_HOST_AUTH_METHOD=trust` | Mật khẩu trong Secrets Manager, xoay vòng 30 ngày, `RequireTLS` trên RDS Proxy |
| Hàng đợi là bảng trong PostgreSQL riêng | SQS FIFO `orders.fifo` + DLQ |
| Accept store là bảng `order_accept` | DynamoDB on-demand + TTL 24 giờ, hoặc S3 conditional put nếu không được cấp quyền DynamoDB |
| Read replica dựng bằng `pg_basebackup` | `aws_db_instance` với `replicate_source_db` |
| `VISIBILITY_TIMEOUT=30` (dễ quan sát) | `180` (≥ 6× thời gian xử lý của worker) |
| Sự cố DB mô phỏng bằng `docker network disconnect` | Gỡ rule 5432 trên security group `sg-rds` |

## Định nghĩa "giao dịch thành công"

Định nghĩa này quyết định cách đọc kết quả của toàn bộ test, nên chốt ngay từ
đầu:

> Một đơn hàng được coi là **thành công** khi và chỉ khi nó tồn tại trong bảng
> `orders` với `status = 'CONFIRMED'`.

Hệ quả:

- `HTTP 202` **không** phải là thành công. Nó có nghĩa "đã nhận yêu cầu".
- Đơn ở trạng thái `PENDING` chưa phải giao dịch thành công, nên việc nó biến
  mất khi có sự cố **không** tính là "mất giao dịch".
- Ràng buộc #5 nói "không mất giao dịch đã xác nhận" — phạm vi là các đơn đã
  `CONFIRMED`. Đây là lý do kiến trúc trả 202 chứ không trả 200: nó thu hẹp
  phạm vi cam kết xuống đúng phần hệ thống thực sự bảo đảm được.
