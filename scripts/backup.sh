#!/bin/sh
# backup.sh — configuration snapshot for rollback. Creates two layers:
#   1) tar archive of /etc/config, /etc/sing-box, nft rules, and wifi-socks.conf
#   2) standard OpenWrt `sysupgrade -b` backup for firmware-level recovery
#
# Usage: scripts/backup.sh [label]
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root

LABEL="${1:-manual}"
# Use a sortable timestamp rather than a random identifier.
TS="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_DIR/$TS-$LABEL"
mkdir -p "$DEST"

log "Backup -> $DEST"

# Layer 1: archive project-related configuration files.
tar czf "$DEST/etc-config.tar.gz" \
  -C / etc/config etc/sing-box 2>/dev/null || warn "Some paths do not exist yet (normal on the first run)."
backup_snapshot_files "$DEST"

# Layer 2: standard sysupgrade backup.
if command -v sysupgrade >/dev/null 2>&1; then
  sysupgrade -b "$DEST/sysupgrade-backup.tar.gz" 2>/dev/null || warn "sysupgrade -b failed (ignored)."
fi

# Update the `latest` pointer.
ln -sfn "$DEST" "$BACKUP_DIR/latest"

# Retention: keep the 20 newest snapshots.
# shellcheck disable=SC2010  # BusyBox-compatible mtime ordering over generated names.
ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null | grep -v "^$BACKUP_DIR/latest/$" | tail -n +21 | while read -r old; do rm -rf "$old"; done

log "Backup complete: $DEST"
log "List backups: scripts/rollback.sh --list"
