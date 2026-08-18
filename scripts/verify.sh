#!/bin/sh
# Run read-only acceptance checks after applying the configuration.
set -u

# Pick up SINGBOX_COMPAT_ENV so `sing-box check` accepts the legacy syntax.
# shellcheck source=/dev/null
[ -f /etc/sbproxy.env ] && . /etc/sbproxy.env

fail=0
check() {
  label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '[OK] %s\n' "$label"
  else
    printf '[FAIL] %s\n' "$label" >&2
    fail=$((fail + 1))
  fi
}

check 'sing-box process is running' pgrep -f sing-box
check 'sing-box configuration is valid' sh -c "env ${SINGBOX_COMPAT_ENV:-} sing-box check -c /etc/sing-box/config.json"
check 'sing-box service has compat env' sh -c "grep -q 'procd_set_param env ENABLE_DEPRECATED' /etc/init.d/sing-box || [ -z '${SINGBOX_COMPAT_ENV:-}' ]"
check 'sbproxy nftables table exists' nft list table inet sbproxy
check 'fake-IP DNS block present in sing-box config' grep -q '"fakeip"' /etc/sing-box/config.json
check 'DNS hijack rules loaded' sh -c "nft list chain inet sbproxy prerouting | grep -q 'dport 53'"
check 'TPROXY policy rule exists' sh -c "ip rule | grep -q '0x1'"
check 'TPROXY route table exists' sh -c "ip route show table 100 | grep -q ."
check 'managed Wi-Fi interfaces exist' sh -c "iw dev | grep -q 'ssid'"

if [ "$fail" -ne 0 ]; then
  printf '%s check(s) failed. Run scripts/diagnose.sh for details.\n' "$fail" >&2
  exit 1
fi
echo 'Router-side acceptance checks passed. Complete the client leak tests in docs/TESTING.md.'
