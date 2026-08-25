#!/bin/sh
# assign.sh — pin one device to a proxy in its Wi-Fi's pool, or unpin it.
#
# A pin is a row in ASSIGN_FILE plus one element in that SSID's nftables map.
# Neither sing-box nor Wi-Fi is reloaded, so no other device is disturbed.
#
# Usage:
#   scripts/assign.sh <idx> <mac> <slot>    # pin to a specific proxy
#   scripts/assign.sh <idx> <mac> auto      # pin to the least-used proxy
#   scripts/assign.sh <idx> <mac> none      # unpin; the device falls back to
#                                           # the proxy in wifi-socks.conf
# Example:
#   scripts/assign.sh 1 AA:BB:CC:DD:EE:01 2
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root
require_conf

IDX="${1:-}"; MAC="$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z')"; SLOT="${3:-auto}"
[ -n "$IDX" ] && [ -n "$MAC" ] || die "Usage: assign.sh <idx> <mac> <slot|auto|none>"
case "$IDX" in *[!0-9]*|'') die "idx must be a positive integer" ;; esac
assign_valid_mac "$MAC" || die "invalid MAC address (expected AA:BB:CC:DD:EE:FF)"

if [ "$SLOT" = "none" ]; then
  assign_clear "$IDX" "$MAC"
  # Drop the live element too, so the change takes effect without an apply.
  if command -v nft >/dev/null 2>&1; then
    ip="$(lease_ip_of "$MAC")"
    [ -n "$ip" ] && nft delete element inet sbproxy "w${IDX}map" "{ $ip }" >/dev/null 2>&1 || true
  fi
  log "Unpinned $MAC on idx=$IDX; it now uses the Wi-Fi's default proxy."
  exit 0
fi

SLOTS="$(pool_count "$IDX")"
[ "$SLOTS" -gt 0 ] || die "Wi-Fi idx=$IDX has no proxy pool (see config/proxy-pools.conf)"
[ "$SLOT" = "auto" ] && SLOT="$(assign_pick_slot "$IDX")"

assign_set "$IDX" "$MAC" "$SLOT" manual
assign_live_update "$IDX" "$MAC" "$SLOT"

DESC="$(pool_rows "$IDX" | awk -F'|' -v s="$SLOT" '$1==s { print ($7 != "" ? $7 " " : "") $3 ":" $4 }')"
log "Pinned $MAC on idx=$IDX to slot $SLOT (${DESC:-?})"
log "Connections already open keep using the previous proxy until they close."
