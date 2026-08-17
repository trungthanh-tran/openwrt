#!/bin/sh
# restore.sh — đẩy 1 bản backup từ máy này lên router và chạy rollback (khôi phục + reload dịch vụ).
#
# Dùng:
#   pc/restore.sh [bản-backup] [tuỳ chọn]
#     bản-backup: tên (trong LOCAL_BACKUP_DIR) hoặc đường dẫn file .tar.gz.
#                 Bỏ trống = bản local MỚI NHẤT.
#
# Tuỳ chọn riêng:
#   --list            Liệt kê backup local rồi thoát
#   --yes             Không hỏi xác nhận (cho script/tự động hoá)
#   -h, --help        In hướng dẫn
#
# Tuỳ chọn chung (xem _lib.sh): --conf FILE, --host HOST, --user USER, --port PORT,
#   --key FILE, --remote-dir DIR, --backup-dir DIR, --local-dir DIR
# Ưu tiên: tham số dòng lệnh > file config (pc/sbproxy-pc.conf) > mặc định.
# Không cần file config nếu đã truyền --host.
#
# Ví dụ:
#   pc/restore.sh --list
#   pc/restore.sh                                # bản mới nhất, hỏi xác nhận
#   pc/restore.sh 20260816-101500-pc
#   pc/restore.sh /backup/router.tar.gz --host 192.168.8.1 --yes
set -e
. "$(dirname "$0")/_lib.sh"

usage() { awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; }

BACKUP=""; LIST=0; YES=0
while [ $# -gt 0 ]; do
  sbpc_try_common "$1" "${2:-}"
  if [ "$SBPC_CONSUMED" -gt 0 ]; then shift "$SBPC_CONSUMED"; continue; fi
  case "$1" in
    --list)    LIST=1; shift ;;
    --yes)     YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "Tham số lạ: $1 — xem: pc/restore.sh --help" ;;
    *)  [ -z "$BACKUP" ] || die "Chỉ nhận 1 bản backup (đã có: $BACKUP, thừa: $1)"
        BACKUP="$1"; shift ;;
  esac
done
sbpc_init

if [ "$LIST" = "1" ]; then
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
if [ -z "$BACKUP" ]; then
  FILE="$(ls -1t "$LOCAL_BACKUP_DIR"/*.tar.gz 2>/dev/null | head -n 1)"
  [ -n "$FILE" ] || die "Chưa có backup nào trong $LOCAL_BACKUP_DIR. Chạy pc/backup.sh trước."
elif [ -f "$BACKUP" ]; then
  FILE="$BACKUP"
elif [ -f "$LOCAL_BACKUP_DIR/$BACKUP.tar.gz" ]; then
  FILE="$LOCAL_BACKUP_DIR/$BACKUP.tar.gz"
else
  die "Không tìm thấy: $BACKUP. Xem danh sách: pc/restore.sh --list"
fi
NAME="$(basename "$FILE" .tar.gz)"

warn "Sẽ GHI ĐÈ cấu hình trên router $ROUTER_HOST bằng bản: $NAME"
if [ "$YES" != "1" ]; then
  printf "Tiếp tục? [y/N] "
  read -r ans; case "$ans" in y|Y) : ;; *) die "Đã huỷ." ;; esac
fi

# 1) Đẩy lên router và giải nén vào thư mục backup của router
log "Đẩy $NAME lên router..."
rssh "cat > /tmp/sb-restore.tar.gz" < "$FILE"
rssh "mkdir -p '$REMOTE_BACKUP_DIR' && tar xzf /tmp/sb-restore.tar.gz -C '$REMOTE_BACKUP_DIR' && rm -f /tmp/sb-restore.tar.gz"

# 2) Chạy rollback của repo (khôi phục file + reload network/dnsmasq/firewall/sing-box/wifi)
log "Chạy rollback trên router..."
rssht "SB_YES=1 sh '$REMOTE_DIR/scripts/rollback.sh' '$NAME'"

log "KHÔI PHỤC XONG. Kiểm tra lại mạng/WiFi. Nếu mất kết nối SSH, xem docs/ROLLBACK.md."
