#!/bin/sh
# backup.sh — chạy backup trên router rồi KÉO snapshot về máy này.
# Snapshot lưu tại LOCAL_BACKUP_DIR dạng <timestamp>-<nhãn>.tar.gz, dùng lại được với pc/restore.sh.
#
# Dùng:
#   pc/backup.sh            # nhãn mặc định "pc"
#   pc/backup.sh truoc-nang-cap
set -e
. "$(dirname "$0")/_lib.sh"

LABEL="${1:-pc}"
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
