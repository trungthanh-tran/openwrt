#!/bin/sh
# ban.sh — persistently block a MAC from one SSID via Wi-Fi MAC filtering,
# then kick it now. The ban is recorded in BANS_FILE so apply.sh re-applies it.
#
# Usage: scripts/ban.sh <idx> <mac>
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
uci -q get "wireless.w$IDX" >/dev/null 2>&1 || die "không thấy SSID idx=$IDX"

BANS_FILE="${BANS_FILE:-/etc/sbproxy.bans}"
touch "$BANS_FILE"
if grep -qi "^$IDX|$MAC\$" "$BANS_FILE"; then
  log "$MAC đã bị cấm trên idx=$IDX (không đổi gì)"
else
  echo "$IDX|$MAC" >> "$BANS_FILE"
fi

# Apply the MAC filter live for this SSID.
uci set "wireless.w$IDX.macfilter=deny"
if ! uci -q get "wireless.w$IDX.maclist" | tr ' ' '\n' | grep -qi "^$MAC\$"; then
  uci add_list "wireless.w$IDX.maclist=$MAC"
fi
uci commit wireless

# Kick immediately (best-effort), then reload the band so the ACL takes effect.
ifname="$(ifname_of_idx "$IDX")"
[ -n "$ifname" ] && ubus call "hostapd.$ifname" del_client \
  "{\"addr\":\"$MAC\",\"reason\":1,\"deauth\":true,\"ban_time\":0}" 2>/dev/null || true

band="$(band_of_idx "$IDX")"
radio=""; [ -n "$band" ] && radio="$(radio_of "$band" 2>/dev/null || true)"
if [ -n "$radio" ]; then
  run "wifi reload $radio" || run "wifi reload"
else
  run "wifi reload"
fi
log "Đã cấm $MAC trên idx=$IDX (SSID reload băng ${band:-?})"
