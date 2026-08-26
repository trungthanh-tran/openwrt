#!/bin/sh
# pool.sh — inspect or replace one Wi-Fi's proxy pool.
#
# Replacing regenerates sing-box and nftables and restarts them, but does NOT
# reload Wi-Fi, so clients stay associated. Pins are carried across by proxy
# identity, so a device keeps the proxy it was using even if its slot moves.
#
# Usage:
#   scripts/pool.sh list <idx>
#   scripts/pool.sh replace <idx> <file>   # rows: type|host|port|user|pass|label
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"

VERB="${1:-}"; IDX="${2:-}"
case "$VERB" in
  list|replace) : ;;
  *) die "Usage: pool.sh list <idx> | pool.sh replace <idx> <file>" ;;
esac
case "$IDX" in *[!0-9]*|'') die "idx must be a positive integer" ;; esac

if [ "$VERB" = "list" ]; then
  pool_rows "$IDX"
  exit 0
fi

SRC="${3:-}"
[ -n "$SRC" ] && [ -f "$SRC" ] || die "Usage: pool.sh replace <idx> <file>"
require_root
require_conf

log "Backing up the configuration before replacing the pool..."
"$SB_ROOT/scripts/backup.sh" pre-pool

pool_replace "$IDX" "$SRC"

log "Regenerating sing-box and nftables..."
build_singbox
build_nft

log "Reloading sing-box and tproxy (Wi-Fi will NOT be interrupted)..."
run "/etc/init.d/sbproxy restart"
run "/etc/init.d/sing-box restart"

log "Wi-Fi idx=$IDX now has $(pool_count "$IDX") proxies."
