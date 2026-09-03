#!/bin/sh
# Why does a device on this SSID have no Internet? Walk the data path once,
# from the Wi-Fi interface to the proxy, and report every link as JSON.
#
#   diagnose-ssid.sh <idx>
#
# Read-only. Each check is {name, ok, detail}; `verdict` names the first
# broken link, which is the one to fix. Meant for the agent (diagnose_ssid)
# and the consoles, but readable on its own: pipe through `jq -r .report`.
set -u
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
[ -f /etc/sbproxy/env ] && . /etc/sbproxy/env

command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"missing jq"}'; exit 1; }
idx="${1:-}"
case "$idx" in ''|*[!0-9]*) echo '{"ok":false,"error":"idx must be a number"}'; exit 1;; esac

checks='[]'
verdict=""
add() {  # add <name> <true|false> <detail>
  checks="$(printf '%s' "$checks" | jq -c --arg n "$1" --argjson ok "$2" --arg d "$3" '. + [{name:$n, ok:$ok, detail:$d}]')"
  [ "$2" = false ] && [ -z "$verdict" ] && verdict="$1: $3"
}
tail_txt() { tr -d '\r' | tail -n "$1"; }

# --- 1. the SSID exists in wifi-socks.conf --------------------------------
# Trim a COPY of the idx field: touching $3 itself makes awk rebuild $0 with
# spaces as separators, which used to hand every later cut -d'|' the whole
# row (wrong host/port, and the Wi-Fi key and proxy password leaking into
# the report) whenever the idx column carried padding.
row="$(awk -F'|' -v want="$idx" '!/^[[:space:]]*(#|$)/ { t = $3; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); if (t == want) { print; exit } }' "$CONF" 2>/dev/null)"
if [ -z "$row" ]; then
  add "config" false "no row with idx $idx in $CONF"
  jq -n --argjson c "$checks" --arg v "$verdict" '{ok:true, idx:'"$idx"', checks:$c, verdict:$v}'; exit 0
fi
ssid="$(printf '%s' "$row" | cut -d'|' -f1)"
host="$(printf '%s' "$row" | cut -d'|' -f5 | tr -d ' ')"
port="$(printf '%s' "$row" | cut -d'|' -f6 | tr -d ' ')"
user="$(printf '%s' "$row" | cut -d'|' -f7)"
pass="$(printf '%s' "$row" | cut -d'|' -f8)"
ptype="$(printf '%s' "$row" | cut -d'|' -f12 | tr -d ' ')"; [ -n "$ptype" ] || ptype=socks5
tp="$(tproxy_port "$idx")"
subnet="192.168.$(net_octet "$idx")"
add "config" true "SSID $ssid · subnet $subnet.0/24 · tproxy :$tp · proxy $ptype://$host:$port"

# --- 2. the Wi-Fi interface is up and has clients ----------------------------
ifn="$(ifname_of_idx "$idx" 2>/dev/null)"
if [ -n "$ifn" ]; then
  n=0; command -v iw >/dev/null 2>&1 && n="$(iw dev "$ifn" station dump 2>/dev/null | grep -c '^Station')"
  add "wifi" true "$ifn is up · $n station(s) associated"
else
  add "wifi" false "no running wifi-iface for w$idx (SSID not broadcasting; apply failed or radio down)"
fi

# --- 3. the bridge carries the gateway address --------------------------------
if ip -4 addr show "br-w$idx" 2>/dev/null | grep -q "inet $subnet\.1/"; then
  add "bridge" true "br-w$idx has $subnet.1"
else
  add "bridge" false "br-w$idx is missing or has no $subnet.1 address (netifd did not bring the interface up)"
fi

# --- 4. devices got a lease in the subnet -------------------------------------
leases="$(awk -v s="$subnet." 'index($3, s) == 1 { print $2 " " $3 " " $4 }' "${DHCP_LEASES:-/tmp/dhcp.leases}" 2>/dev/null)"
nl="$(printf '%s' "$leases" | grep -c .)"
if [ "$nl" -gt 0 ]; then
  add "dhcp" true "$nl lease(s): $(printf '%s' "$leases" | tr '\n' ';' | cut -c1-200)"
else
  add "dhcp" false "no DHCP lease in $subnet.0/24 (device has no IP: dnsmasq not serving br-w$idx, or the device never associated)"
fi

# --- 5. bridge netfilter is not diverting the bridge ---------------------------
if bridge_nf_ok; then
  add "bridge_nf" true "bridge-nf-call-iptables is off"
else
  add "bridge_nf" false "bridge-nf-call-iptables=1: TPROXY matches but never delivers; run: echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables"
fi

# --- 6. nftables: table, this SSID's chain, the vmap entry, counters -----------
nftdump="$(nft list table inet sbproxy 2>/dev/null)"
if [ -z "$nftdump" ]; then
  add "nft_table" false "table inet sbproxy is not loaded (sbproxy init did not run / nft failed)"
else
  add "nft_table" true "table inet sbproxy is loaded"
  if printf '%s' "$nftdump" | grep -q "chain w$idx "; then
    add "nft_chain" true "chain w$idx exists"
  else
    add "nft_chain" false "chain w$idx is missing from the table (stale ruleset: re-run apply)"
  fi
  if printf '%s' "$nftdump" | grep -q "\"br-w$idx\" : jump w$idx"; then
    add "nft_vmap" true "prerouting vmap routes br-w$idx to chain w$idx"
  else
    add "nft_vmap" false "br-w$idx is not in the prerouting vmap (traffic from this SSID is never classified)"
  fi
  if printf '%s' "$nftdump" | grep -q "tproxy ip to :$tp"; then
    add "nft_tproxy" true "tproxy rule to :$tp is present"
  else
    add "nft_tproxy" false "no tproxy rule to :$tp in chain w$idx"
  fi
fi

# --- 7. policy routing for marked packets ---------------------------------------
mark="${TPROXY_MARK:-1}"; table="${TPROXY_TABLE:-100}"
if ip rule 2>/dev/null | grep -q "fwmark 0x$(printf '%x' "$mark")"; then
  add "ip_rule" true "fwmark rule for mark $mark exists"
else
  add "ip_rule" false "no 'ip rule fwmark $mark' (marked packets fall to the main table and leave the router unproxied or are dropped)"
fi
if ip route show table "$table" 2>/dev/null | grep -q '^local'; then
  add "ip_route" true "table $table has the local route"
else
  add "ip_route" false "route table $table is empty (needs 'local default dev lo table $table')"
fi

# --- 8. sing-box is running and listening on this SSID's TPROXY port -------------
if command -v uci >/dev/null 2>&1 && uci -q get sing-box.main >/dev/null 2>&1; then
  if [ "$(uci -q get sing-box.main.enabled 2>/dev/null)" = "1" ]; then
    add "singbox_service" true "service enabled in /etc/config/sing-box"
  else
    add "singbox_service" false "/etc/config/sing-box has enabled=0, so '/etc/init.d/sing-box restart' starts nothing; re-run apply (0.5.17+) or: uci set sing-box.main.enabled=1; uci commit sing-box; /etc/init.d/sing-box restart"
  fi
fi
if pgrep -f sing-box >/dev/null 2>&1; then
  add "singbox_process" true "sing-box is running (pid $(pgrep -f sing-box | head -n1))"
  if netstat -ln 2>/dev/null | grep -q ":$tp "; then
    add "singbox_listen" true "listening on :$tp"
  else
    add "singbox_listen" false "sing-box is running but nothing listens on :$tp (config.json does not carry this SSID; re-run apply)"
  fi
else
  add "singbox_process" false "sing-box is NOT running (crashed at start? see singbox_log)"
fi
if [ -f /etc/sing-box/config.json ]; then
  if ( singbox_check /etc/sing-box/config.json ) >/dev/null 2>&1; then
    add "singbox_config" true "config.json passes sing-box check"
  else
    add "singbox_config" false "config.json fails sing-box check: $( (singbox_check /etc/sing-box/config.json) 2>&1 | tail -n 2 | tr '\n' ' ' | cut -c1-200)"
  fi
fi

# --- 9. the proxy itself, from the router ------------------------------------------
# When the SSID runs a pool, the pool slots carry the traffic and the conf
# proxy is only the fallback — a dead fallback must not become the verdict.
# Probe the conf proxy always, but let it fail the walk only when it is the
# proxy actually in use; with a pool, probe slot 0 as the representative.
npool="$(pool_count "$idx" 2>/dev/null || echo 0)"; npool="${npool:-0}"
probe="$(sh "$SB_ROOT/scripts/probe-proxy.sh" "$host" "$port" "$user" "$pass" "$ptype" 2>/dev/null)"
pverdict="$(printf '%s' "$probe" | jq -r '.verdict // ""' 2>/dev/null)"
pstate="$(printf '%s' "$probe" | jq -r '.state // "fail"' 2>/dev/null)"
if [ "$pstate" = ok ]; then
  add "proxy" true "$pverdict"
elif [ "$npool" -gt 0 ]; then
  add "proxy" true "conf fallback proxy fails (${pverdict:-probe failed}) — not the verdict: $npool pool slot(s) carry this SSID's traffic"
else
  add "proxy" false "${pverdict:-probe failed}"
fi
if [ "$npool" -gt 0 ]; then
  slot0="$(pool_rows "$idx" | head -n 1)"
  s_type="$(printf '%s' "$slot0" | cut -d'|' -f2)"
  s_host="$(printf '%s' "$slot0" | cut -d'|' -f3 | tr -d ' ')"
  s_port="$(printf '%s' "$slot0" | cut -d'|' -f4 | tr -d ' ')"
  s_user="$(printf '%s' "$slot0" | cut -d'|' -f5)"
  s_pass="$(printf '%s' "$slot0" | cut -d'|' -f6)"
  sprobe="$(sh "$SB_ROOT/scripts/probe-proxy.sh" "$s_host" "$s_port" "$s_user" "$s_pass" "${s_type:-socks5}" 2>/dev/null)"
  sverdict="$(printf '%s' "$sprobe" | jq -r '.verdict // ""' 2>/dev/null)"
  sstate="$(printf '%s' "$sprobe" | jq -r '.state // "fail"' 2>/dev/null)"
  if [ "$sstate" = ok ]; then
    add "pool_proxy" true "slot 0 ($s_host:$s_port) works: $sverdict"
  else
    add "pool_proxy" false "slot 0 ($s_host:$s_port) fails: ${sverdict:-probe failed} — test the remaining $((npool - 1)) slot(s) with Test proxy"
  fi
  add "pool" true "$npool pool slot(s) on ports $(pool_port "$idx" 0)..$(pool_port "$idx" $((npool - 1)))"
fi

# --- 10. what sing-box has been saying ------------------------------------------------
sblog=""
command -v logread >/dev/null 2>&1 && sblog="$(logread -e sing-box 2>/dev/null | tail_txt 25)"
sblog="$(mask_secret "$sblog" "$pass")"
if printf '%s' "$sblog" | grep -qi 'FATAL\|panic\|dial.*error\|connection refused\|i/o timeout'; then
  add "singbox_log" false "sing-box log shows errors (see singbox_log)"
else
  add "singbox_log" true "no recent errors in the sing-box log"
fi

# --- 11. traffic seen from the subnet (are packets even reaching the router?) --------
ct=0
[ -r /proc/net/nf_conntrack ] && ct="$(grep -c "src=$subnet\." /proc/net/nf_conntrack 2>/dev/null)"
add "conntrack" true "$ct connection(s) tracked from $subnet.0/24"

[ -n "$verdict" ] || verdict="ok: every link on the data path looks healthy; if a device still has no Internet, test the pool slot it is pinned to and check the device's own DNS/proxy settings"
report="$(printf '%s' "$checks" | jq -r '.[] | (if .ok then "  ok   " else "  FAIL " end) + .name + " — " + .detail')"
jq -n --argjson idx "$idx" --arg ssid "$ssid" --argjson c "$checks" --arg v "$verdict" \
      --arg report "$report" --arg sblog "$sblog" --argjson probe "${probe:-null}" \
      '{ok:true, idx:$idx, ssid:$ssid, verdict:$v, checks:$c, report:$report, singbox_log:$sblog, probe:$probe}'
