#!/usr/bin/env bash
# Dừng môi trường. Thêm --volumes để xoá luôn dữ liệu.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
if [ "${1:-}" = "--volumes" ]; then
  say "dừng và XOÁ toàn bộ dữ liệu"
  $COMPOSE --profile onprem --profile tools down -v
else
  say "dừng (giữ nguyên dữ liệu)"
  $COMPOSE --profile onprem --profile tools down
fi
