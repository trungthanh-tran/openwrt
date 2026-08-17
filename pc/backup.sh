#!/bin/sh
# backup.sh — create a router snapshot and download it to this computer.
# Stores <timestamp>-<label>.tar.gz in LOCAL_BACKUP_DIR for pc/restore.sh.
#
# Usage: pc/backup.sh [label] [options]; the default label is `pc`.
#
# Script option: -h, --help shows help.
#
# Shared options (see _lib.sh): --conf FILE, --host HOST, --user USER, --port PORT,
#   --key FILE, --remote-dir DIR, --backup-dir DIR, --local-dir DIR
# Precedence: CLI arguments, config file, defaults. A config file is optional with --host.
#
# Examples:
#   pc/backup.sh                          # label `pc`, read pc/sbproxy-pc.conf
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

# 1) Create a router snapshot with scripts/backup.sh.
log "Tạo backup trên router (nhãn: $LABEL)..."
rssh "sh '$REMOTE_DIR/scripts/backup.sh' '$LABEL'"

# 2) Resolve the newly created snapshot through `latest`.
NAME="$(rssh "basename \$(readlink -f '$REMOTE_BACKUP_DIR/latest')")"
[ -n "$NAME" ] && [ "$NAME" != "latest" ] || die "Không xác định được bản backup vừa tạo trên router."

# 3) Download via tar over SSH for Dropbear compatibility.
mkdir -p "$LOCAL_BACKUP_DIR"
OUT="$LOCAL_BACKUP_DIR/$NAME.tar.gz"
log "Kéo về: $OUT ..."
rssh "tar czf - -C '$REMOTE_BACKUP_DIR' '$NAME'" > "$OUT"
[ -s "$OUT" ] || { rm -f "$OUT"; die "File kéo về rỗng — kiểm tra kết nối/đường dẫn."; }

log "Backup xong: $OUT"
log "Danh sách bản local: pc/restore.sh --list"
