#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Dựng nội dung File Server on-premise — nguồn cho AWS DataSync.
#
# Ràng buộc #7 yêu cầu giữ nguyên "nội dung, cấu trúc thư mục và quyền theo
# phòng ban" sau chuyển đổi. Muốn chứng minh được điều đó thì trước hết phải
# có một cây thư mục THẬT, có phân quyền THẬT để mà so sánh trước/sau.
#
# Yêu cầu cho phép thu nhỏ dung lượng: mặc định ~50 MB thay vì 500 GB, nhưng
# giữ nguyên số phòng ban, độ sâu thư mục và kiểu file.
# ---------------------------------------------------------------------------
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARE="${SHARE:-$ROOT/onprem/fileshare}"
SIZE_MB="${SIZE_MB:-50}"

DEPARTMENTS="sales finance hr production purchasing"

echo "dựng file share tại $SHARE (~${SIZE_MB} MB)"
rm -rf "$SHARE"
mkdir -p "$SHARE"

# Số file mỗi phòng ban, chia đều dung lượng mục tiêu.
FILES_PER_DEPT=$(( SIZE_MB * 1024 / 5 / 256 ))   # file ~256KB
[ "$FILES_PER_DEPT" -lt 4 ] && FILES_PER_DEPT=4

for dept in $DEPARTMENTS; do
  for sub in 2024 2025 templates archive; do
    mkdir -p "$SHARE/$dept/$sub"
  done

  # File "mật" để test A5: user phòng khác không được đọc.
  printf 'TÀI LIỆU NỘI BỘ PHÒNG %s\nKhông chia sẻ ra ngoài phòng ban.\n' \
    "$(echo "$dept" | tr '[:lower:]' '[:upper:]')" > "$SHARE/$dept/CONFIDENTIAL.txt"

  for i in $(seq 1 "$FILES_PER_DEPT"); do
    year=$([ $((i % 2)) -eq 0 ] && echo 2024 || echo 2025)
    f="$SHARE/$dept/$year/${dept}-doc-$(printf '%04d' "$i").dat"
    head -c 262144 /dev/urandom > "$f"
  done

  cat > "$SHARE/$dept/README.txt" <<EOF
Thư mục phòng $dept — ABC Manufacturing
Chỉ thành viên nhóm AD "$dept" được đọc/ghi.
Sinh lúc: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
done

mkdir -p "$SHARE/public"
echo "Thư mục dùng chung cho toàn công ty." > "$SHARE/public/README.txt"

echo
echo "cấu trúc:"
find "$SHARE" -maxdepth 2 -type d | sed "s|$SHARE|  .|" | sort
echo
echo "tổng: $(find "$SHARE" -type f | wc -l) file, $(du -sh "$SHARE" | cut -f1)"
echo
echo "Kiểm kê để đối chiếu SAU khi DataSync sang EFS:"
MANIFEST="$ROOT/evidence/fileshare-manifest.txt"
mkdir -p "$(dirname "$MANIFEST")"
( cd "$SHARE" && find . -type f -exec md5sum {} \; | sort -k2 ) > "$MANIFEST"
echo "  đã ghi $(wc -l < "$MANIFEST") dòng checksum vào ${MANIFEST#"$ROOT"/}"
echo "  sau migration chạy lại lệnh này trên đích rồi 'diff' hai file —"
echo "  giống hệt nhau = giữ nguyên nội dung và cấu trúc thư mục."
echo
echo "Quyền theo phòng ban do container onprem-files đặt (group + mode 2770),"
echo "xem deploy/local/fileserver-entrypoint.sh. Kiểm tra bằng:"
echo "  ./scripts/test-a5-fileshare-perms.sh"
