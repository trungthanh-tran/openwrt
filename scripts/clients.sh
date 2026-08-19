#!/bin/sh
# clients.sh — list Wi-Fi clients on every managed SSID as JSON.
# Read-only. Output: {ok:true, clients:[{idx,ssid,ifname,mac,ip,host,
#   signal_dbm,connected_s,rx_bytes,tx_bytes,banned}]}
set -u
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"

command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"thiếu jq"}'; exit 0; }
LEASES="${LEASES:-/tmp/dhcp.leases}"

# mac (lowercase) -> "ip\thost" from DHCP leases.
lease_of() {
  [ -f "$LEASES" ] || return 0
  awk -v m="$1" 'tolower($2)==m { print $3 "\t" $4; exit }' "$LEASES"
}

emit() {
  wifi_ifaces | while read -r section ifname; do
    idx="${section#w}"
    ssid="$(uci -q get "wireless.$section.ssid" 2>/dev/null || echo "$section")"
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
      il="$(lease_of "$lmac")"; ip="${il%%	*}"; host="${il#*	}"
      [ "$host" = "$il" ] && host=""      # no tab -> no lease match
      banned=false
      case " $(bans_for_idx "$idx") " in *" $lmac "*) banned=true ;; esac
      jq -n --argjson idx "$idx" --arg ssid "$ssid" --arg ifname "$ifname" \
            --arg mac "$lmac" --arg ip "$ip" --arg host "$host" \
            --arg sig "${sig:-}" --arg conn "${conn:-0}" \
            --arg rx "${rx:-0}" --arg tx "${tx:-0}" --argjson banned "$banned" \
        '{idx:$idx,ssid:$ssid,ifname:$ifname,mac:$mac,ip:$ip,host:$host,
          signal_dbm:($sig|try tonumber catch null),
          connected_s:($conn|try tonumber catch 0),
          rx_bytes:($rx|try tonumber catch 0),
          tx_bytes:($tx|try tonumber catch 0),
          banned:$banned}'
    done
  done
}

emit | jq -s '{ok:true, clients: sort_by(.idx, (.connected_s // 0) * -1)}'
