# Migration file server

File server on-premise → EFS, **giữ nguyên nội dung, cấu trúc thư mục và quyền
theo phòng ban**. Thu hồi quyền phải có hiệu lực trong 5 phút.

Viết cho người chưa từng làm migration bao giờ.

---

## 1. Khó ở chỗ nào

Chép file thì dễ. Cái khó là **chép kèm quyền**.

Một file trên Linux mang ba thứ:

```
-rw-rw----  1  sales_user  sales  4096  don-hang-thang-9.xlsx
   │           │           │
   │           │           └── group   phòng ban nào sở hữu
   │           └────────────── owner   ai tạo ra
   └────────────────────────── mode    ai được đọc, ghi
```

Chép bằng `cp` hay kéo thả thì **ba thứ đó biến thành của người chép**. Mọi file
thành cùng một owner, phòng ban nào cũng đọc được file phòng khác — mất hoàn toàn
phân quyền.

Đây chính là ràng buộc #7 của yêu cầu, và là phần dễ làm hỏng nhất.

### Một chi tiết nữa: bit setgid

Thư mục phòng ban đặt mode `2770`, số `2` đầu là **setgid**. Nó khiến file tạo
mới trong thư mục **tự thuộc về group của thư mục**, không phải group của người
tạo.

Không có bit này thì hôm nay chép đúng, nhưng file tạo ngày mai lại sai group.

---

## 2. Ba cách chép, chọn cái nào

| | `cp` / kéo thả | `rsync -a` | **DataSync** |
|---|---|---|---|
| Giữ owner, group, mode | **không** | có | có |
| Giữ setgid | không | có | có |
| Báo cáo đối chiếu | không | không | **có** |
| Tự thử lại khi lỗi mạng | không | một phần | có |
| Chạy song song nhiều luồng | không | không | có |
| Chi phí | 0 | 0 | 0,0125 USD/GB |

**Chọn DataSync** vì hai cột cuối cùng: có báo cáo đối chiếu để làm bằng chứng
bàn giao, và tự thử lại.

`rsync -a` làm được phần quyền, nhưng chạy một luồng, và khi đứt mạng giữa chừng
thì phải tự biết chỗ dừng.

---

## 3. Kiến trúc: vì sao không cần agent

DataSync thường cần một **agent** — máy ảo cài ở phía nguồn để đọc dữ liệu.

Nhưng agent chỉ bắt buộc khi nguồn là **NFS hoặc SMB tự quản**. Nếu nguồn đã là
dịch vụ AWS thì DataSync đọc thẳng.

Cách làm ở đây, chia hai chặng:

```
Chặng 1    file server on-premise  ──▶  S3          (dùng AWS CLI)
Chặng 2    S3                      ──▶  EFS         (DataSync, không cần agent)
```

**Lợi:** không phải dựng EC2 agent. Chi phí phần file gần như bằng 0 — DataSync
tính theo GB truyền, không tính giờ instance.

**Đánh đổi:** chặng 1 phải tự làm, và **S3 không giữ được quyền POSIX** (nó không
phải filesystem). Nên phải xuất quyền ra một file riêng rồi phục hồi sau — xem
mục 5.

### Khi nào dùng agent thay vì hai chặng

Nếu có VPN hoặc Direct Connect tới on-premise thì dựng agent chép thẳng
NFS → EFS, giữ nguyên quyền suốt đường, không phải xuất phục hồi. Sạch hơn nhưng
tốn thêm một EC2.

---

## 4. Chuẩn bị

### 4.1 Kiểm kê phía nguồn

Trước khi chép, ghi lại hiện trạng để sau này đối chiếu:

```bash
# danh sách file kèm quyền, owner, group
find /srv/fileserver -printf '%p|%u|%g|%m|%s\n' | sort > manifest-nguon.txt

# checksum từng file, bắt được lỗi nội dung
find /srv/fileserver -type f -exec md5sum {} \; | sort > checksum-nguon.txt

# bản đồ uid/gid
getent passwd | awk -F: '$3>=1000 {print $1":"$3}' > users-nguon.txt
getent group  | awk -F: '$3>=1000 {print $1":"$3}' > groups-nguon.txt
```

**Đây là bằng chứng.** Không có nó thì sau khi chép không chứng minh được là
đúng.

### 4.2 Thống nhất uid/gid hai đầu

Quyền POSIX lưu bằng **số**, không phải tên. Nếu nguồn có `sales` là gid 5001 mà
đích lại là 5007 thì file thành của nhầm phòng.

Bản đồ đã chốt trong dự án:

| Phòng ban | uid | gid |
|---|---|---|
| sales | 6001 | 5001 |
| finance | 6002 | 5002 |
| hr | 6003 | 5003 |
| production | 6004 | 5004 |
| purchasing | 6005 | 5005 |
| dùng chung | 6000 | 5000 |

Giống hệt `deploy/local/fileserver-entrypoint.sh` của môi trường nguồn, nên đối
chiếu trực tiếp được.

### 4.3 Dựng EFS và access point

Terraform lo phần này (`modules/fileserver`). Kết quả:

```
/sales       uid 6001  gid 5001  mode 0770
/finance     uid 6002  gid 5002  mode 0770
/hr          uid 6003  gid 5003  mode 0770
/production  uid 6004  gid 5004  mode 0770
/purchasing  uid 6005  gid 5005  mode 0770
/shared      uid 6000  gid 5000  mode 0770 + secondary_gids = cả 5 phòng
```

---

## 5. Chặng 1 — đưa file lên S3

### 5.1 Xuất quyền ra file trước

S3 không giữ quyền POSIX, nên phải xuất riêng:

```bash
cd /srv/fileserver
find . -printf '%p|%u|%g|%m\n' > /tmp/quyen.txt
```

File này sẽ dùng để phục hồi quyền ở mục 6.

### 5.2 Chép lên S3

```bash
aws s3 sync /srv/fileserver s3://<bucket-trung-gian>/fileserver/ \
  --storage-class STANDARD

aws s3 cp /tmp/quyen.txt s3://<bucket-trung-gian>/quyen.txt
```

`s3 sync` chạy lại được nhiều lần — chỉ chép file đã đổi. Nên chạy lần đầu sớm,
rồi chạy lại ngay trước cutover để bắt file mới.

---

## 6. Chặng 2 — DataSync S3 → EFS

### 6.1 Hai location

| | Cấu hình |
|---|---|
| Source | S3 bucket trung gian, prefix `fileserver/` |
| Target | EFS file system, **qua access point hoặc thư mục gốc** |

DataSync cần một IAM role để đọc S3 — đặt tên theo prefix `abc-migration-*`
cho khớp quyền đã cấp.

### 6.2 Task — ba tuỳ chọn quyết định

| Tuỳ chọn | Giá trị | Không đặt thì sao |
|---|---|---|
| **POSIX permissions** | **`PRESERVE`** | Mọi file cùng một owner, mất phân quyền |
| **User/Group ID** | **`INT_VALUE`** | uid/gid bị dịch sai |
| Verify data | `POINT_IN_TIME_CONSISTENT` | Không biết chép đủ chưa |

`PRESERVE` là tuỳ chọn quan trọng nhất của cả bài này.

### 6.3 Chạy

```bash
aws datasync start-task-execution --task-arn <arn>
```

Theo dõi: `FilesTransferred`, `BytesTransferred`, và trạng thái
`TRANSFERRING → VERIFYING → SUCCESS`.

### 6.4 Phục hồi quyền (vì đi qua S3)

Vì chặng 1 mất quyền, sau khi DataSync xong phải áp lại từ `quyen.txt`. Mount EFS
vào một EC2 rồi chạy:

```bash
sudo mount -t efs -o tls,iam <fs-id>:/ /mnt/efs

while IFS='|' read -r duongdan owner group mode; do
  target="/mnt/efs/${duongdan#./}"
  [ -e "$target" ] || continue
  chown "$owner:$group" "$target"
  chmod "$mode" "$target"
done < /tmp/quyen.txt
```

Rồi **đặt lại bit setgid** cho thư mục phòng ban:

```bash
for d in sales finance hr production purchasing shared; do
  chmod 2770 "/mnt/efs/$d"
done
```

> Nếu dùng agent chép thẳng NFS → EFS thì **bỏ được cả mục 6.4** — quyền giữ
> nguyên suốt đường.

---

## 7. Đối chiếu — bằng chứng giữ nguyên quyền

Mount EFS rồi sinh manifest giống hệt cách làm ở nguồn:

```bash
cd /mnt/efs
find . -printf '%p|%u|%g|%m|%s\n' | sort > manifest-dich.txt
find . -type f -exec md5sum {} \; | sort > checksum-dich.txt

diff manifest-nguon.txt manifest-dich.txt   # phải rỗng
diff checksum-nguon.txt checksum-dich.txt   # phải rỗng
```

`diff` rỗng nghĩa là **nội dung, owner, group, mode, kích thước đều khớp**.

### Thử quyền thật

Quan trọng hơn `diff`: thử xem phòng này có đọc được thư mục phòng kia không.

```bash
sudo -u sales_user ls /mnt/efs/sales       # phải được
sudo -u sales_user ls /mnt/efs/finance     # phải Permission denied
sudo -u sales_user touch /mnt/efs/hr/x     # phải Permission denied
```

`scripts/test-a5-fileshare-perms.sh` chạy 30 phép thử kiểu này, hiện **30/30 đạt**.

---

## 8. Thu hồi quyền trong 5 phút

Đây là phần thứ hai của ràng buộc #7, và là chỗ mô hình cũ làm không nổi.

### Vì sao POSIX thường không đủ

Bỏ user khỏi group thì **phiên đang mở vẫn giữ quyền cũ** — group membership được
phân giải lúc đăng nhập. Người dùng phải đăng xuất rồi đăng nhập lại.

Không kiểm soát được thời gian, nên không cam kết được 5 phút.

### Access point giải quyết thế nào

Access point **ép danh tính từ phía AWS**, không phải từ máy client:

| | POSIX trên OS | EFS Access Point |
|---|---|---|
| Ai quyết định danh tính | tiến trình trên máy client | **AWS, phía server** |
| `root` trên EC2 vượt được không | **có** | **không** |
| Thu hồi | sửa group, phiên cũ vẫn giữ quyền | xoá access point chặn mount mới ngay; phiên đang mount phải ép unmount |

Ba cách thu hồi và kết quả đo thật ngày 12/09/2026 (`evidence/aws-A6-efs-revoke-*.log`):

| Cách | Hiệu lực đo được |
|---|---|
| Xoá access point của phòng đó | Chặn mount mới ngay. **Không cắt được phiên đang mount** — đo 283 giây vẫn đọc ghi bình thường |
| Gỡ `elasticfilesystem:ClientMount`/`ClientWrite` khỏi IAM role | Chưa kiểm chứng trên AWS thật. IAM cũng xét lúc mount nên nhiều khả năng giống hàng trên |
| Gỡ security group của client khỏi rule 2049 | Cắt được, nhưng **kéo sập app tier**: NFS block chứ không lỗi, uvicorn treo, `/ready` quá hạn, ASG thay máy sau 13–52 giây |

Nguyên nhân hàng đầu tiên: NFS client giữ file handle đã mở, EFS kiểm access point ở
thời điểm **mount** chứ không kiểm lại ở từng thao tác đọc ghi.

**Quy trình thu hồi đúng để đạt ràng buộc #7 (≤ 5 phút):**

1. Xoá access point của phòng đó — chặn mọi mount mới.
2. Ép unmount trên các máy đang mount:

```bash
aws ssm send-command --profile abc-migration \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Name,Values=abc-migration-dev-app" \
  --parameters 'commands=["umount -f -l /mnt/sales || true"]'
```

Bước 2 mới là bước bảo đảm được 5 phút, vì nó chủ động chứ không chờ client tự
phát hiện. Đừng cam kết thời gian chỉ dựa vào bước 1.

### Hai điều kiện trong file system policy

Thiếu một là hỏng cả cơ chế:

| Điều kiện | Thiếu thì sao |
|---|---|
| `aws:SecureTransport = true` | Mount không mã hoá vẫn được chấp nhận |
| Bắt buộc có `elasticfilesystem:AccessPointArn` | **Máy có quyền IAM rộng mount thẳng thư mục gốc, đọc hết mọi phòng ban** |

Điều kiện thứ hai quan trọng nhất. Không có nó thì access point chỉ là gợi ý, ai
muốn bỏ qua cũng được.

---

## 9. Cutover file server

Nhẹ hơn database nhiều, vì file ít thay đổi hơn đơn hàng.

```
T-1 ngày   chạy s3 sync lần đầu, chép phần lớn dữ liệu
           chạy DataSync, phục hồi quyền, đối chiếu

T+0        thông báo người dùng ngừng ghi vào file server cũ
           đặt thư mục nguồn thành chỉ đọc:
             chmod -R a-w /srv/fileserver

T+5        chạy s3 sync lần hai, chỉ chép file đổi trong ngày
T+10       chạy DataSync lần hai
T+15       phục hồi quyền cho file mới, đối chiếu lại
T+20       đổi điểm mount trên máy người dùng sang EFS
T+25       thử quyền theo phòng ban, mở lại cho ghi
```

**Chép hai lần là cố ý.** Lần đầu chép nặng lúc hệ thống còn chạy, lần hai chỉ
chép phần chênh nên rất nhanh.

---

## 10. Rollback

Dễ hơn database vì **nguồn cũ vẫn còn nguyên**.

```
1. Đổi điểm mount về lại file server cũ
2. Bỏ chế độ chỉ đọc:  chmod -R u+w /srv/fileserver
3. File tạo mới trên EFS sau cutover thì chép ngược về
```

Chỉ mất những file tạo mới trên EFS sau khi cutover — nên **giữ file server cũ ít
nhất một tuần**, đừng xoá ngay.

---

## 11. Sau khi xong

| Việc | Khi nào |
|---|---|
| Giữ file server cũ ở chế độ chỉ đọc | ít nhất 1 tuần |
| Xoá bucket S3 trung gian | sau khi đối chiếu xong |
| Bật lifecycle chuyển Infrequent Access | đã có sẵn, sau 30 ngày không truy cập |
| Kiểm AWS Backup cho EFS đã chạy chưa | ngày đầu |
| Lưu `manifest-*.txt` và `checksum-*.txt` | vĩnh viễn, đây là bằng chứng bàn giao |

Lifecycle sang IA giảm chi phí khoảng 90% cho file cũ. Hợp với file server: phần
lớn tài liệu ghi một lần rồi hiếm khi mở lại.
