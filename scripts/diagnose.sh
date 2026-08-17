#!/bin/sh
# Collect troubleshooting evidence without restarting services or changing state.
set -u

run() {
  printf '\n== %s ==\n' "$1"
  shift
  "$@" 2>&1 || true
}

run 'System board' ubus call system board
run 'Wi-Fi status' wifi status
run 'Wi-Fi interfaces' iw dev
run 'sing-box validation' sing-box check -c /etc/sing-box/config.json
run 'sing-box processes' pgrep -af sing-box
run 'sbproxy nftables table' nft list table inet sbproxy
run 'Policy rules' ip rule
run 'Route table 100' ip route show table 100
run 'Recent sing-box logs' sh -c 'logread -e sing-box | tail -50'
run 'Recent sbproxy logs' sh -c 'logread -e sbproxy | tail -50'
run 'Listening sockets' sh -c 'ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null'
