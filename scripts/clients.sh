#!/bin/sh
# clients.sh — list Wi-Fi clients: the ones associated right now, the ones on
# the managed blocklist, and the ones that have connected before and left.
#
# Output: {ok:true, clients:[{idx,ssid,band,ifname,mac,ip,host,
#   signal_dbm,connected_s,rx_bytes,tx_bytes,banned,online,status,
#   first_seen,last_seen,inactive_s,
#   slot,proxy_label,proxy_host,proxy_type,proxy_state,pool_size}]}
#
# status is one of: online | blocked | offline. A console renders it as
# "active for <connected_s>", "blocked", or "inactive for <inactive_s>".
#
# The proxy fields carry the pool slot a device is pinned to. Only the label and
# host:port of that slot are reported: the credentials sit in the same row of
# proxy-pools.conf and must never travel with a device list.
set -u
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"

command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"jq is missing"}'; exit 0; }
LEASES="${LEASES:-/tmp/dhcp.leases}"
SEEN_FILE="${SEEN_FILE:-/tmp/sbproxy.seen}"
SEEN_STORE="${SEEN_STORE:-/etc/sbproxy.seen}"
SEEN_MAX="${SEEN_MAX:-400}"
case "$SEEN_MAX" in ''|*[!0-9]*) SEEN_MAX=400 ;; esac
NOW="$(date +%s)"

TMP_JSON="/tmp/sbproxy-clients.$$.jsonl"
LIVE_KEYS="/tmp/sbproxy-clients.$$.live"
LIVE_INFO="/tmp/sbproxy-clients.$$.info"
PIN_INDEX="/tmp/sbproxy-clients.$$.pins"
POOL_SIZES="/tmp/sbproxy-clients.$$.sizes"
SEEN_TMP="/tmp/sbproxy-clients.$$.seen"
SEEN_NEW="/tmp/sbproxy-clients.$$.newdev"
LIVE_ROWS="/tmp/sbproxy-clients.$$.rows"
: > "$TMP_JSON"; : > "$LIVE_KEYS"; : > "$LIVE_INFO"; : > "$PIN_INDEX"; : > "$POOL_SIZES"
: > "$LIVE_ROWS"
trap 'rm -f "$TMP_JSON" "$LIVE_KEYS" "$LIVE_INFO" "$PIN_INDEX" "$POOL_SIZES" "$SEEN_TMP" "$SEEN_NEW" "$LIVE_ROWS"' EXIT INT TERM

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
      type[i "|" s] = trim($2)
      label[i "|" s] = (NF >= 7 ? trim($7) : "")
      next
    }
    NF < 3 { next }
    {
      i = trim($1); k = i "|" trim($3)
      print i "|" tolower(trim($2)) "\t" trim($3) "\t" \
            (k in label ? label[k] : "") "\t" (k in host ? host[k] : "") "\t" \
            (k in type ? type[k] : "socks5") > pins
    }
    END { for (i in count) print i "\t" count[i] > sizes }
  ' "$_pools" "$_assign" 2>/dev/null || :
}

# Sets P_SLOT / P_LABEL / P_HOST / P_TYPE / P_STATE / P_SIZE for one device.
proxy_fields() {
  P_SIZE="$(awk -F'\t' -v i="$1" '$1==i { print $2; exit }' "$POOL_SIZES")"
  P_SIZE="${P_SIZE:-0}"
  _row="$(awk -F'\t' -v k="$1|$2" '$1==k { print $2 "\t" $3 "\t" $4; exit }' "$PIN_INDEX")"
  P_SLOT="${_row%%	*}"
  _rest="${_row#*	}"; P_LABEL="${_rest%%	*}"; _rest="${_rest#*	}"
  P_HOST="${_rest%%	*}"; P_TYPE="${_rest##*	}"
  P_TYPE="${P_TYPE:-socks5}"
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

# --- the seen store: every device that has ever associated -------------------
# Lines: idx|mac|first_seen|last_seen|ip|host. The tmpfs copy is rewritten on
# every poll; the flash copy is only touched when a device shows up for the
# first time, so a console polling every few seconds costs no flash writes.
seen_load() {
  if [ ! -f "$SEEN_FILE" ] && [ -f "$SEEN_STORE" ]; then
    cp "$SEEN_STORE" "$SEEN_FILE" 2>/dev/null || :
  fi
  [ -f "$SEEN_FILE" ] || : > "$SEEN_FILE" 2>/dev/null || :
}

# Merge this run's live sightings into the seen store.
seen_sync() {
  [ -w "$(dirname "$SEEN_FILE")" ] 2>/dev/null || return 0
  : > "$SEEN_NEW"
  awk -F'|' -v now="$NOW" -v seenf="$SEEN_FILE" -v marker="$SEEN_NEW" '
    function key(i, m) { return i "|" m }
    FILENAME == seenf {
      if (NF < 4) next
      k = key($1, $2)
      if (!(k in first)) order[++n] = k
      first[k] = $3; last[k] = $4
      ip[k] = (NF >= 5 ? $5 : ""); host[k] = (NF >= 6 ? $6 : "")
      next
    }
    # live sightings: idx|mac|ip|host
    {
      k = key($1, $2)
      if (!(k in first)) { order[++n] = k; first[k] = now; print "new" > marker }
      last[k] = now
      if ($3 != "") ip[k] = $3
      if ($4 != "") host[k] = $4
    }
    END {
      for (j = 1; j <= n; j++) {
        k = order[j]
        print k "|" first[k] "|" last[k] "|" ip[k] "|" host[k]
      }
    }
  ' "$SEEN_FILE" "$LIVE_INFO" 2>/dev/null \
    | sort -t'|' -k4,4nr | head -n "$SEEN_MAX" > "$SEEN_TMP" 2>/dev/null || return 0
  mv "$SEEN_TMP" "$SEEN_FILE" 2>/dev/null || return 0
  # Only a device never recorded before earns a flash write.
  if [ -s "$SEEN_NEW" ] && [ -n "$SEEN_STORE" ]; then
    cp "$SEEN_FILE" "$SEEN_STORE" 2>/dev/null || :
  fi
}

# Sets S_FIRST / S_LAST for one device from the seen store ("" when unknown).
seen_of() {
  _srow="$(awk -F'|' -v k="$1|$2" '$1 "|" $2 == k { print $3 "\t" $4; exit }' "$SEEN_FILE" 2>/dev/null)"
  S_FIRST="${_srow%%	*}"; S_LAST="${_srow##*	}"
  case "$S_FIRST" in ''|*[!0-9]*) S_FIRST="" ;; esac
  case "$S_LAST" in ''|*[!0-9]*) S_LAST="" ;; esac
}

# One device as JSON. Every emitter funnels through here so the three kinds of
# entry cannot drift apart in shape.
emit_device() { # idx ssid band ifname mac ip host sig conn rx tx banned online [first last]
  _idx="$1"; _ssid="$2"; _band="$3"; _ifname="$4"; _mac="$5"; _ip="$6"; _host="$7"
  _sig="$8"; _conn="$9"; shift 9
  _rx="$1"; _tx="$2"; _banned="$3"; _online="$4"
  # A caller reading the seen store row by row already knows the timestamps;
  # only the others pay for a lookup.
  if [ "$#" -ge 6 ]; then S_FIRST="$5"; S_LAST="$6"; else seen_of "$_idx" "$_mac"; fi
  if [ "$_online" = true ]; then _status=online; S_LAST="$NOW"
  elif [ "$_banned" = true ]; then _status=blocked
  else _status=offline
  fi
  _inactive=""
  if [ "$_online" != true ] && [ -n "$S_LAST" ]; then
    _inactive="$((NOW - S_LAST))"
    [ "$_inactive" -ge 0 ] 2>/dev/null || _inactive=0
  fi
  proxy_fields "$_idx" "$_mac"
  jq -n --argjson idx "$_idx" --arg ssid "$_ssid" --arg band "$_band" \
        --arg ifname "$_ifname" --arg mac "$_mac" --arg ip "$_ip" --arg host "$_host" \
        --arg sig "$_sig" --arg conn "${_conn:-0}" --arg rx "${_rx:-0}" --arg tx "${_tx:-0}" \
        --argjson banned "$_banned" --argjson online "$_online" --arg status "$_status" \
        --arg first "${S_FIRST:-}" --arg last "${S_LAST:-}" --arg inactive "${_inactive:-}" \
        --arg slot "$P_SLOT" --arg plabel "$P_LABEL" --arg phost "$P_HOST" \
        --arg ptype "$P_TYPE" --arg pstate "$P_STATE" --arg psize "$P_SIZE" \
    '{idx:$idx,ssid:$ssid,band:$band,ifname:$ifname,mac:$mac,ip:$ip,host:$host,
      signal_dbm:($sig|try tonumber catch null),
      connected_s:($conn|try tonumber catch 0),
      rx_bytes:($rx|try tonumber catch 0),
      tx_bytes:($tx|try tonumber catch 0),
      banned:$banned,online:$online,status:$status,
      first_seen:($first|try tonumber catch null),
      last_seen:($last|try tonumber catch null),
      inactive_s:($inactive|try tonumber catch null),
      slot:($slot|try tonumber catch null),
      proxy_label:$plabel,proxy_host:$phost,proxy_type:$ptype,proxy_state:$pstate,
      pool_size:($psize|try tonumber catch 0)}'
}

# Associated stations, one pass of `iw`, into LIVE_INFO (idx|mac|ip|host) and a
# detail file the emitter reads back. Collection is separated from emission so
# the seen store can be updated before anything is rendered.
collect_live() {
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
      il="$(lease_of "$lmac")"; ip="${il%%	*}"; host="${il#*	}"
      [ "$host" = "$il" ] && host=""
      printf '%s|%s\n' "$idx" "$lmac" >> "$LIVE_KEYS"
      printf '%s|%s|%s|%s\n' "$idx" "$lmac" "$ip" "$host" >> "$LIVE_INFO"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$idx" "$ssid" "$band" "$ifname" "$lmac" "$ip" "$host" \
        "${sig:-}" "${conn:-0}" "${rx:-0}|${tx:-0}" >> "$LIVE_ROWS"
    done
  done
}

emit_live() {
  while IFS='	' read -r idx ssid band ifname mac ip host sig conn bytes; do
    [ -n "$mac" ] || continue
    rx="${bytes%%|*}"; tx="${bytes##*|}"
    banned=false
    case " $(bans_for_idx "$idx") " in *" $mac "*) banned=true ;; esac
    emit_device "$idx" "$ssid" "$band" "$ifname" "$mac" "$ip" "$host" \
                "$sig" "$conn" "$rx" "$tx" "$banned" true
  done < "$LIVE_ROWS"
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
    emit_device "$idx" "$ssid" "$band" "$ifname" "$lmac" "$ip" "$host" \
                "" 0 0 0 true false
  done
}

# Devices that have connected before and are neither associated now nor banned:
# the answer to "which machines have ever been on this Wi-Fi?".
emit_history() {
  [ -s "$SEEN_FILE" ] || return 0
  while IFS='|' read -r idx mac first last ip host; do
    case "$idx" in *[!0-9]*|'') continue ;; esac
    echo "$mac" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || continue
    grep -qxF "$idx|$mac" "$LIVE_KEYS" && continue
    case " $(bans_for_idx "$idx") " in *" $mac "*) continue ;; esac
    ssid="$(uci -q get "wireless.w$idx.ssid" 2>/dev/null || echo "w$idx")"
    band="$(band_of_idx "$idx")"
    ifname="$(ifname_of_idx "$idx")"
    # A current lease is fresher than whatever was recorded at the last sighting.
    il="$(lease_of "$mac")"; lip="${il%%	*}"; lhost="${il#*	}"
    [ "$lhost" = "$il" ] && lhost=""
    [ -n "$lip" ] && ip="$lip"
    [ -n "$lhost" ] && host="$lhost"
    emit_device "$idx" "$ssid" "$band" "$ifname" "$mac" "$ip" "$host" \
                "" 0 0 0 false false "$first" "$last"
  done < "$SEEN_FILE"
}

build_pool_index
seen_load
collect_live
seen_sync
emit_live > "$TMP_JSON"
emit_blocked_offline >> "$TMP_JSON"
emit_history >> "$TMP_JSON"
# Online first, then blocked, then the rest by how recently they were seen.
jq -s '{ok:true, clients: sort_by(
          (if .online then 0 elif .banned then 1 else 2 end),
          .idx,
          (if .online then ((.connected_s // 0) * -1) else ((.last_seen // 0) * -1) end))}' "$TMP_JSON"
