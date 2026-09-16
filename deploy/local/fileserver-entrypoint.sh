#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File Server on-premise — Linux, phân quyền POSIX theo phòng ban.
#
# Đây là NGUỒN của ràng buộc #7: "giữ nguyên nội dung, cấu trúc thư mục và
# quyền theo phòng ban sau chuyển đổi". Muốn chứng minh giữ được quyền thì
# trước hết nguồn phải có quyền THẬT để mà đối chiếu.
#
# Cách phân quyền, ánh xạ thẳng sang EFS Access Point ở đích:
#
#   thư mục phòng ban   chown <dev>:<gid phòng>   chmod 2770
#     - group là phòng ban  -> chỉ thành viên phòng đó đọc/ghi được
#     - bit setgid (2)      -> file tạo mới thừa kế group, không rơi về group
#                              cá nhân rồi thành người khác đọc được
#     - other = 0           -> phòng khác không thấy gì
#
#   thư mục public      chmod 2775, group "congty" chứa cả 5 user
#
# Owner để nguyên UID của người phát triển (mặc định 1000) chứ không đổi sang
# root: thư mục này là bind mount từ máy host, đổi owner sang root thì trên
# host không sửa được nữa và scripts/make-fileshare.sh chạy lại sẽ hỏng.
# ---------------------------------------------------------------------------
set -euo pipefail

SHARE="${SHARE:-/share}"
OWNER_UID="${OWNER_UID:-1000}"

# gid cố định để quyền trên đĩa không đổi giữa các lần dựng lại container.
declare -A DEPT_GID=(
  [sales]=5001 [finance]=5002 [hr]=5003 [production]=5004 [purchasing]=5005
)
COMPANY_GID=5000

groupadd -g "$COMPANY_GID" congty 2>/dev/null || true

for dept in "${!DEPT_GID[@]}"; do
  gid="${DEPT_GID[$dept]}"
  uid=$((gid + 1000))
  groupadd -g "$gid" "$dept" 2>/dev/null || true
  useradd -u "$uid" -g "$gid" -G congty -M -s /bin/bash "${dept}_user" 2>/dev/null || true
done

echo "phan quyen theo phong ban tren $SHARE"
for dept in "${!DEPT_GID[@]}"; do
  [ -d "$SHARE/$dept" ] || continue
  chown -R "$OWNER_UID:${DEPT_GID[$dept]}" "$SHARE/$dept"
  chmod -R u=rwX,g=rwX,o= "$SHARE/$dept"
  find "$SHARE/$dept" -type d -exec chmod g+s {} +
  printf '  %-12s gid=%s  mode=2770\n' "$dept" "${DEPT_GID[$dept]}"
done

if [ -d "$SHARE/public" ]; then
  chown -R "$OWNER_UID:$COMPANY_GID" "$SHARE/public"
  chmod -R u=rwX,g=rwX,o=rX "$SHARE/public"
  find "$SHARE/public" -type d -exec chmod g+s {} +
  printf '  %-12s gid=%s  mode=2775\n' public "$COMPANY_GID"
fi

echo
echo "kiem tra:  docker exec -u sales_user abc-onprem-files ls /share/finance"
echo "           -> phai bao Permission denied"
echo
exec sleep infinity
