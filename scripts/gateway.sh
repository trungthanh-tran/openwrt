#!/bin/sh
# Report the route used by unmarked router traffic and verify direct Internet
# access through that device. Read-only; intended for the Agent and diagnostics.
set -u

# Which logical interface the router is expected to leave through. Empty means
# "whatever the default route uses is fine", which is the right answer for a
# wired WAN, a PPPoE session, an LTE stick or Wi-Fi-as-WAN alike. Set it in
# /etc/sbproxy/env only when one specific uplink must be enforced.
EXPECTED_INTERFACE="${GATEWAY_EXPECTED_INTERFACE-}"
ROUTE_TARGET="${GATEWAY_ROUTE_TARGET:-1.1.1.1}"
DNS_NAME="${GATEWAY_DNS_NAME:-openwrt.org}"
PROBE_URL="${GATEWAY_PROBE_URL:-https://www.gstatic.com/generate_204}"
PROBE_TIMEOUT="${GATEWAY_PROBE_TIMEOUT:-8}"

command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"missing jq"}'; exit 1; }

route_line="$(ip -4 route get "$ROUTE_TARGET" 2>/dev/null | head -n 1)"
field_after() {
  printf '%s\n' "$route_line" | awk -v key="$1" '{for(i=1;i<NF;i++) if($i==key){print $(i+1); exit}}'
}

device="$(field_after dev)"
gateway="$(field_after via)"
source_ip="$(field_after src)"
route_ok=false
[ -n "$route_line" ] && [ -n "$device" ] && route_ok=true

logical_interface=""
actual_up=false
interfaces=""
if command -v ubus >/dev/null 2>&1; then
  dump="$(ubus call network.interface dump 2>/dev/null || true)"
  # Several logical interfaces can share one device (wan and wan6 on eth1).
  # The route being checked is IPv4, so the one holding an IPv4 address is
  # the uplink; its dhcpv6 sibling must not be reported as "in use".
  if [ -n "$dump" ] && [ -n "$device" ]; then
    _match='[.interface[]? | select((.l3_device // "") == $dev or (.device // "") == $dev)]
            | sort_by([(((.["ipv4-address"] // []) | length) == 0), ((.up // false) | not)])'
    logical_interface="$(printf '%s' "$dump" | jq -r --arg dev "$device"       "$_match"' | .[0].interface // empty' 2>/dev/null)"
    actual_up="$(printf '%s' "$dump" | jq -r --arg dev "$device"       "$_match"' | .[0].up // false' 2>/dev/null)"
  fi
    # Every logical interface the router knows, so a console can offer the choice
  # instead of anyone hard-coding a name here. `current` marks the one carrying
  # the traffic right now, which is what "automatic" resolves to.
  interfaces="$(printf '%s' "$dump" | jq -c --arg current "$logical_interface" '
    [ .interface[]?
      | { name: (.interface // ""),
          device: (.l3_device // .device // ""),
          proto: (.proto // ""),
          up: (.up // false),
          ipv4: (((.["ipv4-address"] // [])[0] // {}).address // ""),
          default_route: ([ (.route // [])[]
                            | select(((.target // "") == "0.0.0.0") and ((.mask // 0) == 0)) ]
                          | length > 0),
          current: (((.interface // "") == $current) and ($current != "")) }
      | select(.name != "" and .name != "loopback")
      | . + { proxied: (.device | startswith("br-w")) }
    ]' 2>/dev/null || true)"
  expected_status="$(ubus call "network.interface.$EXPECTED_INTERFACE" status 2>/dev/null || true)"
  expected_device="$(printf '%s' "$expected_status" | jq -r '.l3_device // .device // empty' 2>/dev/null)"
else
  expected_device=""
fi
printf '%s' "${interfaces:-}" | jq -e 'type == "array"' >/dev/null 2>&1 || interfaces='[]'
[ -n "$logical_interface" ] || { [ -n "$device" ] && [ "$device" = "$expected_device" ] && logical_interface="$EXPECTED_INTERFACE"; }

operstate=""
[ -n "$device" ] && [ -r "/sys/class/net/$device/operstate" ] && operstate="$(cat "/sys/class/net/$device/operstate" 2>/dev/null)"
link_ok=false
case "$operstate" in up|unknown) link_ok=true ;; esac
[ "$actual_up" = "true" ] && link_ok=true

# Traffic leaving through one of the project's own SSID bridges means the
# router is routing its uplink back into a proxied network: a loop, and the one
# egress that is always wrong no matter how the WAN is built.
egress_problem=""
case "$device" in
  br-w[0-9]*) egress_problem=proxied-bridge ;;
esac

expected_active=false
if [ -n "$egress_problem" ]; then
  expected_active=false
elif [ -z "$EXPECTED_INTERFACE" ] || [ "$logical_interface" = "$EXPECTED_INTERFACE" ] || \
   { [ -n "$expected_device" ] && [ "$device" = "$expected_device" ]; }; then
  expected_active=true
else
  egress_problem=not-expected
fi

dns_checked=false
dns_ok=false
if command -v nslookup >/dev/null 2>&1; then
  dns_checked=true
  nslookup "$DNS_NAME" >/dev/null 2>&1 && dns_ok=true
fi

http_ok=false
http_code=0
latency_ms=0
if command -v curl >/dev/null 2>&1 && [ "$route_ok" = "true" ]; then
  if [ -n "$device" ]; then
    result="$(curl -4 -sS -o /dev/null -m "$PROBE_TIMEOUT" --interface "$device" \
      -w '%{http_code} %{time_total}' "$PROBE_URL" 2>/dev/null || true)"
  else
    result="$(curl -4 -sS -o /dev/null -m "$PROBE_TIMEOUT" \
      -w '%{http_code} %{time_total}' "$PROBE_URL" 2>/dev/null || true)"
  fi
  http_code="$(printf '%s' "$result" | awk '{print $1}')"
  elapsed="$(printf '%s' "$result" | awk '{print $2}')"
  case "$http_code" in 200|204|301|302) http_ok=true ;; *) http_code=0 ;; esac
  case "$elapsed" in
    ''|*[!0-9.]*) latency_ms=0 ;;
    *) latency_ms="$(awk -v t="$elapsed" 'BEGIN{printf "%d", (t*1000)+0.5}')" ;;
  esac
fi

state=down
if [ "$route_ok" = "true" ] && [ "$link_ok" = "true" ]; then
  state=degraded
  [ "$expected_active" = "true" ] && [ "$dns_ok" = "true" ] && [ "$http_ok" = "true" ] && state=ok
fi

jq -n \
  --arg state "$state" --arg expected_interface "$EXPECTED_INTERFACE" \
  --arg interface "$logical_interface" --arg device "$device" \
  --arg gateway "$gateway" --arg source_ip "$source_ip" --arg operstate "$operstate" \
  --arg route "$route_line" --arg probe_url "$PROBE_URL" \
  --arg egress_problem "$egress_problem" \
  --argjson interfaces "$interfaces" \
  --argjson route_ok "$route_ok" --argjson link_ok "$link_ok" \
  --argjson expected_active "$expected_active" --argjson dns_checked "$dns_checked" \
  --argjson dns_ok "$dns_ok" --argjson http_ok "$http_ok" \
  --argjson http_code "${http_code:-0}" --argjson latency_ms "${latency_ms:-0}" \
  --argjson checked_at "$(date +%s)" \
  '{ok:true,state:$state,expected_interface:$expected_interface,interface:$interface,
    device:$device,gateway:$gateway,source_ip:$source_ip,operstate:$operstate,
    route:$route,route_ok:$route_ok,link_ok:$link_ok,expected_active:$expected_active,
    egress_problem:$egress_problem,interfaces:$interfaces,
    dns_checked:$dns_checked,dns_ok:$dns_ok,http_ok:$http_ok,http_code:$http_code,
    latency_ms:$latency_ms,probe_url:$probe_url,checked_at:$checked_at}'
