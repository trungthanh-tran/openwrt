#!/bin/sh
# tests/test_gateway.sh — unit tests for scripts/gateway.sh.
#
# No router needed: ip, ubus, curl and nslookup are stubbed, so every egress
# shape (wired WAN, Wi-Fi as WAN, a pinned interface, a routing loop through a
# proxied SSID bridge, no route at all) can be exercised on a workstation.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT INT TERM

pass=0; fail=0; skip=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no()   { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want[$3] got[$2]"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  echo "== gateway =="
  printf '  skip gateway suite (jq is not installed)\n'

  echo; echo "GATEWAY TOTAL: pass=0 fail=0 skip=1"
  exit 0
fi

# ip stub: `ip -4 route get X` prints $IP_ROUTE_LINE (empty means no route).
cat > "$STUB/ip" <<'SH'
#!/bin/sh
[ -n "${IP_ROUTE_LINE:-}" ] && printf '%s\n' "$IP_ROUTE_LINE"
exit 0
SH

# ubus stub: dump answers from $UBUS_DUMP, per-interface status from
# $UBUS_STATUS_<name> so a pinned interface can resolve to a device.
cat > "$STUB/ubus" <<'SH'
#!/bin/sh
if [ "${1:-}" = "call" ] && [ "${2:-}" = "network.interface" ] && [ "${3:-}" = "dump" ]; then
  printf '%s\n' "${UBUS_DUMP:-}"; exit 0
fi
case "${2:-}" in
  network.interface.*)
    name="${2#network.interface.}"
    eval "value=\${UBUS_STATUS_${name}:-}"
    [ -n "$value" ] || exit 1
    printf '%s\n' "$value"; exit 0
    ;;
esac
exit 1
SH

# curl stub: answers with $CURL_RESULT ("<code> <seconds>").
cat > "$STUB/curl" <<'SH'
#!/bin/sh
printf '%s' "${CURL_RESULT:-204 0.26}"
exit 0
SH

# nslookup stub: succeeds unless DNS_FAILS=1.
cat > "$STUB/nslookup" <<'SH'
#!/bin/sh
[ "${DNS_FAILS:-0}" = "1" ] && exit 1
exit 0
SH
chmod +x "$STUB/ip" "$STUB/ubus" "$STUB/curl" "$STUB/nslookup"
PATH="$STUB:$PATH"; export PATH

# One interface dump covering a wired WAN and a proxied SSID bridge.
DUMP='{"interface":[
  {"interface":"wan","l3_device":"eth1","device":"eth1","up":true},
  {"interface":"w1","l3_device":"br-w1","device":"br-w1","up":true}]}'

run_gateway() {  # prints the JSON produced for the current environment
  sh "$ROOT/scripts/gateway.sh" 2>/dev/null
}

field() { printf '%s' "$1" | jq -r "$2"; }

echo "== gateway: a wired WAN is a normal uplink =="
out="$(IP_ROUTE_LINE='1.1.1.1 via 192.168.88.1 dev eth1 src 192.168.88.74 uid 0' \
       UBUS_DUMP="$DUMP" run_gateway)"
eq "state is ok"                 "$(field "$out" .state)" "ok"
eq "egress interface is resolved" "$(field "$out" .interface)" "wan"
eq "device is reported"          "$(field "$out" .device)" "eth1"
eq "the egress is accepted"      "$(field "$out" .expected_active)" "true"
eq "no egress problem"           "$(field "$out" .egress_problem)" ""
eq "no interface is enforced"    "$(field "$out" .expected_interface)" ""
eq "http result is carried"      "$(field "$out" .http_code)" "204"

echo "== gateway: wan and wan6 share the device; only the IPv4 one is in use =="
out="$(IP_ROUTE_LINE='1.1.1.1 via 192.168.88.1 dev eth1 src 192.168.88.83 uid 0'        UBUS_DUMP='{"interface":[
         {"interface":"wan6","l3_device":"eth1","device":"eth1","proto":"dhcpv6","up":true},
         {"interface":"wan","l3_device":"eth1","device":"eth1","proto":"dhcp","up":true,
          "ipv4-address":[{"address":"192.168.88.83","mask":24}]}]}'        run_gateway)"
eq "wan is resolved, not wan6"  "$(field "$out" .interface)" "wan"
eq "state is ok"                "$(field "$out" .state)" "ok"
eq "only wan is current"        "$(field "$out" '[.interfaces[] | select(.current) | .name] | join(",")')" "wan"

echo "== gateway: Wi-Fi as WAN is equally normal =="
out="$(IP_ROUTE_LINE='1.1.1.1 via 192.168.8.1 dev phy0-sta0 src 192.168.8.2 uid 0' \
       UBUS_DUMP='{"interface":[{"interface":"wwan","l3_device":"phy0-sta0","up":true}]}' \
       run_gateway)"
eq "state is ok"              "$(field "$out" .state)" "ok"
eq "wwan is resolved"         "$(field "$out" .interface)" "wwan"
eq "the egress is accepted"   "$(field "$out" .expected_active)" "true"

echo "== gateway: an enforced interface is still honoured =="
out="$(GATEWAY_EXPECTED_INTERFACE=wwan \
       IP_ROUTE_LINE='1.1.1.1 via 192.168.88.1 dev eth1 src 192.168.88.74 uid 0' \
       UBUS_DUMP="$DUMP" run_gateway)"
eq "a different uplink is degraded" "$(field "$out" .state)" "degraded"
eq "the mismatch is named"          "$(field "$out" .egress_problem)" "not-expected"
eq "the expectation is reported"    "$(field "$out" .expected_interface)" "wwan"

out="$(GATEWAY_EXPECTED_INTERFACE=wan \
       IP_ROUTE_LINE='1.1.1.1 via 192.168.88.1 dev eth1 src 192.168.88.74 uid 0' \
       UBUS_DUMP="$DUMP" run_gateway)"
eq "the enforced uplink passes" "$(field "$out" .state)" "ok"

echo "== gateway: leaving through a proxied SSID is always wrong =="
out="$(IP_ROUTE_LINE='1.1.1.1 via 192.168.11.1 dev br-w1 src 192.168.11.1 uid 0' \
       UBUS_DUMP="$DUMP" run_gateway)"
eq "a routing loop is degraded"  "$(field "$out" .state)" "degraded"
eq "the loop is named"           "$(field "$out" .egress_problem)" "proxied-bridge"
eq "the egress is not accepted"  "$(field "$out" .expected_active)" "false"

echo "== gateway: the interface list is what a console offers =="
FULL_DUMP='{"interface":[
  {"interface":"loopback","l3_device":"lo","proto":"static","up":true},
  {"interface":"lan","l3_device":"br-lan","proto":"static","up":true,
   "ipv4-address":[{"address":"192.168.1.1"}]},
  {"interface":"wan","l3_device":"eth1","proto":"dhcp","up":true,
   "ipv4-address":[{"address":"192.168.88.74"}],
   "route":[{"target":"0.0.0.0","mask":0,"nexthop":"192.168.88.1"}]},
  {"interface":"wwan","l3_device":"phy0-sta0","proto":"dhcp","up":false},
  {"interface":"w1","l3_device":"br-w1","proto":"static","up":true,
   "ipv4-address":[{"address":"192.168.11.1"}]}]}'
out="$(IP_ROUTE_LINE='1.1.1.1 via 192.168.88.1 dev eth1 src 192.168.88.74 uid 0' \
       UBUS_DUMP="$FULL_DUMP" run_gateway)"
eq "loopback is not offered"      "$(field "$out" '[.interfaces[].name] | index("loopback") // "no"')" "no"
eq "every other interface is"     "$(field "$out" '.interfaces | length')" "4"
eq "names are listed in order"    "$(field "$out" '[.interfaces[].name] | join(",")')" "lan,wan,wwan,w1"
eq "the live uplink is marked"    "$(field "$out" '[.interfaces[] | select(.current)] | .[0].name')" "wan"
eq "only one is current"          "$(field "$out" '[.interfaces[] | select(.current)] | length')" "1"
eq "its device is carried"        "$(field "$out" '[.interfaces[] | select(.name=="wan")][0].device')" "eth1"
eq "its address is carried"       "$(field "$out" '[.interfaces[] | select(.name=="wan")][0].ipv4')" "192.168.88.74"
eq "its protocol is carried"      "$(field "$out" '[.interfaces[] | select(.name=="wan")][0].proto')" "dhcp"
eq "a default route is flagged"   "$(field "$out" '[.interfaces[] | select(.name=="wan")][0].default_route')" "true"
eq "a plain LAN has no default"   "$(field "$out" '[.interfaces[] | select(.name=="lan")][0].default_route')" "false"
eq "a down interface is offered"  "$(field "$out" '[.interfaces[] | select(.name=="wwan")][0].up')" "false"
eq "a proxied SSID is marked"     "$(field "$out" '[.interfaces[] | select(.name=="w1")][0].proxied')" "true"
eq "a real uplink is not"         "$(field "$out" '[.interfaces[] | select(.name=="wan")][0].proxied')" "false"

out="$(IP_ROUTE_LINE='1.1.1.1 via 192.168.88.1 dev eth1 src 192.168.88.74 uid 0' \
       UBUS_DUMP='' run_gateway)"
eq "an empty dump still answers" "$(field "$out" '.interfaces | length')" "0"

echo "== gateway: failures still report =="
out="$(IP_ROUTE_LINE='' UBUS_DUMP="$DUMP" run_gateway)"
eq "no route means down"     "$(field "$out" .state)" "down"
eq "route_ok is false"       "$(field "$out" .route_ok)" "false"

out="$(DNS_FAILS=1 IP_ROUTE_LINE='1.1.1.1 via 192.168.88.1 dev eth1 src 192.168.88.74 uid 0' \
       UBUS_DUMP="$DUMP" run_gateway)"
eq "broken DNS is degraded"  "$(field "$out" .state)" "degraded"
eq "dns_ok is false"         "$(field "$out" .dns_ok)" "false"
eq "the egress is still fine" "$(field "$out" .egress_problem)" ""

out="$(CURL_RESULT='000 0' IP_ROUTE_LINE='1.1.1.1 via 192.168.88.1 dev eth1 src 192.168.88.74 uid 0' \
       UBUS_DUMP="$DUMP" run_gateway)"
eq "an HTTP failure is degraded" "$(field "$out" .state)" "degraded"
eq "http_ok is false"            "$(field "$out" .http_ok)" "false"


echo "== switch-gateway: the chosen interface becomes the uplink =="
cat > "$STUB/uci" <<'SH'
#!/bin/sh
[ "$1" = "-q" ] && shift
printf 'uci %s\n' "$*" >> "$UCI_LOG"
case "$1" in
  get) case "$2" in
    network.wwan.metric) echo 20 ;;
    network.wan|network.wwan) echo interface ;;   # section-existence checks
    *) exit 1 ;;
  esac ;;
esac
exit 0
SH
chmod +x "$STUB/uci"
UCI_LOG="$STUB/uci.log"; export UCI_LOG
SWITCH_ENV="$STUB/env"; printf 'FOO=1\nGATEWAY_EXPECTED_INTERFACE=wan\n' > "$SWITCH_ENV"
DEFROUTE='"route":[{"target":"0.0.0.0","mask":0,"nexthop":"192.168.8.1"}]'
SWITCH_DUMP='{"interface":[
  {"interface":"wan","l3_device":"eth1","device":"eth1","up":true,'"$DEFROUTE"'},
  {"interface":"wwan","l3_device":"phy0-sta0","up":true,'"$DEFROUTE"'},
  {"interface":"lan","l3_device":"br-lan","up":true},
  {"interface":"w1","l3_device":"br-w1","up":true,'"$DEFROUTE"'}]}'
: > "$UCI_LOG"
out="$(UBUS_DUMP="$SWITCH_DUMP" \
       UBUS_STATUS_wwan='{"interface":"wwan","l3_device":"phy0-sta0","up":true,'"$DEFROUTE"'}' \
       ENV_FILE="$SWITCH_ENV" NETWORK_RELOAD=true sh "$ROOT/scripts/switch-gateway.sh" wwan 2>/dev/null)"
eq "switch succeeds"                 "$(field "$out" .ok)" "true"
eq "the other uplink steps behind"   "$(grep -c 'uci set network.wan.metric=100' "$UCI_LOG")" "1"
eq "the choice takes metric 0"       "$(grep -c 'uci set network.wwan.metric=0' "$UCI_LOG")" "1"
eq "lan is left alone"               "$(grep -c 'network.lan' "$UCI_LOG")" "0"
eq "the proxied bridge is left alone" "$(grep -c 'network.w1' "$UCI_LOG")" "0"
eq "network is committed"            "$(grep -c 'uci commit network' "$UCI_LOG")" "1"
eq "the choice is pinned"            "$(grep -c '^GATEWAY_EXPECTED_INTERFACE=wwan$' "$SWITCH_ENV")" "1"
eq "other env keys survive"          "$(grep -c '^FOO=1$' "$SWITCH_ENV")" "1"

echo "== switch-gateway: already-correct metrics mean an empty change list, not an error =="
# wan already sits behind (metric 100), wwan already leads (metric 0): nothing
# to stage. The empty list used to hit `jq --argjson changed ""` (a jq usage
# error) and answer a false failure on a router that was already right.
cat > "$STUB/uci" <<'SH'
#!/bin/sh
[ "$1" = "-q" ] && shift
printf 'uci %s\n' "$*" >> "$UCI_LOG"
case "$1" in
  get) case "$2" in
    network.wan.metric) echo 100 ;;
    network.wwan.metric) echo 0 ;;
    network.wan|network.wwan) echo interface ;;
    *) exit 1 ;;
  esac ;;
esac
exit 0
SH
chmod +x "$STUB/uci"
: > "$UCI_LOG"
out="$(UBUS_DUMP="$SWITCH_DUMP" \
       UBUS_STATUS_wwan='{"interface":"wwan","l3_device":"phy0-sta0","up":true,'"$DEFROUTE"'}' \
       ENV_FILE="$SWITCH_ENV" NETWORK_RELOAD=true sh "$ROOT/scripts/switch-gateway.sh" wwan 2>/dev/null)"
eq "a no-op switch still succeeds"   "$(field "$out" .ok)" "true"
eq "and reports an empty changed list" "$(field "$out" '.changed | length')" "0"
eq "nothing is committed"            "$(grep -c 'uci commit' "$UCI_LOG")" "0"

echo "== switch-gateway: dynamic interfaces and staged changes =="
# An interface that exists only in ubus (no uci section) cannot carry a
# metric; it is skipped, never a reason to abort the switch.
cat > "$STUB/uci" <<'SH'
#!/bin/sh
[ "$1" = "-q" ] && shift
printf 'uci %s\n' "$*" >> "$UCI_LOG"
case "$1" in
  get) case "$2" in
    network.wwan|network.wwan.metric) [ "$2" = network.wwan ] && echo interface; [ "$2" = network.wwan.metric ] && echo 20 ;;
    *) exit 1 ;;   # wan has NO uci section at all
  esac ;;
esac
exit 0
SH
chmod +x "$STUB/uci"
: > "$UCI_LOG"
out="$(UBUS_DUMP="$SWITCH_DUMP" \
       UBUS_STATUS_wwan='{"interface":"wwan","l3_device":"phy0-sta0","up":true,'"$DEFROUTE"'}' \
       ENV_FILE="$SWITCH_ENV" NETWORK_RELOAD=true sh "$ROOT/scripts/switch-gateway.sh" wwan 2>/dev/null)"
eq "a ubus-only uplink is skipped, not fatal" "$(field "$out" .ok)" "true"
eq "no metric is forced onto it"     "$(grep -c 'uci set network.wan' "$UCI_LOG")" "0"
eq "the choice still takes metric 0" "$(grep -c 'uci set network.wwan.metric=0' "$UCI_LOG")" "1"

# A uci failure mid-flight reverts whatever was staged: the next unrelated
# `uci commit network` must not flush half a switch.
cat > "$STUB/uci" <<'SH'
#!/bin/sh
[ "$1" = "-q" ] && shift
printf 'uci %s\n' "$*" >> "$UCI_LOG"
case "$1" in
  get) case "$2" in
    network.wan|network.wwan) echo interface ;;
    network.wwan.metric) echo 20 ;;
    *) exit 1 ;;
  esac ;;
  set) case "$2" in network.wwan.metric=0) exit 1 ;; esac ;;
esac
exit 0
SH
chmod +x "$STUB/uci"
: > "$UCI_LOG"
out="$(UBUS_DUMP="$SWITCH_DUMP" \
       UBUS_STATUS_wwan='{"interface":"wwan","l3_device":"phy0-sta0","up":true,'"$DEFROUTE"'}' \
       ENV_FILE="$SWITCH_ENV" NETWORK_RELOAD=true sh "$ROOT/scripts/switch-gateway.sh" wwan 2>/dev/null)"
eq "a failed uci set answers ok:false" "$(field "$out" .ok)" "false"
eq "and the staged changes are reverted" "$(grep -c 'uci revert network' "$UCI_LOG")" "1"
eq "and nothing is committed"        "$(grep -c 'uci commit' "$UCI_LOG")" "0"

echo "== switch-gateway: refusals =="
out="$(UBUS_DUMP="$SWITCH_DUMP" UBUS_STATUS_lan='{"interface":"lan","l3_device":"br-lan","up":true}' \
       ENV_FILE="$SWITCH_ENV" NETWORK_RELOAD=true sh "$ROOT/scripts/switch-gateway.sh" lan 2>/dev/null)"
eq "no default route is refused"    "$(field "$out" .ok)" "false"
out="$(UBUS_DUMP="$SWITCH_DUMP" UBUS_STATUS_w1='{"interface":"w1","l3_device":"br-w1","up":true,'"$DEFROUTE"'}' \
       ENV_FILE="$SWITCH_ENV" NETWORK_RELOAD=true sh "$ROOT/scripts/switch-gateway.sh" w1 2>/dev/null)"
eq "a proxied bridge is refused"    "$(field "$out" .ok)" "false"
out="$(UBUS_DUMP="$SWITCH_DUMP" UBUS_STATUS_wwan='{"interface":"wwan","l3_device":"phy0-sta0","up":false,'"$DEFROUTE"'}' \
       ENV_FILE="$SWITCH_ENV" NETWORK_RELOAD=true sh "$ROOT/scripts/switch-gateway.sh" wwan 2>/dev/null)"
eq "a down interface is refused"    "$(field "$out" .ok)" "false"
out="$(UBUS_DUMP="$SWITCH_DUMP" ENV_FILE="$SWITCH_ENV" NETWORK_RELOAD=true sh "$ROOT/scripts/switch-gateway.sh" nope 2>/dev/null)"
eq "an unknown interface is refused" "$(field "$out" .ok)" "false"
out="$(UBUS_DUMP="$SWITCH_DUMP" ENV_FILE="$SWITCH_ENV" NETWORK_RELOAD=true sh "$ROOT/scripts/switch-gateway.sh" 'wan;reboot' 2>/dev/null)"
eq "a shell-looking name is refused" "$(field "$out" .ok)" "false"

echo
echo "GATEWAY TOTAL: pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ]
