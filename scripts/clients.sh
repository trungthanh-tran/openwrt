#!/bin/sh
# clients.sh — list online Wi-Fi clients plus offline entries from the managed
# blocklist. Output: {ok:true, clients:[{idx,ssid,band,ifname,mac,ip,host,
#   signal_dbm,connected_s,rx_bytes,tx_bytes,banned,online}]}
set -u
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"

command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"jq is missing"}'; exit 0; }
LEASES="${LEASES:-/tmp/dhcp.leases}"
TMP_JSON="/tmp/sbproxy-clients.$$.jsonl"
LIVE_KEYS="/tmp/sbproxy-clients.$$.live"
: > "$TMP_JSON"; : > "$LIVE_KEYS"
trap 'rm -f "$TMP_JSON" "$LIVE_KEYS"' EXIT INT TERM

# mac (lowercase) -> "ip\thost" from DHCP leases.
lease_of() {
  [ -f "$LEASES" ] || return 0
  awk -v m="$1" 'tolower($2)==m { print $3 "\t" $4; exit }' "$LEASES"
}

emit_live() {
  wifi_ifaces | while read -r section ifname; do
    idx="${section#w}"
    ssid="$(uci -q get "wireless.$section.ssid" 2>/dev/null || echo "$section")"
    band="$(band_of_idx "$idx")"
    # Parse `iw dev <ifname> station dump` into: mac|connected_s|rx|tx|signal
    iw dev "$ifname" station dump 2>/dev/null | awk '
      /^Station/ { if (mac!="") print mac"|"conn"|"rx"|"tx"|"sig; mac=$2; conn=rx=tx=sig="" }
      /rx bytes:/       { rx=$3 }
      /tx bytes:/       { tx=$3 }
      /^[[:space:]]*signal:/ { sig=$2 }
      /connected time:/ { conn=$3 }
      END { if (mac!="") print mac"|"conn"|"rx"|"tx"|"sig }
    ' | while IFS='|' read -r mac conn rx tx sig; do
      [ -n "$mac" ] || continue
      lmac="$(printf '%s' "$mac" | tr 'A-Z' 'a-z')"
      printf '%s|%s\n' "$idx" "$lmac" >> "$LIVE_KEYS"
      il="$(lease_of "$lmac")"; ip="${il%%	*}"; host="${il#*	}"
      [ "$host" = "$il" ] && host=""
      banned=false
      case " $(bans_for_idx "$idx") " in *" $lmac "*) banned=true ;; esac
      jq -n --argjson idx "$idx" --arg ssid "$ssid" --arg band "$band" \
            --arg ifname "$ifname" --arg mac "$lmac" --arg ip "$ip" --arg host "$host" \
            --arg sig "${sig:-}" --arg conn "${conn:-0}" \
            --arg rx "${rx:-0}" --arg tx "${tx:-0}" --argjson banned "$banned" \
        '{idx:$idx,ssid:$ssid,band:$band,ifname:$ifname,mac:$mac,ip:$ip,host:$host,
          signal_dbm:($sig|try tonumber catch null),
          connected_s:($conn|try tonumber catch 0),
          rx_bytes:($rx|try tonumber catch 0),
          tx_bytes:($tx|try tonumber catch 0),
          banned:$banned,online:true}'
    done
  done
}

emit_blocked_offline() {
  [ -f "${BANS_FILE:-/etc/sbproxy.bans}" ] || return 0
  sort -u "${BANS_FILE:-/etc/sbproxy.bans}" | while IFS='|' read -r idx mac; do
    case "$idx" in *[!0-9]*|'') continue ;; esac
    lmac="$(printf '%s' "$mac" | tr 'A-Z' 'a-z' | tr -d ' \r')"
    echo "$lmac" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || continue
    grep -qxF "$idx|$lmac" "$LIVE_KEYS" && continue
    ssid="$(uci -q get "wireless.w$idx.ssid" 2>/dev/null || echo "w$idx")"
    band="$(band_of_idx "$idx")"
    ifname="$(ifname_of_idx "$idx")"
    il="$(lease_of "$lmac")"; ip="${il%%	*}"; host="${il#*	}"
    [ "$host" = "$il" ] && host=""
    jq -n --argjson idx "$idx" --arg ssid "$ssid" --arg band "$band" \
          --arg ifname "$ifname" --arg mac "$lmac" --arg ip "$ip" --arg host "$host" \
      '{idx:$idx,ssid:$ssid,band:$band,ifname:$ifname,mac:$mac,ip:$ip,host:$host,
        signal_dbm:null,connected_s:0,rx_bytes:0,tx_bytes:0,banned:true,online:false}'
  done
}

emit_live > "$TMP_JSON"
emit_blocked_offline >> "$TMP_JSON"
jq -s '{ok:true, clients: sort_by((if .online then 0 else 1 end), .idx, ((.connected_s // 0) * -1))}' "$TMP_JSON"
