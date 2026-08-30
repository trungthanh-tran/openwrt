#!/bin/sh
# doctor.sh — one-shot, read-only health report across every subsystem.
# Complements verify.sh (pass/fail acceptance) and diagnose.sh (raw evidence):
# doctor prints a human-readable status per area and exits non-zero on any FAIL.
set -u
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"

pass=0; warn=0; failc=0
ok()  { printf '  [OK]   %s\n' "$*"; pass=$((pass + 1)); }
wn()  { printf '  [WARN] %s\n' "$*"; warn=$((warn + 1)); }
bad() { printf '  [FAIL] %s\n' "$*"; failc=$((failc + 1)); }
sec() { printf '\n== %s ==\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

sec "Platform"
if have jq && have ubus; then
  model="$(ubus call system board 2>/dev/null | jq -r '.model // empty' 2>/dev/null)"
  board="$(ubus call system board 2>/dev/null | jq -r '.board_name // empty' 2>/dev/null)"
  [ -n "$model" ] && ok "Device: $model ($board)" || wn "Could not read model/board"
else
  wn "jq/ubus is missing — skipping device detection"
fi

sec "Dependencies"
for c in nft iw jq ubus; do
  have "$c" && ok "$c is installed" || bad "$c is missing"
done
if have sing-box; then
  v="$(sing-box version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -1)"
  if [ -n "$v" ]; then
    maj="${v%%.*}"; rest="${v#*.}"; min="${rest%%.*}"
    if [ "$maj" -gt 1 ] 2>/dev/null || { [ "$maj" -eq 1 ] && [ "$min" -ge 12 ]; } 2>/dev/null; then
      ok "sing-box $v (>= 1.12, supports the new DNS syntax)"
    else
      bad "sing-box $v < 1.12 — the fake-IP DNS configuration cannot be loaded"
    fi
  else
    wn "sing-box is installed, but its version could not be read"
  fi
else
  bad "sing-box is missing"
fi

sec "wifi-socks.conf configuration"
if [ -f "$CONF" ]; then
  if ( validate_conf ) >/dev/null 2>&1; then ok "configuration is valid"; else bad "configuration is INVALID (run apply.sh for details)"; fi
  n="$(desired_idx | grep -c .)"
  ok "Managed SSIDs: ${n:-0}"
else
  wn "$CONF does not exist (copy from config/wifi-socks.conf.example)"
fi

sec "sing-box"
if pgrep -f 'sing-box' >/dev/null 2>&1; then ok "process is running"; else bad "NOT running"; fi
if uci -q get sing-box.main >/dev/null 2>&1; then
  if [ "$(uci -q get sing-box.main.enabled)" = "1" ]; then ok "service is enabled in /etc/config/sing-box"
  else bad "/etc/config/sing-box has enabled=0: the init script never starts sing-box (apply.sh fixes this)"; fi
fi
if [ -f /etc/sing-box/config.json ]; then
  if ( singbox_check /etc/sing-box/config.json ) >/dev/null 2>&1; then ok "configuration is valid (sing-box check)"; else bad "configuration is invalid (sing-box check)"; fi
  grep -q '"fakeip"' /etc/sing-box/config.json && ok "fake-IP DNS is present in the configuration" || wn "fakeip block not found in the configuration"
  [ -f "${SINGBOX_CACHE:-/etc/sing-box/cache.db}" ] && ok "fake-IP cache exists" || wn "cache.db does not exist yet (created at runtime)"
else
  bad "/etc/sing-box/config.json is missing (not applied yet?)"
fi
if [ -n "${SINGBOX_COMPAT_ENV:-}" ]; then
  grep -q 'ENABLE_DEPRECATED' /etc/init.d/sing-box 2>/dev/null && ok "compatibility environment is present in init" || wn "SINGBOX_COMPAT_ENV is set but is missing from init"
fi

sec "nftables TPROXY + DNS hijack"
if nft list table inet sbproxy >/dev/null 2>&1; then
  ok "table inet sbproxy exists"
  if nft list chain inet sbproxy prerouting 2>/dev/null | grep -q 'dport 53'; then
    ok "DNS interception rule (dport 53) is loaded"
  else
    wn "DNS interception rule for port 53 was not found (clients may leak DNS)"
  fi
else
  bad "sbproxy table is missing (has sbproxy init run?)"
fi
bridge_nf_ok && ok "br_netfilter is not diverting bridged traffic" \
  || bad "bridge-nf-call-iptables=1 — TPROXY matches but never delivers; every proxied SSID hangs"
ip rule 2>/dev/null | grep -q '0x1' && ok "fwmark policy rule exists" || bad "fwmark IP rule is missing"
ip route show table "${TPROXY_TABLE:-100}" 2>/dev/null | grep -q . && ok "route table ${TPROXY_TABLE:-100} has entries" || bad "route table ${TPROXY_TABLE:-100} is empty"

sec "Wi-Fi and device management"
ifn="$(wifi_ifaces | grep -c .)"
[ "${ifn:-0}" -gt 0 ] && ok "Broadcasting SSIDs: $ifn interface(s)" || wn "no active wifi-iface found"
h="$(ubus list 2>/dev/null | grep -c '^hostapd\.')"
[ "${h:-0}" -gt 0 ] && ok "hostapd ubus: $h instance(s) (disconnect available)" || wn "hostapd ubus not found (disconnect will fail; full wpad/hostapd is required)"
have iw && ok "iw is installed (client listing available)" || bad "iw is missing"
[ -f /tmp/dhcp.leases ] && ok "DHCP leases are readable (IP/hostname mapping)" || wn "/tmp/dhcp.leases does not exist yet"

sec "MAC bans"
bf="${BANS_FILE:-/etc/sbproxy.bans}"
if [ -f "$bf" ]; then
  nb="$(grep -c '|' "$bf" 2>/dev/null)"; ok "blocked MAC addresses: ${nb:-0}"
else
  ok "no MAC addresses are blocked"
fi

sec "Agent LAN"
[ -s /etc/sbproxy/token ] && ok "token exists" || wn "token is missing (run agent/install-agent.sh)"
[ -x /www/cgi-bin/sbproxy ] && ok "CGI is installed (/www/cgi-bin/sbproxy)" || wn "CGI is not installed"
[ -f /www/sbproxy/index.html ] && ok "self-hosted Web UI is installed" || wn "self-hosted Web UI is not installed"
pgrep -f uhttpd >/dev/null 2>&1 && ok "uhttpd is running" || wn "uhttpd is not running"
[ -x /usr/sbin/sbproxy-healthd ] && ok "healthd is installed" || wn "healthd is not installed"

sec "Summary"
printf '  OK=%d  WARN=%d  FAIL=%d\n' "$pass" "$warn" "$failc"
if [ "$failc" -eq 0 ]; then
  [ "$warn" -gt 0 ] && printf '\nConclusion: the system is basically HEALTHY (%d warning(s) require review).\n' "$warn" \
                    || printf '\nConclusion: the system is HEALTHY.\n'
  exit 0
else
  printf '\nConclusion: %d critical error(s) found — review [FAIL] above and run scripts/diagnose.sh to collect logs.\n' "$failc"
  exit 1
fi
