#!/bin/sh
# Collect troubleshooting evidence without restarting services or changing state.
set -u

# Pick up SINGBOX_COMPAT_ENV so `sing-box check` accepts the legacy syntax.
# shellcheck source=/dev/null
[ -f /etc/sbproxy.env ] && . /etc/sbproxy.env

run() {
  printf '\n== %s ==\n' "$1"
  shift
  "$@" 2>&1 || true
}

run 'System board' ubus call system board
run 'Wi-Fi status' wifi status
run 'Wi-Fi interfaces' iw dev
run 'sing-box validation' sh -c "env ${SINGBOX_COMPAT_ENV:-} sing-box check -c /etc/sing-box/config.json"
run 'sing-box processes' pgrep -af sing-box
run 'sbproxy nftables table' nft list table inet sbproxy
run 'Policy rules' ip rule
run 'Route table 100' ip route show table 100
run 'Internet gateway route/link/DNS/HTTP' sh scripts/gateway.sh
run 'Recent sing-box logs' sh -c 'logread -e sing-box | tail -n 100'
run 'Recent sbproxy logs' sh -c 'logread -e sbproxy | tail -n 100'
run 'Listening sockets' sh -c 'ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null'

# --- Fake-IP DNS path -------------------------------------------------------
run 'DNS hijack rules (must list tcp+udp dport 53 per SSID)' \
  sh -c "nft list chain inet sbproxy prerouting | grep 'dport 53'"
run 'DNS/fake-IP config summary' \
  grep -n -E '"log"|fakeip|hijack-dns|out-w|in-w|default_domain_resolver' /etc/sing-box/config.json
run 'DNS-related system logs' \
  sh -c "logread | grep -Ei 'sing-box|dns|tproxy|br-w[0-9]' | tail -n 150"
run 'fakeip block in sing-box config' grep -c '"fakeip"' /etc/sing-box/config.json
run 'compat env in sing-box init script' grep -n 'ENABLE_DEPRECATED' /etc/init.d/sing-box
run 'compat env of the RUNNING sing-box process' \
  sh -c 'p=$(pgrep -f "sing-box run" | head -1); [ -n "$p" ] && tr "\0" "\n" < "/proc/$p/environ" | grep ENABLE_DEPRECATED'
run 'fakeip cache file' ls -l /etc/sing-box/cache.db
