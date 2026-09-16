# Quy trình release Web/App

Đáp ứng mong đợi của khách hàng: *"có quy trình release Web/App nhanh và an toàn hơn"*.

Yêu cầu yêu cầu **ở mức khái niệm**:

> "Hiện thực hoá phương án giúp việc release Web/App nhanh và an toàn hơn ở mức khái niệm (concept) — **không yêu cầu pipeline hoàn chỉnh**, chỉ cần thể hiện đúng ý tưởng vận hành; tự lựa chọn công cụ phù hợp."

Tài liệu này mô tả quy trình đã **hiện thực hoá trong Terraform**, không phải ý tưởng trên giấy.

---

## 1. Hiện trạng và sau khi lên AWS

| | On-premise hiện tại | Sau khi lên AWS |
|---|---|---|
| Cách phát hành | Chép file lên server bằng tay | Đẩy artifact lên S3, thay instance |
| Số server phải đụng tay | 2 (Web, App) | 0 |
| Gián đoạn khi release | Có, người dùng thấy | Không, thay lần lượt |
| Biết đang chạy phiên bản nào | Hỏi người vừa deploy | `current.txt` trong S3 |
| Quay lui khi lỗi | Chép lại bản cũ, nếu còn giữ | Sửa một dòng, ~3 phút |
| Ba tiến trình lệch phiên bản | Có thể xảy ra | Không thể — dùng chung một artifact |
| Lỡ deploy bản hỏng | Người dùng phát hiện | Health check chặn, dừng rollout |

Yêu cầu mô tả hiện trạng là *"release thủ công, dễ sai sót và mất thời gian"*. Bảng trên là câu trả lời cho từng chữ đó.

---

## 2. Quy trình, 4 bước

### Bước 1 — Đóng gói, đặt tên theo mã commit

```bash
VERSION=$(git rev-parse --short HEAD)
tar czf app-$VERSION.tar.gz app/
aws s3 cp app-$VERSION.tar.gz s3://abc-migration-dev-artifacts/
```

Tên file mang mã commit nên artifact **bất biến**: cùng một tên luôn là cùng một nội dung. Không có chuyện "bản trên server khác bản trong git".

### Bước 2 — Trỏ phiên bản hiện hành

```bash
echo "$VERSION" > current.txt
aws s3 cp current.txt s3://abc-migration-dev-artifacts/current.txt
```

Một file duy nhất quyết định instance mới sẽ chạy bản nào. Muốn biết production đang chạy gì thì đọc file này, không phải đi hỏi.

### Bước 3 — Thay instance lần lượt

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name abc-migration-dev-web \
  --preferences MinHealthyPercentage=50,InstanceWarmup=120
```

Cấu hình đã đặt sẵn trong `modules/compute/asg.tf`:

```hcl
instance_refresh {
  strategy = "Rolling"
  preferences {
    min_healthy_percentage = 50
    instance_warmup        = 120
  }
}
```

Auto Scaling thay từng nhóm nhỏ, luôn giữ ít nhất **một nửa số instance đang phục vụ**. Người dùng không thấy gián đoạn.

### Bước 4 — Health check quyết định đi tiếp hay dừng

Nhóm dùng `health_check_type = "ELB"`. Instance mới phải qua được health check của target group thì mới được tính là khoẻ, và refresh mới đi tiếp.

Bản hỏng thì instance mới không bao giờ khoẻ → **refresh tự dừng, instance cũ vẫn phục vụ**. Đây là chỗ chữ "an toàn hơn" nằm.

---

## 3. Quay lui

```bash
echo "<mã commit cũ>" > current.txt
aws s3 cp current.txt s3://abc-migration-dev-artifacts/current.txt
aws autoscaling start-instance-refresh --auto-scaling-group-name abc-migration-dev-web
```

Khoảng 3 phút. Không cần build lại, không cần tìm lại bản cũ — artifact cũ vẫn nằm nguyên trong S3, bucket có bật versioning.

---

## 4. Bốn cơ chế làm nên chữ "an toàn"

| Cơ chế | Chặn được lỗi gì |
|---|---|
| Artifact bất biến, tên theo commit | Deploy nhầm bản, hoặc bản trên server khác bản trong git |
| Một artifact cho cả `web`, `app`, `worker` | Ba tiến trình chạy ba phiên bản khác nhau |
| Rolling + `min_healthy_percentage = 50` | Gián đoạn dịch vụ khi phát hành |
| Health check `ELB` gác cổng | Phát hành trọn vẹn một bản hỏng |

Ba tiến trình dùng chung một artifact, chỉ khác biến `TIER` trong user data — xem `modules/compute/templates/user-data.sh.tftpl`.

---

## 5. Cấu hình tách khỏi mã

Chuỗi kết nối, URL hàng đợi, mật khẩu database đều nằm ở **SSM Parameter Store**, đọc lúc instance khởi động:

```bash
DB_HOST=$(get db/host)
DB_PASSWORD=$(get db/password)     # SecureString, mã hoá bằng aws/ssm
```

Đổi cấu hình **không cần đóng gói lại**, chỉ cần thay instance. Và mã nguồn không bao giờ chứa bí mật.

---

## 6. Vì sao không dùng CodePipeline / CodeBuild / CodeDeploy

**Yêu cầu không yêu cầu:** *"không yêu cầu pipeline hoàn chỉnh, chỉ cần thể hiện đúng ý tưởng vận hành"*.

**Ngân sách:** tài khoản có trần 350 USD/tháng dùng chung với người khác. Xem `chi-phi.md`. Ba dịch vụ đó thêm chi phí cho một hạng mục mà yêu cầu đã nói là không cần làm đầy đủ.

**Không thêm gì về mặt an toàn ở phạm vi này:** bốn cơ chế ở mục 4 đã có đủ. CodeDeploy cho thêm blue/green và tự động quay lui theo alarm — đáng giá khi có nhiều người deploy mỗi ngày, không đáng ở một môi trường demo.

---

## 7. Nếu muốn tiến tới pipeline đầy đủ

Quy trình hiện tại là nền để thêm vào, không phải thứ phải bỏ đi:

| Thêm | Được gì |
|---|---|
| GitHub Actions + OIDC | Bước 1 và 2 chạy tự động khi merge. **Không cần access key** — OIDC đổi lấy vai trò tạm thời |
| CodeDeploy blue/green | Chuyển tải theo tỷ lệ, tự quay lui khi alarm kêu |
| Môi trường staging | Chạy `test-all.sh` trên staging trước khi chạm production |
| Ghim `.terraform.lock.hcl` vào git | Dựng lại ra đúng phiên bản provider — ràng buộc #8 |

Ba cái đầu cần thêm quyền và thêm chi phí. Cái thứ tư miễn phí, chỉ cần sửa một dòng trong `.gitignore`.
