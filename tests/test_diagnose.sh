#!/bin/sh
# tests/test_diagnose.sh — scripts/diagnose-ssid.sh against a stubbed router.
# Every tool the script consults (nft, ip, pgrep, netstat, iw, ubus, logread,
# curl) is a stub driven by environment variables, so each broken link on
# the data path can be produced on a workstation and the verdict checked.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/config"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no()   { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want[$3] got[$2]"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  echo "== diagnose =="; printf '  skip (jq is not installed)\n'; echo "DIAGNOSE TOTAL: pass=0 fail=0 skip=1"; exit 0
fi

# A router root with the real lib.sh and probe-proxy.sh, and a one-SSID conf.
SB="$TMP/sbproxy"; mkdir -p "$SB/scripts" "$SB/config"
cp "$ROOT/scripts/lib.sh" "$ROOT/scripts/diagnose-ssid.sh" "$ROOT/scripts/probe-proxy.sh" "$SB/scripts/"
cp "$ROOT/config/settings.sh" "$SB/config/settings.sh"
printf 'hiki|5g|1|password12|proxy.example|1080|u|hunter2|1|1||socks5\n' > "$SB/config/wifi-socks.conf"
LEASES="$TMP/dhcp.leases"; printf '1 aa:bb:cc:dd:ee:ff 192.168.11.23 phone *\n' > "$LEASES"

for tool in nft ip pgrep netstat iw logread; do
  cat > "$BIN/$tool" <<SH
#!/bin/sh
tool=$tool
SH
  cat >> "$BIN/$tool" <<'SH'
case "$tool" in
  nft)     [ "${NFT_LOADED:-1}" = 1 ] || exit 1
           printf 'table inet sbproxy {\n  chain prerouting {\n    iifname vmap { "br-w1" : jump w1 }\n  }\n  chain w1 {\n    meta l4proto { tcp, udp } tproxy ip to :12001 meta mark set 1 accept\n  }\n}\n' ;;
  ip)      case "$*" in
             *"addr show br-w1"*) [ "${BRIDGE_UP:-1}" = 1 ] && echo "    inet 192.168.11.1/24 brd 192.168.11.255 scope global br-w1" ;;
             rule*) [ "${IP_RULE:-1}" = 1 ] && echo "32765:	from all fwmark 0x1 lookup 100" ;;
             "route show table 100"*) [ "${IP_ROUTE:-1}" = 1 ] && echo "local default dev lo scope host" ;;
           esac ;;
  pgrep)   [ "${SINGBOX_RUNNING:-1}" = 1 ] && { echo 4242; exit 0; }; exit 1 ;;
  netstat) [ "${SINGBOX_LISTEN:-1}" = 1 ] && echo "tcp        0      0 0.0.0.0:12001           0.0.0.0:*               LISTEN" ;;
  iw)      printf 'Station aa:bb:cc:dd:ee:ff (on phy0-ap0)\n' ;;
  logread) printf '%s\n' "${SINGBOX_LOG:-INFO sing-box started}" ;;
esac
exit 0
SH
done
# ubus: the wifi-iface for w1 exists unless WIFI_DOWN=1.
cat > "$BIN/ubus" <<'SH'
#!/bin/sh
[ "${WIFI_DOWN:-0}" = 1 ] && { echo '{}'; exit 0; }
echo '{"radio0":{"interfaces":[{"section":"w1","ifname":"phy0-ap0"}]}}'
SH
# curl: proxy probe outcome from PROXY_STATE; side checks always succeed.
cat > "$BIN/curl" <<'SH'
#!/bin/sh
proxy=""; url=""
while [ "$#" -gt 0 ]; do case "$1" in -x) proxy="$2"; shift 2;; -o|-m|-w) shift 2;; -*) shift;; *) url="$1"; shift;; esac; done
if [ -z "$proxy" ]; then
  case "$url" in http://proxy.example:*) [ "${PROXY_STATE:-ok}" = blocked ] && exit 7; exit 52;; *ipify*) printf '198.51.100.7'; exit 0;; *) printf '204 0.050'; exit 0;; esac
fi
case "${PROXY_STATE:-ok}" in
  ok) printf '204 0.120'; exit 0 ;;
  *) echo "curl: (7) Failed to connect to proxy.example port 1080: Connection refused" >&2; exit 7 ;;
esac
SH
# uci: the sing-box service flag, driven by SINGBOX_ENABLED.
cat > "$BIN/uci" <<'SH'
#!/bin/sh
[ "$1" = "-q" ] && shift
case "$2" in
  sing-box.main) exit 0 ;;
  sing-box.main.enabled) echo "${SINGBOX_ENABLED:-1}"; exit 0 ;;
esac
exit 1
SH
# sing-box binary for singbox_check.
cat > "$BIN/sing-box" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$BIN"/*
mkdir -p "$TMP/etc/sing-box"; : > "$TMP/etc/sing-box/config.json"
export PATH="$BIN:$PATH"

run() { ( cd "$SB" && DHCP_LEASES="$LEASES" "$@" sh scripts/diagnose-ssid.sh 1 2>/dev/null ); }
field() { printf '%s' "$1" | jq -r "$2"; }
check_ok() { printf '%s' "$1" | jq -r --arg n "$2" '.checks[] | select(.name == $n) | .ok'; }

echo "== diagnose: a healthy SSID =="
out="$(run env BRNF_PATH=/nonexistent)"
eq "answer is ok"                  "$(field "$out" .ok)" "true"
eq "ssid is named"                 "$(field "$out" .ssid)" "hiki"
eq "wifi link passes"              "$(check_ok "$out" wifi)" "true"
eq "bridge link passes"            "$(check_ok "$out" bridge)" "true"
eq "nft vmap passes"               "$(check_ok "$out" nft_vmap)" "true"
eq "tproxy rule passes"            "$(check_ok "$out" nft_tproxy)" "true"
eq "sing-box listener passes"      "$(check_ok "$out" singbox_listen)" "true"
eq "proxy passes"                  "$(check_ok "$out" proxy)" "true"
eq "verdict is ok"                 "$(field "$out" .verdict | cut -d: -f1)" "ok"
eq "report is rendered"            "$(field "$out" .report | grep -c '^  ok')" "$(field "$out" '[.checks[] | select(.ok)] | length')"

echo "== diagnose: each broken link is named first =="
out="$(run env BRNF_PATH=/nonexistent WIFI_DOWN=1)"
eq "no wifi-iface -> wifi verdict"     "$(field "$out" .verdict | cut -d: -f1)" "wifi"
out="$(run env BRNF_PATH=/nonexistent BRIDGE_UP=0)"
eq "no bridge address -> bridge"       "$(field "$out" .verdict | cut -d: -f1)" "bridge"
printf '%s\n' "1" > "$TMP/brnf"
out="$(run env BRNF_PATH="$TMP/brnf")"
eq "bridge-nf=1 -> bridge_nf"          "$(field "$out" .verdict | cut -d: -f1)" "bridge_nf"
out="$(run env BRNF_PATH=/nonexistent NFT_LOADED=0)"
eq "no nft table -> nft_table"         "$(field "$out" .verdict | cut -d: -f1)" "nft_table"
out="$(run env BRNF_PATH=/nonexistent IP_RULE=0)"
eq "no fwmark rule -> ip_rule"         "$(field "$out" .verdict | cut -d: -f1)" "ip_rule"
out="$(run env BRNF_PATH=/nonexistent SINGBOX_RUNNING=0)"
eq "sing-box down -> singbox_process"  "$(field "$out" .verdict | cut -d: -f1)" "singbox_process"
out="$(run env BRNF_PATH=/nonexistent SINGBOX_ENABLED=0 SINGBOX_RUNNING=0)"
eq "service disabled -> singbox_service first" "$(field "$out" .verdict | cut -d: -f1)" "singbox_service"
eq "service verdict tells the uci fix"  "$(field "$out" .verdict | grep -c 'sing-box.main.enabled=1')" "1"
out="$(run env BRNF_PATH=/nonexistent SINGBOX_LISTEN=0)"
eq "no listener -> singbox_listen"     "$(field "$out" .verdict | cut -d: -f1)" "singbox_listen"
out="$(run env BRNF_PATH=/nonexistent PROXY_STATE=blocked)"
eq "dead proxy -> proxy"               "$(field "$out" .verdict | cut -d: -f1)" "proxy"
eq "proxy verdict says blocked"        "$(field "$out" .verdict | grep -c blocked)" "1"
eq "probe is embedded"                 "$(field "$out" .probe.checks.public_ip)" "198.51.100.7"
out="$(run env BRNF_PATH=/nonexistent SINGBOX_LOG='ERROR dial tcp: connection refused (hunter2)')"
eq "sing-box errors -> singbox_log"    "$(field "$out" .verdict | cut -d: -f1)" "singbox_log"
eq "password is blanked in the log"    "$(field "$out" .singbox_log | grep -c hunter2)" "0"

echo "== diagnose: a padded conf row still parses field-by-field =="
# Trimming the idx column used to make awk rebuild the row with spaces, so
# every later cut -d'|' saw ONE field: wrong host/port, and the Wi-Fi key and
# proxy password leaking verbatim into the report.
printf 'hiki|5g| 1 |password12|proxy.example| 1080 |u|hunter2|1|1||socks5\n' > "$SB/config/wifi-socks.conf"
out="$(run env BRNF_PATH=/nonexistent)"
eq "padded idx is still found"          "$(field "$out" .ssid)" "hiki"
eq "host and port parse correctly"      "$(printf '%s' "$out" | jq -r '.checks[] | select(.name == "config") | .detail' | grep -c 'proxy.example:1080')" "1"
eq "the wifi key never enters the report" "$(field "$out" .report | grep -c password12)" "0"
eq "the proxy password never enters the report" "$(field "$out" .report | grep -c hunter2)" "0"
eq "the padded row still ends healthy"  "$(field "$out" .verdict | cut -d: -f1)" "ok"
printf 'hiki|5g|1|password12|proxy.example|1080|u|hunter2|1|1||socks5\n' > "$SB/config/wifi-socks.conf"

echo "== diagnose: a pool carries the SSID; the conf proxy is only the fallback =="
printf '1|socks5|pool1.example|2080|pu|pp|lbl\n1|socks5|pool2.example|2081|||\n' > "$SB/config/proxy-pools.conf"
out="$(run env BRNF_PATH=/nonexistent PROXY_STATE=blocked)"
eq "a dead conf proxy is not the verdict"  "$(field "$out" .verdict | cut -d: -f1)" "pool_proxy"
eq "the conf check explains the demotion"  "$(printf '%s' "$out" | jq -r '.checks[] | select(.name == "proxy") | .detail' | grep -c 'pool slot')" "1"
eq "slot 0 is probed and named"            "$(printf '%s' "$out" | jq -r '.checks[] | select(.name == "pool_proxy") | .detail' | grep -c 'pool1.example:2080')" "1"
out="$(run env BRNF_PATH=/nonexistent)"
eq "a healthy pool keeps the ok verdict"   "$(field "$out" .verdict | cut -d: -f1)" "ok"
eq "pool slots are counted"                "$(printf '%s' "$out" | jq -r '.checks[] | select(.name == "pool") | .detail' | grep -c '2 pool slot')" "1"
rm -f "$SB/config/proxy-pools.conf"

echo "== diagnose: unknown idx =="
out="$(cd "$SB" && sh scripts/diagnose-ssid.sh 7 2>/dev/null)"
eq "unknown idx -> config verdict"     "$(field "$out" .verdict | cut -d: -f1)" "config"
out="$(cd "$SB" && sh scripts/diagnose-ssid.sh 'x;y' 2>/dev/null)"
eq "dirty idx is refused"              "$(field "$out" .ok)" "false"

echo
echo "DIAGNOSE TOTAL: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
