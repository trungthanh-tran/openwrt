#!/bin/sh
# restore.sh — đẩy 1 bản backup từ máy này lên router và chạy rollback (khôi phục + reload dịch vụ).
#
# Dùng:
#   pc/restore.sh --list                         # liệt kê backup local
#   pc/restore.sh                                # khôi phục bản local MỚI NHẤT
#   pc/restore.sh 20260816-101500-pc             # theo tên (trong LOCAL_BACKUP_DIR)
#   pc/restore.sh /duong/dan/backup.tar.gz       # theo đường dẫn file
set -e
. "$(dirname "$0")/_lib.sh"

if [ "$1" = "--list" ]; then
  echo "Backup local trong $LOCAL_BACKUP_DIR:"
  FILES="$(ls -1t "$LOCAL_BACKUP_DIR"/*.tar.gz 2>/dev/null || true)"
  if [ -n "$FILES" ]; then
    echo "$FILES" | while read -r f; do printf '  %s\n' "$(basename "$f" .tar.gz)"; done
  else
    echo "  (chưa có — chạy pc/backup.sh trước)"
  fi
  exit 0
fi

# Xác định file backup
if [ -z "$1" ]; then
  FILE="$(ls -1t "$LOCAL_BACKUP_DIR"/*.tar.gz 2>/dev/null | head -n 1)"
  [ -n "$FILE" ] || die "Chưa có backup nào trong $LOCAL_BACKUP_DIR. Chạy pc/backup.sh trước."
elif [ -f "$1" ]; then
  FILE="$1"
elif [ -f "$LOCAL_BACKUP_DIR/$1.tar.gz" ]; then
  FILE="$LOCAL_BACKUP_DIR/$1.tar.gz"
else
  die "Không tìm thấy: $1. Xem danh sách: pc/restore.sh --list"
fi
NAME="$(basename "$FILE" .tar.gz)"

warn "Sẽ GHI ĐÈ cấu hình trên router $ROUTER_HOST bằng bản: $NAME"
printf "Tiếp tục? [y/N] "
read -r ans; case "$ans" in y|Y) : ;; *) die "Đã huỷ." ;; esac

# 1) Đẩy lên router và giải nén vào thư mục backup của router
log "Đẩy $NAME lên router..."
rssh "cat > /tmp/sb-restore.tar.gz" < "$FILE"
rssh "mkdir -p '$REMOTE_BACKUP_DIR' && tar xzf /tmp/sb-restore.tar.gz -C '$REMOTE_BACKUP_DIR' && rm -f /tmp/sb-restore.tar.gz"

# 2) Chạy rollback của repo (khôi phục file + reload network/dnsmasq/firewall/sing-box/wifi)
log "Chạy rollback trên router..."
rssht "SB_YES=1 sh '$REMOTE_DIR/scripts/rollback.sh' '$NAME'"

log "KHÔI PHỤC XONG. Kiểm tra lại mạng/WiFi. Nếu mất kết nối SSH, xem docs/ROLLBACK.md."
