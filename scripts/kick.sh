#!/bin/sh
# kick.sh — deauthenticate (kick) one client from its Wi-Fi. Not persistent:
# the device may reassociate immediately. Use ban.sh to block reconnection.
#
# Usage: scripts/kick.sh <idx> <mac>
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root

IDX="$1"; MAC="$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z')"
case "$IDX" in *[!0-9]*|'') die "idx must be a positive integer" ;; esac
case "$MAC" in
  [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) : ;;
  *) die "invalid MAC address (expected AA:BB:CC:DD:EE:FF)" ;;
esac

ifname="$(ifname_of_idx "$IDX")"
[ -n "$ifname" ] || die "no active interface found for idx=$IDX"

# hostapd deauth via ubus; ban_time=0 means no in-memory hold (ban.sh handles persistence).
ubus call "hostapd.$ifname" del_client \
  "{\"addr\":\"$MAC\",\"reason\":1,\"deauth\":true,\"ban_time\":0}" \
  || die "ubus del_client failed (is hostapd unavailable on $ifname?)"
log "Disconnected $MAC from $ifname (idx=$IDX)"
