#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Đóng gói giao diện thành bundle tĩnh để đẩy lên S3.
#
# Trên AWS, CloudFront phục vụ bundle này ở đường dẫn gốc và chuyển tiếp /api/*
# về ALB. Trình duyệt gọi cùng một origin nên không cần CORS.
#
# Ở local, Web tier đóng đúng vai đó: phục vụ vỏ trang và /static/*, chuyển
# tiếp /api/* xuống App tier. Nhờ vậy bộ test chạy ở local kiểm chứng đúng hợp
# đồng mà trình duyệt sẽ thấy trên AWS.
#
#   ./scripts/build-spa.sh
# ---------------------------------------------------------------------------
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/app/web"
OUT="${OUT:-$ROOT/build/spa}"

[ -f "$SRC/ui.html" ] || { echo "khong thay $SRC/ui.html"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

# Điểm vào phải tên index.html: đó là default_root_object của CloudFront.
cp "$SRC/ui.html" "$OUT/index.html"

if [ -d "$SRC/static" ]; then
  mkdir -p "$OUT/static"
  cp -r "$SRC/static/." "$OUT/static/"
fi

FILES=$(find "$OUT" -type f | wc -l)
SIZE=$(du -sh "$OUT" | cut -f1)

echo "da dong goi vao ${OUT#"$ROOT"/}"
echo "  $FILES file, $SIZE"
echo
find "$OUT" -maxdepth 2 -type d | sed "s|$OUT|  .|" | sort
echo
echo "Terraform doc thu muc nay qua bien assets_dir:"
echo "  cd deploy/terraform && terraform plan -var assets_dir=../../build/spa"
