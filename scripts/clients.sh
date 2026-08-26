#!/bin/sh
# clients.sh — list online Wi-Fi clients plus offline entries from the managed
# blocklist. Output: {ok:true, clients:[{idx,ssid,band,ifname,mac,ip,host,
#   signal_dbm,connected_s,rx_bytes,tx_bytes,banned,online,
#   slot,proxy_label,proxy_host,proxy_state,pool_size}]}
#
# The proxy fields carry the pool slot a device is pinned to. Only the label and
# host:port of that slot are reported: the credentials sit in the same row of
# proxy-pools.conf and must never travel with a device list.
set -u
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"

command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"jq is missing"}'; exit 0; }
LEASES="${LEASES:-/tmp/dhcp.leases}"
TMP_JSON="/tmp/sbproxy-clients.$$.jsonl"
LIVE_KEYS="/tmp/sbproxy-clients.$$.live"
PIN_INDEX="/tmp/sbproxy-clients.$$.pins"
POOL_SIZES="/tmp/sbproxy-clients.$$.sizes"
: > "$TMP_JSON"; : > "$LIVE_KEYS"; : > "$PIN_INDEX"; : > "$POOL_SIZES"
trap 'rm -f "$TMP_JSON" "$LIVE_KEYS" "$PIN_INDEX" "$POOL_SIZES"' EXIT INT TERM

# Resolve the pool and the pins in one pass, so looking a device up below is a
# scan of two small files rather than re-parsing the configuration per device.
build_pool_index() {
  _pools="${POOLS:-$SB_ROOT/config/proxy-pools.conf}"
  [ -f "$_pools" ] || return 0
  _assign="${ASSIGN_FILE:-/etc/sbproxy.assign}"
  [ -f "$_assign" ] || _assign=/dev/null
  awk -F'|' -v pools="$_pools" -v pins="$PIN_INDEX" -v sizes="$POOL_SIZES" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    { sub(/\r$/, "") }
    $0 ~ /^[ \t]*#/ || $0 ~ /^[ \t]*$/ { next }
    FILENAME == pools {
      if (NF < 6 || NF > 7) next
      i = trim($1); s = count[i]++
      host[i "|" s] = trim($3) ":" trim($4)
      label[i "|" s] = (NF >= 7 ? trim($7) : "")
      next
    }
    NF < 3 { next }
    {
      i = trim($1); k = i "|" trim($3)
      print i "|" tolower(trim($2)) "\t" trim($3) "\t" \
            (k in label ? label[k] : "") "\t" (k in host ? host[k] : "") > pins
    }
    END { for (i in count) print i "\t" count[i] > sizes }
  ' "$_pools" "$_assign" 2>/dev/null || :
}
build_pool_index

# Sets P_SLOT / P_LABEL / P_HOST / P_STATE / P_SIZE for one device.
proxy_fields() {
  P_SIZE="$(awk -F'\t' -v i="$1" '$1==i { print $2; exit }' "$POOL_SIZES")"
  P_SIZE="${P_SIZE:-0}"
  _row="$(awk -F'\t' -v k="$1|$2" '$1==k { print $2 "\t" $3 "\t" $4; exit }' "$PIN_INDEX")"
  P_SLOT="${_row%%	*}"
  _rest="${_row#*	}"; P_LABEL="${_rest%%	*}"; P_HOST="${_rest##*	}"
  if [ "$P_SIZE" -eq 0 ]; then P_STATE="none"
  elif [ -z "$P_SLOT" ]; then P_STATE="unpinned"
  # A pin the pool no longer has a row for has to read as broken, not as a
  # device quietly sitting on some other proxy.
  elif [ -z "$P_HOST" ]; then P_STATE="stale"
  else P_STATE="pinned"
  fi
}

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
      proxy_fields "$idx" "$lmac"
      jq -n --argjson idx "$idx" --arg ssid "$ssid" --arg band "$band" \
            --arg ifname "$ifname" --arg mac "$lmac" --arg ip "$ip" --arg host "$host" \
            --arg sig "${sig:-}" --arg conn "${conn:-0}" \
            --arg rx "${rx:-0}" --arg tx "${tx:-0}" --argjson banned "$banned" \
            --arg slot "$P_SLOT" --arg plabel "$P_LABEL" --arg phost "$P_HOST" \
            --arg pstate "$P_STATE" --arg psize "$P_SIZE" \
        '{idx:$idx,ssid:$ssid,band:$band,ifname:$ifname,mac:$mac,ip:$ip,host:$host,
          signal_dbm:($sig|try tonumber catch null),
          connected_s:($conn|try tonumber catch 0),
          rx_bytes:($rx|try tonumber catch 0),
          tx_bytes:($tx|try tonumber catch 0),
          banned:$banned,online:true,
          slot:($slot|try tonumber catch null),
          proxy_label:$plabel,proxy_host:$phost,proxy_state:$pstate,
          pool_size:($psize|try tonumber catch 0)}'
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
    proxy_fields "$idx" "$lmac"
    jq -n --argjson idx "$idx" --arg ssid "$ssid" --arg band "$band" \
          --arg ifname "$ifname" --arg mac "$lmac" --arg ip "$ip" --arg host "$host" \
          --arg slot "$P_SLOT" --arg plabel "$P_LABEL" --arg phost "$P_HOST" \
          --arg pstate "$P_STATE" --arg psize "$P_SIZE" \
      '{idx:$idx,ssid:$ssid,band:$band,ifname:$ifname,mac:$mac,ip:$ip,host:$host,
        signal_dbm:null,connected_s:0,rx_bytes:0,tx_bytes:0,banned:true,online:false,
        slot:($slot|try tonumber catch null),
        proxy_label:$plabel,proxy_host:$phost,proxy_state:$pstate,
        pool_size:($psize|try tonumber catch 0)}'
  done
}

emit_live > "$TMP_JSON"
emit_blocked_offline >> "$TMP_JSON"
jq -s '{ok:true, clients: sort_by((if .online then 0 else 1 end), .idx, ((.connected_s // 0) * -1))}' "$TMP_JSON"
