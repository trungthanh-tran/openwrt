#!/bin/sh
# unban.sh — remove a MAC ban from one SSID and rebuild its MAC filter.
#
# Usage: scripts/unban.sh <idx> <mac>
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root

IDX="$1"; MAC="$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z')"
case "$IDX" in *[!0-9]*|'') die "idx phải là số nguyên dương" ;; esac
case "$MAC" in
  [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) : ;;
  *) die "mac không hợp lệ (cần AA:BB:CC:DD:EE:FF)" ;;
esac

BANS_FILE="${BANS_FILE:-/etc/sbproxy.bans}"
if [ -f "$BANS_FILE" ]; then
  TMP="/tmp/sbproxy-bans.$$"
  grep -iv "^$IDX|$MAC\$" "$BANS_FILE" > "$TMP" 2>/dev/null || :
  mv "$TMP" "$BANS_FILE"
fi

# Rebuild this SSID's MAC filter from the remaining bans.
uci -q delete "wireless.w$IDX.maclist" 2>/dev/null || true
rest="$(bans_for_idx "$IDX")"
if [ -n "$rest" ]; then
  uci set "wireless.w$IDX.macfilter=deny"
  for m in $rest; do uci add_list "wireless.w$IDX.maclist=$m"; done
else
  uci -q delete "wireless.w$IDX.macfilter" || true
  uci -q delete "wireless.w$IDX.maclist" || true
fi
uci commit wireless

band="$(band_of_idx "$IDX")"
radio=""; [ -n "$band" ] && radio="$(radio_of "$band" 2>/dev/null || true)"
if [ -n "$radio" ]; then
  run "wifi reload $radio" || run "wifi reload"
else
  run "wifi reload"
fi
log "Đã bỏ cấm $MAC trên idx=$IDX"
