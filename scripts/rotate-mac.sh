#!/bin/sh
# Rotate the BSSID/MAC of one managed SSID while preserving its configured OUI.
# The new value is stored in UCI, so later apply.sh runs keep it stable.
# An optional second argument changes the configured OUI before rotating; an
# explicitly empty OUI selects a locally administered 02:xx address.
# Usage: scripts/rotate-mac.sh <idx> [mac_oui]
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root
require_conf

IDX="${1:-}"
case "$IDX" in *[!0-9]*|'') die "idx must be a positive integer" ;; esac

SET_OUI=0
REQUESTED_OUI=""
if [ "$#" -ge 2 ]; then
  SET_OUI=1
  REQUESTED_OUI="$(printf '%s' "$2" | tr -d ' \r' | tr 'a-z' 'A-Z')"
  case "$REQUESTED_OUI" in
    '') : ;;
    [0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]) : ;;
    *) die "mac_oui must use the AA:BB:CC format or be empty" ;;
  esac
fi

BAND="$(band_of_idx "$IDX")"
[ -n "$BAND" ] || die "idx=$IDX is not present in wifi-socks.conf"
uci -q get "wireless.w$IDX.ssid" >/dev/null 2>&1 \
  || die "Wi-Fi w$IDX has not been applied on the router"

OUI="$(awk -F'|' -v i="$IDX" '
  !/^[[:space:]]*#/ {
    idx=$3; gsub(/[[:space:]\r]/, "", idx)
    if (idx == i) {
      oui=$11; gsub(/[[:space:]\r]/, "", oui); print tolower(oui); exit
    }
  }
' "$CONF")"
[ "$SET_OUI" = "0" ] || OUI="$REQUESTED_OUI"

OLD="$(uci -q get "wireless.w$IDX.macaddr" 2>/dev/null || true)"
NEW="$(gen_mac "$OUI")"
tries=0
while [ "$NEW" = "$OLD" ] && [ "$tries" -lt 5 ]; do
  NEW="$(gen_mac "$OUI")"
  tries=$((tries + 1))
done
[ "$NEW" != "$OLD" ] || die "failed to generate a new MAC address"

"${BACKUP_SCRIPT:-$SB_ROOT/scripts/backup.sh}" pre-rotate-mac
if [ "$SET_OUI" = "1" ]; then
  TMP_CONF="/tmp/sbproxy-rotate-conf.$$"
  trap 'rm -f "$TMP_CONF"' EXIT INT TERM
  awk -F'|' -v OFS='|' -v i="$IDX" -v oui="$REQUESTED_OUI" '
    {
      idx=$3; gsub(/[[:space:]\r]/, "", idx)
      if ($0 !~ /^[[:space:]]*#/ && idx == i) $11=oui
      print
    }
  ' "$CONF" > "$TMP_CONF"
  cat "$TMP_CONF" > "$CONF"
  rm -f "$TMP_CONF"
  trap - EXIT INT TERM
fi
uci set "wireless.w$IDX.macaddr=$NEW"
uci commit wireless

RADIO="$(radio_of "$BAND")"
wifi reload "$RADIO" >/dev/null 2>&1 || wifi reload
log "Rotated BSSID w$IDX: ${OLD:-not set} -> $NEW (OUI=${OUI:-02 local}, radio=$RADIO)"
