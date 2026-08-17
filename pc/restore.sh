#!/bin/sh
# restore.sh — upload a local snapshot and run router rollback.
#
# Usage: pc/restore.sh [snapshot] [options]. Snapshot may be a name or tar.gz path;
# omitting it selects the newest local snapshot.
#
# Script options: --list, --yes, and -h/--help.
#
# Shared options (see _lib.sh): --conf FILE, --host HOST, --user USER, --port PORT,
#   --key FILE, --remote-dir DIR, --backup-dir DIR, --local-dir DIR
# Precedence: CLI arguments, config file, defaults. A config file is optional with --host.
#
# Examples:
#   pc/restore.sh --list
#   pc/restore.sh                                # newest snapshot, ask for confirmation
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

# Resolve the requested snapshot.
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

# 1) Upload and extract into the router backup directory.
log "Đẩy $NAME lên router..."
rssh "cat > /tmp/sb-restore.tar.gz" < "$FILE"
rssh "mkdir -p '$REMOTE_BACKUP_DIR' && tar xzf /tmp/sb-restore.tar.gz -C '$REMOTE_BACKUP_DIR' && rm -f /tmp/sb-restore.tar.gz"

# 2) Run project rollback and reload affected services.
log "Chạy rollback trên router..."
rssht "SB_YES=1 sh '$REMOTE_DIR/scripts/rollback.sh' '$NAME'"

log "KHÔI PHỤC XONG. Kiểm tra lại mạng/WiFi. Nếu mất kết nối SSH, xem docs/ROLLBACK.md."
