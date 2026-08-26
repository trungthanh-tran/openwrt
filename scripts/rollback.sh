#!/bin/sh
# rollback.sh — restore configuration from the latest or a named snapshot.
#
# Usage:
#   scripts/rollback.sh --list          # list snapshots
#   scripts/rollback.sh                  # restore `latest`
#   scripts/rollback.sh 20260812-101500-pre-apply
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root

if [ "$1" = "--list" ]; then
  echo "Available backups in $BACKUP_DIR:"
  # shellcheck disable=SC2010  # BusyBox-compatible mtime ordering over generated names.
  ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null | grep -v "^$BACKUP_DIR/latest/$" | sed "s#$BACKUP_DIR/##;s#/\$##" || echo "  (none)"
  echo "'latest' -> $(readlink -f "$BACKUP_DIR/latest" 2>/dev/null || echo none)"
  exit 0
fi

if [ -n "$1" ]; then
  case "$1" in *[!A-Za-z0-9._-]*|*..*) die "Invalid backup name: $1" ;; esac
  SRC="$BACKUP_DIR/$1"
else SRC="$(readlink -f "$BACKUP_DIR/latest" 2>/dev/null)"; fi
[ -n "$SRC" ] && [ -d "$SRC" ] || die "Backup not found: ${1:-latest}. See: rollback.sh --list"

log "Rolling back from: $SRC"
# SB_YES=1 skips confirmation for non-interactive agent/CGI calls.
if [ "$SB_YES" != "1" ]; then
  printf "This will OVERWRITE /etc/config, /etc/sing-box, and %s. Continue? [y/N] " "$NFT_FILE"
  read -r ans; case "$ans" in y|Y) : ;; *) die "Cancelled."; esac
fi

# 1) Restore configuration files.
[ -f "$SRC/etc-config.tar.gz" ] && tar xzf "$SRC/etc-config.tar.gz" -C / && log "Restored /etc/config and /etc/sing-box"
restore_snapshot_files "$SRC"

# 2) Reload all affected services.
log "Reloading services..."
uci commit 2>/dev/null || true
/etc/init.d/network reload  || true
/etc/init.d/dnsmasq restart || true
/etc/init.d/firewall reload || true
/etc/init.d/sbproxy restart 2>/dev/null || true
/etc/init.d/sing-box restart 2>/dev/null || true
wifi reload || true
recover_wifi_networks

log "ROLLBACK COMPLETE. Check network connectivity."
log "If serious problems remain, restore the sysupgrade backup ($SRC/sysupgrade-backup.tar.gz) through LuCI"
log "  System > Backup/Flash > Restore, or: sysupgrade -r $SRC/sysupgrade-backup.tar.gz && reboot"
