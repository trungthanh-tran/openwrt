#!/bin/sh
# Make one logical interface the router's Internet uplink.
#
#   switch-gateway.sh <interface>
#
# OpenWrt keeps every default route netifd learns; the one with the lowest
# metric wins. This gives the chosen interface metric 0 and pushes every other
# interface that carries a default route behind it (metric 100+), commits, and
# reloads the network so netifd re-installs the routes. The choice is then
# pinned as GATEWAY_EXPECTED_INTERFACE so gateway.sh reports a mismatch if the
# router ever drifts back. Nothing about the SSIDs or the proxies changes.
set -u
SB_ROOT="${SB_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ENV_FILE="${ENV_FILE:-/etc/sbproxy/env}"
FALLBACK_METRIC="${GATEWAY_FALLBACK_METRIC:-100}"
NETWORK_RELOAD="${NETWORK_RELOAD:-/etc/init.d/network reload}"

fail() { printf '{"ok":false,"error":%s}\n' "$(printf '%s' "$1" | jq -R .)"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"missing jq"}'; exit 1; }
command -v ubus >/dev/null 2>&1 && command -v uci >/dev/null 2>&1 || fail "ubus/uci are required"

want="${1:-}"
case "$want" in
  "") fail "interface name is required" ;;
  *[!A-Za-z0-9_.-]*) fail "interface name may only use letters, digits, . _ -" ;;
esac
[ "${#want}" -le 32 ] || fail "interface name is longer than 32 characters"

status="$(ubus call "network.interface.$want" status 2>/dev/null)" || fail "interface $want does not exist"
device="$(printf '%s' "$status" | jq -r '.l3_device // .device // ""')"
case "$device" in br-w[0-9]*) fail "$want is a proxied SSID bridge; the uplink cannot go through it" ;; esac
[ "$(printf '%s' "$status" | jq -r '.up // false')" = "true" ] || fail "interface $want is down"
has_default="$(printf '%s' "$status" | jq -r \
  '[(.route // [])[] | select(((.target // "") == "0.0.0.0") and ((.mask // 0) == 0))] | length > 0')"
[ "$has_default" = "true" ] || fail "interface $want has no default route; it cannot be the uplink"

# Every other interface that offers a default route steps behind the choice.
dump="$(ubus call network.interface dump 2>/dev/null || true)"
others="$(printf '%s' "$dump" | jq -r --arg want "$want" '
  [ .interface[]?
    | select((.interface // "") != $want and (.interface // "") != "")
    | select(((.l3_device // .device // "") | startswith("br-w")) | not)
    | select(([ (.route // [])[] | select(((.target // "") == "0.0.0.0") and ((.mask // 0) == 0)) ] | length) > 0)
    | .interface ] | .[]' 2>/dev/null)"

# A failure after `uci set` must not leave half-staged metrics behind: the
# next unrelated `uci commit network` would flush them.
fail_revert() { uci revert network 2>/dev/null || true; fail "$1"; }

changed=""
for other in $others; do
  # Interfaces that exist only in ubus (dynamic: vpn, hotplug modems) have no
  # uci section to carry a metric — skip them instead of failing the switch.
  uci -q get "network.$other" >/dev/null 2>&1 || continue
  current="$(uci -q get "network.$other.metric" 2>/dev/null || true)"
  if [ -z "$current" ] || [ "$current" -lt "$FALLBACK_METRIC" ] 2>/dev/null; then
    uci set "network.$other.metric=$FALLBACK_METRIC" || fail_revert "cannot set metric on $other"
    changed="$changed $other"
  fi
done
current="$(uci -q get "network.$want.metric" 2>/dev/null || true)"
if [ -n "$current" ] && [ "$current" != "0" ]; then
  uci set "network.$want.metric=0" || fail_revert "cannot set metric on $want"
  changed="$changed $want"
fi
if [ -n "$changed" ]; then
  uci commit network || fail_revert "uci commit failed"
  $NETWORK_RELOAD >/dev/null 2>&1 || fail "network reload failed"
fi

# Pin the expectation so the gateway check agrees with the operator.
mkdir -p "$(dirname "$ENV_FILE")" 2>/dev/null
tmp="$ENV_FILE.$$"
{
  [ -f "$ENV_FILE" ] && awk '!/^[[:space:]]*GATEWAY_EXPECTED_INTERFACE=/' "$ENV_FILE"
  printf 'GATEWAY_EXPECTED_INTERFACE=%s\n' "$want"
} > "$tmp" 2>/dev/null && cat "$tmp" > "$ENV_FILE" 2>/dev/null || { rm -f "$tmp"; fail "cannot write $ENV_FILE"; }
rm -f "$tmp"

# `jq -R` on empty input prints nothing at all, and an empty --argjson value
# is a jq usage error — a router already on the right uplink would answer a
# false failure. Default the empty case to [] explicitly.
changed_json="$(printf '%s' "${changed# }" | jq -R 'split(" ") | map(select(. != ""))')"
[ -n "$changed_json" ] || changed_json='[]'
jq -n --arg interface "$want" --arg device "$device" \
  --argjson changed "$changed_json" \
  '{ok:true, interface:$interface, device:$device, changed:$changed}'
