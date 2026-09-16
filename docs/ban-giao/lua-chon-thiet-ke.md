# Vì sao chọn dịch vụ này, không chọn dịch vụ kia

Mỗi mục: **đã chọn gì**, **đối thủ là gì**, **vì sao**, và **khi nào thì chọn ngược lại**.

Phần cuối là bảng phân biệt những thứ hay bị lẫn.

---

# PHẦN A — LỰA CHỌN DỊCH VỤ

## 1. Compute: EC2 + Auto Scaling

**Đối thủ:** ECS Fargate · Lambda · Elastic Beanstalk · EKS

| | EC2 + ASG | Fargate | Lambda |
|---|---|---|---|
| Scale out | 30–40s (warm pool) · 2–3 phút (máy mới) | 30–60s | tức thì |
| Phải container hoá | không | **có** | phải viết lại theo handler |
| Chi phí ở tải thấp | trả theo giờ | trả theo giờ | gần 0 |
| Giữ kết nối DB lâu | tốt | tốt | **kém**, cần RDS Proxy bắt buộc |

**Chọn EC2 vì:** ứng dụng là một tiến trình Python chạy thẳng trên OS bằng
systemd. Đây đúng "chất" migration từ on-premise — khách hàng đang chạy như vậy,
chuyển lên AWS mà không phải viết lại.

Container hoá thêm một lớp phải học, phải dựng registry, phải chứng minh. Trong
2 tuần thì đổi lại không đáng.

**Khi nào chọn ngược:** nếu khách đã dùng Docker sẵn, hoặc tải nhảy vọt bất
thường cần scale trong giây. Fargate gần như xoá được rủi ro spike.

Lambda không hợp ở đây: worker chạy liên tục poll SQS, và giữ connection pool tới
PostgreSQL — hai thứ Lambda làm kém.

---

## 2. Database: RDS PostgreSQL Multi-AZ

**Đối thủ:** Aurora PostgreSQL · PostgreSQL tự cài trên EC2 · Multi-AZ DB Cluster

| | RDS Multi-AZ instance | Aurora | Tự cài trên EC2 |
|---|---|---|---|
| Failover | 60–120s | ~30s | tự làm |
| Chi phí | thấp nhất | +20–30% | rẻ nhưng tốn người |
| Backup, PITR | có sẵn | có sẵn | tự dựng |
| Tương thích PostgreSQL | 100% | gần 100% | 100% |

**Chọn RDS Multi-AZ instance vì:** yêu cầu yêu cầu RTO ≤ 30 phút. Failover
60–120 giây thừa xa. Aurora nhanh hơn nhưng đắt hơn mà không giải quyết thêm
ràng buộc nào.

Tự cài trên EC2 thì mất luôn lý do chuyển lên cloud — vẫn phải tự lo backup, tự
lo replication, tự lo vá lỗi.

**Multi-AZ DB Cluster** (3 instance, failover ~35s) đắt hơn, và yêu cầu không đòi
RTO tính bằng giây.

**Khi nào chọn ngược:** RTO yêu cầu dưới 1 phút → Aurora. Hoặc cần đọc mở rộng
mạnh → Aurora có tới 15 reader.

---

## 3. Hàng đợi: SQS FIFO

**Đối thủ:** SQS Standard · Amazon MSK (Kafka) · EventBridge · RabbitMQ tự dựng

| | SQS FIFO | SQS Standard | MSK |
|---|---|---|---|
| Giữ thứ tự | có, trong message group | **không** | có, trong partition |
| Giao đúng một lần | có (cửa sổ 5 phút) | **at-least-once** | at-least-once |
| Thông lượng | 3.000 msg/s per group | không giới hạn | rất cao |
| Vận hành | không phải làm gì | không phải làm gì | **phải quản cluster** |
| Chi phí | theo request | theo request | tối thiểu ~150 USD/tháng |

**Chọn FIFO vì ràng buộc #3** đòi hai thứ mà Standard không có:

- **Khử trùng lặp 5 phút** theo `MessageDeduplicationId` — client bấm gửi hai
  lần, message thứ hai bị SQS bỏ trước khi chạm worker
- **Thứ tự trong cùng message group** — hai lần sửa một đơn xử lý đúng thứ tự,
  bản cũ không đè bản mới

MSK dư thừa hoàn toàn: 150 USD/tháng và phải quản cluster, cho một hệ thống
150 người dùng.

EventBridge hợp cho routing sự kiện giữa nhiều dịch vụ, không hợp làm hàng đợi
công việc có retry và DLQ.

**Đánh đổi đã chấp nhận:** FIFO mặc định chỉ 300 msg/s. Bật
`deduplication_scope = messageGroup` + `fifo_throughput_limit = perMessageGroupId`
lên được 3.000, và vì `MessageGroupId` là mã khách hàng nên các khách không chờ
nhau.

---

## 4. Sổ ghi nhận đơn: DynamoDB

**Đối thủ:** một bảng trong RDS · S3 · ElastiCache Redis

| | DynamoDB | Bảng trong RDS | S3 | Redis |
|---|---|---|---|---|
| Còn đọc được khi RDS chết | **có** | **không** | có | có |
| Ghi có điều kiện (chống trùng) | có | có | **không** | có |
| Tra theo `order_id` | có, qua GSI | có | **không** | phải tự đánh index |
| Bền khi mất điện | có | có | có | **mất nếu không bật persistence** |

**Chọn DynamoDB vì cột đầu tiên.** Mục đích của sổ ghi nhận là trả lời *"đơn của
tôi đang ở đâu"* **khi database chính chết**. Để nó trong chính RDS là mất hoàn
toàn tác dụng.

S3 loại vì không có ghi có điều kiện — không chặn trùng được.

Redis loại vì phải bật persistence mới bền, và thêm một cluster phải quản.

**Chi phí:** PAY_PER_REQUEST, không có traffic thì gần như 0.

---

## 5. File server: EFS + Access Point

**Đối thủ:** FSx for Windows · FSx for Lustre · S3 · EBS Multi-Attach

| | EFS | FSx for Windows | S3 |
|---|---|---|---|
| Giao thức | NFS | SMB | HTTP API |
| Phân quyền | POSIX uid/gid | ACL + Active Directory | IAM policy |
| Nhiều máy cùng mount | có | có | không phải filesystem |
| Chi phí 50 GB | ~18 USD | ~33 USD + phí AD | ~1 USD |

**Chọn EFS vì giả định:** yêu cầu chỉ nói *"File Server dùng chung cho các phòng
ban"*, không nói hệ điều hành. Giả định đã chốt ở `gia-dinh.md`: on-premise chạy
Linux, chia sẻ qua NFS, phân quyền POSIX.

Với giả định đó, EFS là ánh xạ **một–một**: cùng NFS, cùng mô hình uid/gid/mode.
Chép sang giữ nguyên quyền, `diff` hai bản kiểm kê là so được.

**Khi nào chọn ngược:** nếu on-premise là Windows + SMB + Active Directory →
FSx for Windows. Đắt hơn nhưng là lựa chọn duy nhất đúng.

S3 loại vì **không phải filesystem** — ứng dụng và người dùng đang mount ổ đĩa,
chuyển sang API là bắt viết lại cách làm việc.

---

## 6. Giao diện: S3 + CloudFront, không phải EC2 Web tier

**Đối thủ:** tầng EC2 riêng chạy web server · Amplify Hosting

| | S3 + CloudFront | EC2 Web tier |
|---|---|---|
| Số máy | 0 | 2 |
| ALB | dùng chung với API | thêm 1 cái |
| Chi phí/tháng | 207,82 USD tổng | 256,19 USD tổng |
| HTTPS tin cậy | **có sẵn miễn phí** | cần ACM |
| CORS | không cần | phải cấu hình |

**Lý do quyết định là chứng chỉ TLS.** Tài khoản không được cấp quyền ACM nên
ALB không gắn được chứng chỉ. CloudFront đi kèm sẵn chứng chỉ cho
`*.cloudfront.net`, được trình duyệt tin cậy, không tốn tiền và không cần quyền.

Không có CloudFront thì hoặc chạy HTTP trần, hoặc dùng chứng chỉ tự ký và người
dùng gặp cảnh báo đỏ — không demo trước khách được.

**Tách biệt Web/App mà yêu cầu yêu cầu vẫn giữ nguyên**, chỉ là ranh giới chuyển
từ *giữa hai tầng EC2* sang *giữa CloudFront/S3 và ALB/EC2*.

---

## 7. Cân bằng tải: ALB

**Đối thủ:** NLB · Classic Load Balancer

| | ALB | NLB |
|---|---|---|
| Tầng | 7 (HTTP) | 4 (TCP) |
| Định tuyến theo path | **có** | không |
| Health check HTTP | có | chỉ TCP |
| Độ trễ | vài ms | thấp hơn |
| IP tĩnh | không | có |

**Chọn ALB vì** cần health check theo đường dẫn HTTP (`/ready`) và định tuyến
theo path. NLB chỉ kiểm được cổng có mở không — không phân biệt được "tiến trình
sống" với "tiến trình sống nhưng không phục vụ được".

CLB là thế hệ cũ, AWS không khuyến nghị cho thiết kế mới.

---

## 8. Migration dữ liệu: DMS, và logical replication làm dự phòng

**Đối thủ:** PostgreSQL logical replication · `pg_dump`/`pg_restore` · AWS MGN

| | DMS | Logical replication | pg_dump |
|---|---|---|---|
| Có CDC (bám thay đổi) | có | có | **không** |
| Báo cáo đối chiếu từng dòng | **có sẵn** | tự viết | không |
| Chi phí | ~0,22 USD cho 6 giờ | 0 | 0 |
| Phải cài gì thêm | không | không | không |

**Chọn DMS vì Data Validation Report** — bằng chứng đối chiếu row-by-row, đẹp khi
demo và khi bàn giao.

Nhưng **bài test A1 thực tế chạy bằng logical replication**, vì lúc đó chưa có
quyền DMS. Kết quả: downtime **1,1 giây**, 3.587 đơn khớp hai đầu, 0 đơn trùng.

`pg_dump` loại vì không có CDC — phải khoá ghi suốt thời gian dump, không đạt
downtime ≤ 15 phút với dữ liệu thật.

**AWS MGN loại** vì nó tạo instance nằm ngoài Terraform → xung đột trực tiếp với
ràng buộc #8 *"dựng lại từ hồ sơ bàn giao"*. Chỉ migrate **dữ liệu**, còn compute
thì dựng lại bằng IaC.

---

## 9. Chép file: DataSync agentless

**Đối thủ:** DataSync có agent · `rsync` · Storage Gateway

**Chọn DataSync S3 → EFS vì không cần agent.** Agent chỉ bắt buộc khi nguồn là
NFS/SMB tự quản. Cả hai đầu đều là dịch vụ AWS nên DataSync chạy thẳng.

Hệ quả: phần file gần như **miễn phí** — tính theo GB truyền, không tính giờ
instance.

`rsync` làm được nhưng thủ công và không có báo cáo đối chiếu.

**`posix_permissions = PRESERVE` là bắt buộc.** Không có nó, mọi file sang EFS
thuộc về cùng một owner và toàn bộ phân quyền phòng ban thành vô nghĩa.

---

## 10. Mật khẩu: Secrets Manager **và** SSM Parameter Store

Không phải chọn một, mà dùng **cả hai cho hai người dùng khác nhau**:

| | Ai đọc | Vì sao |
|---|---|---|
| SSM Parameter Store SecureString | **Ứng dụng** | Miễn phí ở Standard tier, đọc nhiều |
| Secrets Manager | **RDS Proxy** | Proxy **không hỗ trợ** Parameter Store |

Nếu chỉ dùng Secrets Manager: 0,40 USD mỗi secret mỗi tháng cộng phí gọi, mà
ứng dụng đọc rất nhiều lần.

Nếu chỉ dùng Parameter Store: RDS Proxy không dựng được.

Mật khẩu do `random_password` sinh lúc apply, không ai gõ vào file, không đi qua
Git.

---

## 11. Mã hoá: dùng AWS managed key, không tạo CMK

| | CMK tự quản | AWS managed (`alias/aws/*`) | AWS owned |
|---|---|---|---|
| Mã hoá at-rest | có | có | có |
| Chi phí | 1 USD/tháng + request | **0** | 0 |
| Sửa key policy | **có** | không | không |
| Xoay vòng | tự đặt, 1 năm | AWS tự, 3 năm | AWS lo |
| Thấy trong Console | có | có | **không** |
| Một key chung nhiều dịch vụ | **có** | không | không |

**CMK hơn ở dòng cuối.** Key mặc định không chia sẻ được giữa các dịch vụ, nên
IAM policy phải cấp `kms:Decrypt` trên `*` kèm điều kiện `kms:ViaService` cho
từng dịch vụ. Một CMK dùng chung thì **một dòng trên đúng một ARN** là đủ cho
RDS, SQS, S3, EFS, SSM, Secrets Manager, DynamoDB.

**Vẫn chọn AWS managed key, và đã gỡ hẳn CMK khỏi Terraform.** Ba lý do, đều rút
ra từ lần dựng thật:

1. CMK không chỉ cần `kms:CreateKey`. Nó kéo theo `kms:TagResource`,
   `kms:EnableKeyRotation`, `kms:Encrypt`, và mỗi quyền thiếu lại chặn ở một
   bước khác nhau — phải xin bốn lần mới đi hết.
2. **Không xoá lại được.** Xoá CMK cần `kms:ScheduleKeyDeletion`, quyền này
   không nằm trong nhóm tạo key. Lần dựng thật ngày 12/09/2026 để lại hai key
   mồ côi không tự dọn được, mỗi key 1 USD/tháng. Xem `noi-bo/quyen-aws-can-cap.md`.
3. Dữ liệu vẫn được mã hoá at-rest như nhau. Cái mất là khả năng tự sửa key
   policy và dùng chung một key — không phải mức bảo mật.

Lý do bỏ hẳn thay vì để cờ bật tắt: một cờ không ai bật, mà bật lên thì để lại
rác không dọn được, chỉ làm mã và tài liệu nặng thêm. Cần CMK thì thêm lại
`aws_kms_key` vào `modules/iam` và truyền ARN xuống — khoảng 20 dòng.

Đánh đổi phải chấp nhận: không có ARN cố định để trỏ vào, nên `kms:Decrypt`
trong policy của instance role cấp trên `*`, kèm điều kiện `kms:ViaService` giới
hạn còn đúng bốn dịch vụ `ssm`, `sqs`, `dynamodb`, `s3`. Rộng hơn trỏ một ARN,
nhưng role không dùng được key nào ngoài bốn dịch vụ đó.

Đã dựng thật cả hai chế độ, đều chạy. Bản giữ lại là bản không CMK.

---

## 12. IaC: Terraform

**Đối thủ:** CloudFormation · AWS CDK · Pulumi

| | Terraform | CloudFormation | CDK |
|---|---|---|---|
| Đa nhà cung cấp | có | chỉ AWS | chỉ AWS |
| Xem trước thay đổi | `plan` rõ ràng | change set | qua `cdk diff` |
| Phải biết ngôn ngữ lập trình | không (HCL) | không (YAML) | **có** |
| Quản state | tự quản (S3) | AWS quản | AWS quản |

**Chọn Terraform vì** `plan` đọc dễ, và không khoá vào một nhà cung cấp. Đây
cũng là công cụ phổ biến nhất trong ngành nên tài liệu bàn giao ai cũng đọc được.

CloudFormation có lợi thế là AWS quản state hộ, nhưng cú pháp YAML dài dòng và
`plan` kém rõ ràng hơn.

CDK mạnh khi hạ tầng phức tạp cần vòng lặp và điều kiện, nhưng bắt người đọc
biết TypeScript/Python — trái với mục tiêu "ai cũng dựng lại được".

---

## 13. Những thứ đã chủ động BỎ

| Bỏ | Lý do |
|---|---|
| **Cognito** | Yêu cầu **không nhắc tới đăng nhập**. Người nhập đơn là nhân viên nội bộ, nhập thay khách. Không có khách tự đăng nhập |
| **ECR + Docker** | Ứng dụng là một tiến trình Python. Cài Docker daemon lên mỗi máy chỉ để chạy một tiến trình là thừa |
| **X-Ray** | Correlation id trong log đã đủ truy vết một giao dịch. X-Ray thêm giá trị khi có hàng chục microservice |
| **WAF** | Ngoài phạm vi 2 tuần, thêm ~21 USD/tháng. Khuyến nghị giai đoạn sau |
| **GuardDuty, Security Hub** | Như trên |
| **Synthetics canary** | Chạy 1 phút/lần, **không đủ phân giải** cho ngân sách gián đoạn 2 phút. Dùng vòng lặp curl 1 giây/lần thay thế |
| **Read replica** | Bị SCP chặn ở cấp Organization. Báo cáo chạy trên primary với mốc chốt tường minh, đo được p95 61 ms |
| **VPC Interface Endpoint** | 3 endpoint × 2 AZ ≈ 44 USD/tháng, **đắt hơn cả NAT Gateway** ở quy mô này |
| **NAT thứ hai** | Tiết kiệm 43 USD/tháng. Đánh đổi: mất đường **ra** internet nếu AZ chứa NAT chết. Traffic **vào** đi qua ALB nên nhận đơn không ảnh hưởng |

---

# PHẦN B — PHÂN BIỆT NHỮNG THỨ HAY LẪN

## Multi-AZ vs Read Replica

| | Multi-AZ | Read Replica |
|---|---|---|
| Mục đích | **Sẵn sàng cao** | **Mở rộng đọc** |
| Đồng bộ | đồng bộ, RPO = 0 | bất đồng bộ, chậm vài giây |
| Đọc được từ standby | **không** | có |
| Tự chuyển khi hỏng | có | không, phải promote tay |

Hay bị hỏi: *"có Multi-AZ rồi sao còn cần replica?"* — Multi-AZ standby **không
phục vụ đọc**, nó chỉ nằm chờ. Muốn giảm tải đọc phải có replica.

## SQS FIFO vs Standard

| | FIFO | Standard |
|---|---|---|
| Thứ tự | giữ, trong message group | **không đảm bảo** |
| Số lần giao | đúng một lần (cửa sổ 5 phút) | **ít nhất một lần** |
| Thông lượng | 3.000 msg/s per group | không giới hạn |
| Tên queue | phải kết thúc `.fifo` | tự do |

## ALB vs NLB

| | ALB | NLB |
|---|---|---|
| Tầng OSI | 7 | 4 |
| Hiểu HTTP | có | không |
| Định tuyến theo path/host | có | **không** |
| Health check | HTTP, kiểm nội dung | chỉ TCP |
| IP tĩnh | không | **có** |

## Security Group vs Network ACL

| | Security Group | NACL |
|---|---|---|
| Gắn vào | ENI (máy) | subnet |
| Có nhớ trạng thái | **có** — cho vào thì tự cho ra | **không** — phải mở cả hai chiều |
| Luật deny | không có | **có** |
| Thứ tự luật | không, gộp tất cả | có, theo số |

Dự án này chỉ dùng Security Group. NACL hợp khi cần chặn một dải IP cụ thể ở
tầng subnet.

## Identity policy vs SCP vs Resource policy

| | Gắn vào | Ai sửa được |
|---|---|---|
| Identity policy | user, role | IT của account |
| **SCP** | tài khoản trong Organization | **chỉ account quản lý Organization** |
| Resource policy | chính tài nguyên (S3, KMS, SQS…) | ai có quyền trên tài nguyên |

Đọc error message để phân biệt:

```
"no identity-based policy allows the ... action"     → thiếu quyền, xin IT là có
"explicit deny in a service control policy"          → SCP chặn, IT account bó tay
```

Đây là thứ giúp biết cái nào đáng giục, cái nào phải tìm đường vòng.

## `/health` vs `/ready`

| | `/health` | `/ready` |
|---|---|---|
| Kiểm gì | có tới được database không | tiến trình còn nhận request không |
| Gắn vào target group | **không** | **có** |
| Dùng để | chẩn đoán tay, nguồn alarm | ALB quyết định gửi traffic |

Gắn nhầm `/health` vào target group: database chết → mọi máy rớt health check →
ASG giết sạch → máy mới cũng hỏng y hệt.

## AWS managed key vs AWS owned key vs CMK

| | Thấy trong Console | Có ARN | Sửa key policy | Tiền |
|---|---|---|---|---|
| CMK | có | có | **có** | 1 USD/tháng |
| AWS managed (`alias/aws/*`) | có | có | không | 0 |
| AWS owned | **không** | **không** | không | 0 |

DynamoDB mặc định dùng **AWS owned** — nên `SSEDescription` trả về `null`. Đó
không phải tắt mã hoá, chỉ là không có gì để báo cáo.

## RPO vs RTO

| | Nghĩa | Ngưỡng yêu cầu | Cách đạt |
|---|---|---|---|
| **RPO** | Mất tối đa bao nhiêu **dữ liệu** | ≤ 5 phút | Multi-AZ (RPO 0) + PITR chi tiết 5 phút |
| **RTO** | Mất tối đa bao lâu **khôi phục dịch vụ** | ≤ 30 phút | Failover tự động 60–120 giây |

Hay bị lẫn: RPO tính bằng **dữ liệu**, RTO tính bằng **thời gian**.

## p95 vs trung bình

100 request: 95 cái 100 ms, 5 cái 10 giây.

```
Trung bình = 595 ms   → nghe ổn
p95        = 100 ms
p99        = 10 giây  → 1% người dùng đang chờ 10 giây
```

Trung bình **giấu** phần đuôi. Yêu cầu đặt ngưỡng theo p95 chính vì vậy.

## Inline policy vs Managed policy

| | Inline | Managed |
|---|---|---|
| Thuộc về | đúng một role | độc lập, gắn nhiều role |
| API tạo | `PutRolePolicy` | `CreatePolicy` + `AttachRolePolicy` |
| Xoá role thì sao | mất theo | vẫn còn |

Dự án dùng **inline** cho quyền riêng, và gắn **managed policy có sẵn của AWS**
(`AmazonSSMManagedInstanceCore`, `CloudWatchAgentServerPolicy`) cho phần chung.
Nên **không cần `iam:CreatePolicy`**.

## Warm pool vs Scheduled scaling

| | Warm pool | Scheduled scaling |
|---|---|---|
| Phản ứng với | tải tăng bất ngờ | giờ giấc biết trước |
| Chi phí | chỉ tiền EBS (~0,6 USD/tháng) | trả full giờ máy |
| Độ trễ | 30–40 giây | 0, đã chạy sẵn |

Chọn warm pool vì cao điểm của khách **không cố định giờ**.

## EFS Access Point vs phân quyền POSIX thường

| | Access Point | POSIX trên OS |
|---|---|---|
| Ai quyết định danh tính | **AWS, phía server** | tiến trình trên máy client |
| `root` trên EC2 vượt được không | **không** | **có** |
| Thu hồi quyền | xoá access point chặn mount mới ngay | sửa group, phiên đang mở vẫn giữ quyền cũ |
| Phiên đang mở | **cũng không cắt được** (đo 283 giây) | không cắt được |

Access point ăn điểm ở vế **danh tính**: quyền không do máy con tự khai, `root` trên
EC2 cũng không vượt được. Nhưng nó không tự mình đáp ứng vế **5 phút**.

Đo thật ngày 12/09/2026 (`evidence/aws-A6-efs-revoke-*.log`): xoá access point rồi,
mount đang mở vẫn đọc ghi bình thường suốt 283 giây. EFS xét access point lúc mount,
không xét lại ở từng thao tác I/O. Nên quy trình thu hồi phải là **xoá access point +
ép `umount -f` qua SSM**, xem `migration/file-server.md`.
