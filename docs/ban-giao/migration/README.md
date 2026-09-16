# Migration

Hai phần độc lập, làm song song được:

| Phần | Nguồn → Đích | Công cụ | Tài liệu |
|---|---|---|---|
| **Database** | PostgreSQL on-premise → RDS | DMS (dự phòng: logical replication) | [`database.md`](database.md) |
| **File server** | File server on-premise → EFS | AWS CLI + DataSync | [`file-server.md`](file-server.md) |

## Ràng buộc phải đạt

| Phần | Ràng buộc | Ngưỡng | Đo được |
|---|---|---|---|
| Database | #2 | Downtime ≤ 15 phút, 0 mất, 0 trùng | **1,1 giây**, 3.587 đơn khớp |
| File server | #7 | Giữ nguyên quyền phòng ban, thu hồi ≤ 5 phút | **30/30** phép thử |

## Điểm chung của hai phần

Cả hai đều theo cùng một nguyên tắc: **chép phần nặng trước lúc hệ thống còn
chạy, chỉ khoá ở phút cuối để chép phần chênh**.

Khác nhau ở mức rủi ro:

| | Database | File server |
|---|---|---|
| Dữ liệu đổi liên tục | có, từng giây | ít |
| Rollback | khó sau khi đổi connection string | dễ, nguồn cũ vẫn nguyên |
| Bẫy lớn nhất | **quên đặt lại sequence** | **mất quyền POSIX khi chép** |

## Thứ tự làm

```
1. File server trước   rủi ro thấp, rollback dễ, làm quen quy trình
2. Database sau        rủi ro cao, cần cửa sổ bảo trì
```

Làm file server trước để cả nhóm quen nhịp cutover trước khi động vào phần khó.
