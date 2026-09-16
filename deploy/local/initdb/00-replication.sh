#!/bin/bash
# Cho phép streaming replication từ container replica.
# CHỈ dùng cho môi trường local. Trên AWS, read replica do RDS quản lý và
# xác thực bằng IAM/credential nội bộ, không cần đụng tới pg_hba.
set -e
{
  echo "host replication all all trust"
  echo "host all         all all trust"
} >> "$PGDATA/pg_hba.conf"
