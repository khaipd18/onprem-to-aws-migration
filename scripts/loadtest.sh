#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Chạy test chịu tải B1 bằng k6 trong Docker (không cần cài k6 lên máy).
#
#   bash scripts/loadtest.sh                # bản smoke ~2.5 phút, để kiểm tra script
#   PROFILE=full bash scripts/loadtest.sh   # bản đầy đủ: 50 -> 250 req/s trong 30 phút
#   PEAK_RPS=100 bash scripts/loadtest.sh   # hạ tải nếu máy local không kham nổi
#
# Lưu ý khi chạy trên AWS: đặt load generator NGOÀI VPC (một EC2 c6i.large ở
# region khác, hoặc máy cá nhân) để không tự làm nhiễu kết quả đo.
# ---------------------------------------------------------------------------
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BASE_URL="${BASE_URL:-http://localhost:8080}"
PROFILE="${PROFILE:-smoke}"
NORMAL_RPS="${NORMAL_RPS:-50}"
PEAK_RPS="${PEAK_RPS:-250}"
PEAK_MIN="${PEAK_MIN:-30}"

mkdir -p "$ROOT/evidence"

echo "chạy k6 — profile=$PROFILE, ${NORMAL_RPS} -> ${PEAK_RPS} req/s, target $BASE_URL"
[ "$PROFILE" = "full" ] && echo "bản đầy đủ mất khoảng $((PEAK_MIN + 8)) phút"

# --user để file kết quả thuộc về người chạy chứ không phải root/uid của image.
docker run --rm --network host \
  --user "$(id -u):$(id -g)" \
  -v "$ROOT/loadtest/k6:/scripts:ro" \
  -v "$ROOT/evidence:/home/k6/evidence" \
  -w /home/k6 \
  -e BASE_URL="$BASE_URL" -e PROFILE="$PROFILE" \
  -e NORMAL_RPS="$NORMAL_RPS" -e PEAK_RPS="$PEAK_RPS" -e PEAK_MIN="$PEAK_MIN" \
  grafana/k6 run /scripts/order-load.js

echo
echo "bằng chứng đã ghi:"
ls -la "$ROOT/evidence"/b1-load-test.* 2>/dev/null || echo "  (không có file nào)"
