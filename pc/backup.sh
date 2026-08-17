#!/bin/sh
# backup.sh — chạy backup trên router rồi KÉO snapshot về máy này.
# Snapshot lưu tại LOCAL_BACKUP_DIR dạng <timestamp>-<nhãn>.tar.gz, dùng lại được với pc/restore.sh.
#
# Dùng:
#   pc/backup.sh [nhãn] [tuỳ chọn]      # nhãn mặc định: "pc"
#
# Tuỳ chọn riêng:
#   -h, --help        In hướng dẫn
#
# Tuỳ chọn chung (xem _lib.sh): --conf FILE, --host HOST, --user USER, --port PORT,
#   --key FILE, --remote-dir DIR, --backup-dir DIR, --local-dir DIR
# Ưu tiên: tham số dòng lệnh > file config (pc/sbproxy-pc.conf) > mặc định.
# Không cần file config nếu đã truyền --host.
#
# Ví dụ:
#   pc/backup.sh                          # nhãn "pc", đọc pc/sbproxy-pc.conf
#   pc/backup.sh truoc-nang-cap
#   pc/backup.sh --host 192.168.8.1 --local-dir ~/router-backups
set -e
. "$(dirname "$0")/_lib.sh"

usage() { awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; }

LABEL=""
while [ $# -gt 0 ]; do
  sbpc_try_common "$1" "${2:-}"
  if [ "$SBPC_CONSUMED" -gt 0 ]; then shift "$SBPC_CONSUMED"; continue; fi
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -*) die "Tham số lạ: $1 — xem: pc/backup.sh --help" ;;
    *)  [ -z "$LABEL" ] || die "Chỉ nhận 1 nhãn (đã có: $LABEL, thừa: $1)"
        LABEL="$1"; shift ;;
  esac
done
sbpc_init

LABEL="${LABEL:-pc}"
case "$LABEL" in *[!a-zA-Z0-9._-]*) die "Nhãn chỉ gồm chữ/số/._- (không khoảng trắng): $LABEL" ;; esac

# 1) Tạo snapshot trên router (scripts/backup.sh của repo: tar config + sysupgrade -b)
log "Tạo backup trên router (nhãn: $LABEL)..."
rssh "sh '$REMOTE_DIR/scripts/backup.sh' '$LABEL'"

# 2) Lấy tên bản vừa tạo (con trỏ 'latest')
NAME="$(rssh "basename \$(readlink -f '$REMOTE_BACKUP_DIR/latest')")"
[ -n "$NAME" ] && [ "$NAME" != "latest" ] || die "Không xác định được bản backup vừa tạo trên router."

# 3) Kéo về máy (tar qua SSH — không cần SFTP, hợp với dropbear)
mkdir -p "$LOCAL_BACKUP_DIR"
OUT="$LOCAL_BACKUP_DIR/$NAME.tar.gz"
log "Kéo về: $OUT ..."
rssh "tar czf - -C '$REMOTE_BACKUP_DIR' '$NAME'" > "$OUT"
[ -s "$OUT" ] || { rm -f "$OUT"; die "File kéo về rỗng — kiểm tra kết nối/đường dẫn."; }

log "Backup xong: $OUT"
log "Danh sách bản local: pc/restore.sh --list"
