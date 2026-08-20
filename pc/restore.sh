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
    -*) die "Unknown argument: $1 — see: pc/restore.sh --help" ;;
    *)  [ -z "$BACKUP" ] || die "Only one backup is accepted (existing: $BACKUP, extra: $1)"
        BACKUP="$1"; shift ;;
  esac
done
sbpc_init

if [ "$LIST" = "1" ]; then
  echo "Local backups in $LOCAL_BACKUP_DIR:"
  FILES="$(ls -1t "$LOCAL_BACKUP_DIR"/*.tar.gz 2>/dev/null || true)"
  if [ -n "$FILES" ]; then
    echo "$FILES" | while read -r f; do printf '  %s\n' "$(basename "$f" .tar.gz)"; done
  else
    echo "  (none — run pc/backup.sh first)"
  fi
  exit 0
fi

# Resolve the requested snapshot.
if [ -z "$BACKUP" ]; then
  FILE="$(ls -1t "$LOCAL_BACKUP_DIR"/*.tar.gz 2>/dev/null | head -n 1)"
  [ -n "$FILE" ] || die "No backups found in $LOCAL_BACKUP_DIR. Run pc/backup.sh first."
elif [ -f "$BACKUP" ]; then
  FILE="$BACKUP"
elif [ -f "$LOCAL_BACKUP_DIR/$BACKUP.tar.gz" ]; then
  FILE="$LOCAL_BACKUP_DIR/$BACKUP.tar.gz"
else
  die "Not found: $BACKUP. List backups with: pc/restore.sh --list"
fi
NAME="$(basename "$FILE" .tar.gz)"

warn "This will OVERWRITE the configuration on router $ROUTER_HOST with: $NAME"
if [ "$YES" != "1" ]; then
  printf "Continue? [y/N] "
  read -r ans; case "$ans" in y|Y) : ;; *) die "Cancelled." ;; esac
fi

# 1) Upload and extract into the router backup directory.
log "Uploading $NAME to the router..."
rssh "cat > /tmp/sb-restore.tar.gz" < "$FILE"
rssh "mkdir -p '$REMOTE_BACKUP_DIR' && tar xzf /tmp/sb-restore.tar.gz -C '$REMOTE_BACKUP_DIR' && rm -f /tmp/sb-restore.tar.gz"

# 2) Run project rollback and reload affected services.
log "Running rollback on the router..."
rssht "SB_YES=1 sh '$REMOTE_DIR/scripts/rollback.sh' '$NAME'"

log "RESTORE COMPLETE. Check network/Wi-Fi connectivity. If SSH connectivity is lost, see docs/ROLLBACK.md."
