#!/bin/sh
# Khởi tạo read replica bằng streaming replication.
#
# Chỉ dùng cho môi trường LOCAL. Trên AWS, read replica được tạo bằng một
# resource `aws_db_instance` với `replicate_source_db` — không cần script.
set -e

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "replica: chưa có data, chạy pg_basebackup từ primary..."
  until pg_basebackup -h "${PRIMARY_HOST:-db}" -p "${PRIMARY_PORT:-5432}" \
        -U "${PGUSER:-abcapp}" -D "$PGDATA" -Fp -Xs -R -w; do
    echo "replica: primary chưa sẵn sàng, thử lại sau 2s"
    sleep 2
  done
  chmod 0700 "$PGDATA"
  echo "replica: basebackup xong"
fi

exec postgres -c hot_standby=on
