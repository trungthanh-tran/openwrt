#!/bin/sh
# tests/run.sh — POSIX-sh unit + integration tests for scripts/lib.sh and the
# read-only scripts/clients.sh. No router needed: router-only tools (uci, ubus,
# iw) are stubbed; jq-dependent cases self-skip when jq is absent. Exit 1 on any
# failure.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB_ROOT="$ROOT"; export SB_ROOT

STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT INT TERM

# Smart uci stub: `uci -q get KEY` echoes KEY's value from $UCI_STATE (KEY=VALUE
# lines) or exits 1 if absent; every other uci call is a successful no-op.
cat > "$STUB/uci" <<'SH'
#!/bin/sh
if [ "${1:-}" = "-q" ] && [ "${2:-}" = "get" ]; then
  awk -F'=' -v k="${3:-}" '$1==k{sub(/^[^=]*=/,""); print; found=1; exit} END{exit found?0:1}' \
    "${UCI_STATE:-/dev/null}" 2>/dev/null
  exit $?
fi
if [ "${1:-}" = "-q" ] && [ "${2:-}" = "show" ]; then
  grep "^${3:-}\." "${UCI_STATE:-/dev/null}" 2>/dev/null
  exit 0
fi
exit 0
SH

# ubus stub: `ubus call network.wireless status` emits $UBUS_WIFI_JSON when set.
cat > "$STUB/ubus" <<'SH'
#!/bin/sh
if [ "${1:-}" = "call" ] && [ "${2:-}" = "network.wireless" ] && [ "${3:-}" = "status" ] && [ -n "${UBUS_WIFI_JSON:-}" ]; then
  cat "$UBUS_WIFI_JSON"; exit 0
fi
exit 1
SH

# iw stub: `iw dev <ifname> station dump` prints $IW_DUMP_DIR/<ifname>.txt.
cat > "$STUB/iw" <<'SH'
#!/bin/sh
if [ "${1:-}" = "dev" ] && [ "${3:-}" = "station" ] && [ "${4:-}" = "dump" ]; then
  f="${IW_DUMP_DIR:-/nonexistent}/${2}.txt"; [ -f "$f" ] && cat "$f"
fi
exit 0
SH
chmod +x "$STUB/uci" "$STUB/ubus" "$STUB/iw"
PATH="$STUB:$PATH"; export PATH

CONF="$ROOT/config/wifi-socks.conf.example"; export CONF
# shellcheck source=/dev/null
. "$ROOT/scripts/lib.sh"

pass=0; fail=0; skip=0
ok()      { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no()      { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
sk()      { skip=$((skip + 1)); printf '  skip %s (%s)\n' "$1" "$2"; }
eq()      { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want[$3] got[$2]"; fi; }
match()   { if printf '%s' "$2" | grep -Eq "$3"; then ok "$1"; else no "$1 — no /$3/"; fi; }
nomatch() { if printf '%s' "$2" | grep -Eq "$3"; then no "$1 — unexpected /$3/"; else ok "$1"; fi; }
contains() { if printf '%s' "$2" | grep -qF "$3"; then ok "$1"; else no "$1 — missing[$3]"; fi; }
not_contains() { if printf '%s' "$2" | grep -qF "$3"; then no "$1 — found[$3]"; else ok "$1"; fi; }
dies()    { if ( "$@" ) >/dev/null 2>&1; then no "$L — expected non-zero"; else ok "$L"; fi; }
mkc()     { printf '%s\n' "$1" > "$STUB/c.conf"; }
# Run a $STUB/c.conf validator (validate_conf/check_unique_idx) in a subshell so
# its die() cannot exit the test runner; assert ok|die against expectation.
vrun()    { if ( CONF="$STUB/c.conf" "$3" ) >/dev/null 2>&1; then r=ok; else r=die; fi
            if [ "$r" = "$2" ]; then ok "$1"; else no "$1 — got $r want $2"; fi; }

echo "== derived values =="
eq "net_octet 1"    "$(net_octet 1)"    "11"
eq "net_octet 30"   "$(net_octet 30)"   "40"
eq "tproxy_port 3"  "$(tproxy_port 3)"  "12003"
eq "radio_of 2g"    "$(radio_of 2g)"    "radio0"
eq "radio_of 5g"    "$(radio_of 5g)"    "radio1"
L="radio_of invalid band dies"; dies radio_of 6g

echo "== configurable resolver =="
DNS_CONF="$STUB/dns.conf"
printf '%s\n' '#' > "$DNS_CONF"
build_dns() { # upstream -> path of the generated sing-box config
  ( CONF="$DNS_CONF" DNS_UPSTREAM="$1" SINGBOX_CONF="$STUB/dns.json" \
      NFT_FILE="$STUB/dns.nft" build_singbox ) >/dev/null 2>&1
  printf '%s' "$STUB/dns.json"
}
if command -v jq >/dev/null 2>&1; then
  eq "the default resolver is 1.1.1.1" \
    "$(jq -r '.dns.servers[] | select(.tag=="upstream") | .server' "$(build_dns '')")" "1.1.1.1"
  eq "an ISP resolver is used as given" \
    "$(jq -r '.dns.servers[] | select(.tag=="upstream") | .server' "$(build_dns '9.9.9.9')")" "9.9.9.9"
  eq "a hostname resolver works too" \
    "$(jq -r '.dns.servers[] | select(.tag=="upstream") | .server' "$(build_dns 'dns.example.internal')")" \
    "dns.example.internal"
  if jq -e . "$(build_dns 'dns.example.internal')" >/dev/null 2>&1; then
    ok "the generated config stays valid JSON"
  else
    no "the generated config stays valid JSON"
  fi
else
  sk "configurable resolver" "jq is not installed"
fi
run_lib() {  # run a snippet with lib.sh already sourced
  sh -c '. "$SB_ROOT/scripts/lib.sh"; '"$1"
}
if run_lib 'WIFI_COUNTRY=VN; DNS_UPSTREAM=""; validate_settings' >/dev/null 2>&1; then
  ok "an empty resolver falls back to the default"
else
  no "an empty resolver falls back to the default"
fi
L="DNS_UPSTREAM rejects shell metacharacters"
dies run_lib 'WIFI_COUNTRY=VN; DNS_UPSTREAM="1.1.1.1;id"; validate_settings'
if run_lib 'WIFI_COUNTRY=VN; DNS_UPSTREAM="9.9.9.9"; validate_settings' >/dev/null 2>&1; then
  ok "a plain resolver passes validation"
else
  no "a plain resolver passes validation"
fi

echo "== unsupported board override =="
# ubus and /proc/device-tree/model are absent here, so the board never matches.
if run_lib 'ALLOW_UNSUPPORTED_BOARD=0; validate_platform' >/dev/null 2>&1; then
  no "an unknown board is refused by default"
else
  ok "an unknown board is refused by default"
fi
if run_lib 'ALLOW_UNSUPPORTED_BOARD=1; validate_platform' >/dev/null 2>&1; then
  ok "ALLOW_UNSUPPORTED_BOARD=1 downgrades it to a warning"
else
  no "ALLOW_UNSUPPORTED_BOARD=1 downgrades it to a warning"
fi
match "the refusal explains the override" \
  "$(run_lib 'ALLOW_UNSUPPORTED_BOARD=0; validate_platform' 2>&1)" 'ALLOW_UNSUPPORTED_BOARD=1'
match "the override still warns" \
  "$(run_lib 'ALLOW_UNSUPPORTED_BOARD=1; validate_platform' 2>&1)" 'WARN'

echo "== empty configuration =="
# A freshly provisioned router carries a comment-only wifi-socks.conf, and the
# console can legitimately be left with zero SSIDs. Both must still produce
# artifacts apply.sh accepts, or apply dies with "sing-box configuration is
# invalid" and nothing explains why.
EMPTY_CONF="$STUB/empty.conf"
grep '^#' "$ROOT/config/wifi-socks.conf.example" > "$EMPTY_CONF"
eq "the seeded file carries no SSID rows" \
  "$(grep -vc '^[[:space:]]*\(#\|$\)' "$EMPTY_CONF" || true)" "0"
( CONF="$EMPTY_CONF" validate_conf ) >/dev/null 2>&1 \
  && ok "an empty configuration validates" || no "an empty configuration validates"
if command -v jq >/dev/null 2>&1; then
  ( CONF="$EMPTY_CONF" SINGBOX_CONF="$STUB/empty.json" NFT_FILE="$STUB/empty.nft" \
      build_singbox ) >/dev/null 2>&1
  if jq -e . "$STUB/empty.json" >/dev/null 2>&1; then ok "zero SSIDs give valid sing-box JSON"
  else no "zero SSIDs give valid sing-box JSON"; fi
  eq "no inbounds without SSIDs"  "$(jq '.inbounds|length' "$STUB/empty.json")" "0"
  eq "direct outbound remains"    "$(jq '.outbounds|length' "$STUB/empty.json")" "1"
  eq "only the base route rules"  "$(jq '.route.rules|length' "$STUB/empty.json")" "2"
else
  sk "zero SSIDs give valid sing-box JSON" "jq is not installed"
fi
( CONF="$EMPTY_CONF" NFT_FILE="$STUB/empty.nft" build_nft ) >/dev/null 2>&1 \
  && ok "zero SSIDs still build an nftables ruleset" \
  || no "zero SSIDs still build an nftables ruleset"
match "the ruleset keeps its table" "$(cat "$STUB/empty.nft")" "table inet sbproxy"

echo "== radio discovery =="
radio_state() {  # write a fake UCI dump and point the stub at it
  UCI_STATE="$STUB/wireless.state"; export UCI_STATE
  printf '%s\n' "$@" > "$UCI_STATE"
}

radio_state \
  "wireless.radio0=wifi-device" "wireless.radio0.band=2g" \
  "wireless.radio1=wifi-device" "wireless.radio1.band=5g"
eq "two radios are listed in order" "$(list_radios)" "radio0 radio1 "
eq "band comes from the band option" "$(radio_band radio0)" "2g"
eq "5g radio is found by band" "$(radio_for_band 5g)" "radio1"
eq "no 6g radio on this board" "$(radio_for_band 6g)" ""

radio_state \
  "wireless.radio0=wifi-device" "wireless.radio0.band=5g" \
  "wireless.radio1=wifi-device" "wireless.radio1.band=2g" \
  "wireless.radio2=wifi-device" "wireless.radio2.band=6g"
eq "three radios are listed" "$(list_radios)" "radio0 radio1 radio2 "
eq "2.4G is not assumed to be radio0" "$(radio_for_band 2g)" "radio1"
eq "6g radio is found" "$(radio_for_band 6g)" "radio2"

radio_state \
  "wireless.wlan0=wifi-device" "wireless.wlan0.hwmode=11ng" \
  "wireless.wlan1=wifi-device" "wireless.wlan1.hwmode=11ac"
eq "radios need not be named radioN" "$(list_radios)" "wlan0 wlan1 "
eq "hwmode 11ng means 2.4G" "$(radio_band wlan0)" "2g"
eq "hwmode 11ac means 5G" "$(radio_band wlan1)" "5g"
eq "hwmode is used when band is absent" "$(radio_for_band 2g)" "wlan0"

radio_state "wireless.radio0=wifi-device"
eq "an unreadable radio reports ?" "$(radio_band radio0)" "?"

radio_state "wireless.wan=interface"
eq "no radios means an empty list" "$(list_radios)" ""
eq "no radios means no match" "$(radio_for_band 2g)" ""

echo "== settings.sh radio mapping =="
# The board here is deliberately reversed: radio0 is 5 GHz, radio1 is 2.4 GHz.
radio_state \
  "wireless.radio0=wifi-device" "wireless.radio0.band=5g" \
  "wireless.radio1=wifi-device" "wireless.radio1.band=2g"
contains "a correct mapping is confirmed" "$(check_radio_mapping 5g radio0 RADIO_5G 2>&1)" "[OK] RADIO_5G=radio0"
contains "a swapped mapping names the right radio" \
  "$(check_radio_mapping 2g radio0 RADIO_2G 2>&1)" "RADIO_2G=radio0 is a 5g radio, not 2g - use radio1"
contains "a missing radio is reported" \
  "$(check_radio_mapping 2g radio7 RADIO_2G 2>&1)" "RADIO_2G=radio7 does not exist on this board - use radio1"
contains "an unset variable is reported" \
  "$(check_radio_mapping 2g "" RADIO_2G 2>&1)" "RADIO_2G is not set in config/settings.sh - this board uses radio1"
contains "a band the board lacks warns without a suggestion" \
  "$(check_radio_mapping 6g "" RADIO_6G 2>&1)" "RADIO_6G is not set in config/settings.sh"
unset UCI_STATE

# setup-vm.sh and the VM guide both tell the operator to run
# `ALLOW_UNSUPPORTED_BOARD=1 sh scripts/apply.sh`. That only works if settings.sh
# lets an already-set value stand: lib.sh sources settings.sh *after* the
# environment is in place, so a plain assignment there overwrites what the
# operator asked for and the die message sends them to edit a tracked file.
eq "ALLOW_UNSUPPORTED_BOARD from the environment survives settings.sh" \
  "$(ALLOW_UNSUPPORTED_BOARD=1 sh -c '. "$1/config/settings.sh"; echo "$ALLOW_UNSUPPORTED_BOARD"' _ "$ROOT")" \
  "1"
eq "ALLOW_UNSUPPORTED_BOARD still defaults to 0" \
  "$(sh -c 'unset ALLOW_UNSUPPORTED_BOARD; . "$1/config/settings.sh"; echo "$ALLOW_UNSUPPORTED_BOARD"' _ "$ROOT")" \
  "0"

# br_netfilter sends bridged frames through the IP hooks a second time, and a
# TPROXY verdict taken there never reaches the local socket. The rule counts the
# packet, nothing is dropped, no counter anywhere moves -- the connection simply
# hangs. Confirmed on a real kernel: the identical ruleset works with it off and
# times out with it on. OpenWrt does not ship kmod-br-netfilter by default, so
# this only bites where something else pulled it in, and that is exactly the
# case nobody would think to look for.
BRNF="$STUB/brnf"
eq "bridge_nf_ok is quiet when br_netfilter is absent" \
  "$(BRNF_PATH="$STUB/nonexistent" bridge_nf_ok; echo $?)" "0"
echo 0 > "$BRNF"
eq "bridge_nf_ok accepts br_netfilter turned off" \
  "$(BRNF_PATH="$BRNF" bridge_nf_ok; echo $?)" "0"
echo 1 > "$BRNF"
eq "bridge_nf_ok rejects br_netfilter turned on" \
  "$(BRNF_PATH="$BRNF" bridge_nf_ok; echo $?)" "1"

echo "== uci_dquote =="
eq "escape double-quote" "$(uci_dquote 'a"b')" 'a\"b'
eq "escape backslash"    "$(uci_dquote 'a\b')" 'a\\b'
eq "plain passes through" "$(uci_dquote 'plain')" 'plain'

echo "== gen_mac =="
match "random_octets emits requested byte count" "$(random_octets 4)" '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]*$'
match "gen_mac vendor OUI prefix + 6 octets" "$(gen_mac 50:C7:BF)" '^50:c7:bf:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$'
match "gen_mac lowercases OUI"               "$(gen_mac AC:9E:17)" '^ac:9e:17:'
match "gen_mac default is locally-admin 02:" "$(gen_mac)"          '^02:([0-9a-f]{2}:){4}[0-9a-f]{2}$'

echo "== validate_conf =="
mkc 'A|2g|1|password12|1.2.3.4|1080|u|p|1|1|50:C7:BF'; vrun "accept 11-col"        ok  validate_conf
mkc 'A|2g|1|password12|1.2.3.4|8080|u|p|1|1||http';    vrun "accept HTTP 12-col"   ok  validate_conf
mkc 'A|2g|1|password12|1.2.3.4|1080|||1|0';            vrun "accept 10-col"        ok  validate_conf
mkc 'A|2g|1|password12|1.2.3.4|1080|||1|0||ftp';       vrun "reject proxy type"    die validate_conf
mkc 'A|2g|3|password12|1.2.3.4|8080|||1|0';            vrun "accept idx=3 port=8080" ok validate_conf
mkc 'A|5g|200|password12|1.2.3.4|65535|||1|0';         vrun "accept upper idx/port" ok validate_conf
mkc 'A|2g|1|password12|1.2.3.4|1080|||1|1|ZZ:GG:HH';   vrun "reject bad mac_oui"   die validate_conf
mkc 'A|2g|1|short|1.2.3.4|1080|||1|1';                 vrun "reject short wifi_key" die validate_conf
mkc 'A|2g|1|password12|1.2.3.4|1080|||1';              vrun "reject NF=9"          die validate_conf
mkc 'A|2g|0|password12|1.2.3.4|1080|||1|1';            vrun "reject idx=0"         die validate_conf
mkc 'A|2g|201|password12|1.2.3.4|1080|||1|1';          vrun "reject idx>200"       die validate_conf
mkc 'A|3g|1|password12|1.2.3.4|1080|||1|1';            vrun "reject band 3g"       die validate_conf
mkc 'A|2g|1|password12|1.2.3.4|70000|||1|1';           vrun "reject port>65535"    die validate_conf
mkc 'A|2g|1|password12||1080|||1|1';                   vrun "reject empty sock_host" die validate_conf
mkc 'A|2g|1|password12|1.2.3.4|1080|||2|1';            vrun "reject isolate=2"     die validate_conf
mkc 'A|2g|1|password12|bad host|1080|||1|1';            vrun "reject dirty sock_host" die validate_conf
mkc 'A|2g|1|password12|https://host|1080|||1|1';        vrun "reject URL as sock_host" die validate_conf
tab="$(printf '\t')"
mkc "A|2g|1|password12|host|1080|bad${tab}user||1|1";  vrun "reject control character" die validate_conf
long_host="$(awk 'BEGIN { for (i=0; i<254; i++) printf "h" }')"
mkc "A|2g|1|password12|$long_host|1080|||1|1";         vrun "reject oversized sock_host" die validate_conf
long_user="$(awk 'BEGIN { for (i=0; i<256; i++) printf "u" }')"
mkc "A|2g|1|password12|host|1080|$long_user||1|1";     vrun "reject oversized SOCKS user" die validate_conf
printf 'A|2g|1|password12|1.2.3.4|1080|||1|1\nB|5g|1|password12|5.6.7.8|1080|||1|0\n' > "$STUB/c.conf"
vrun "reject duplicate idx" die validate_conf

echo "== check_unique_idx =="
vrun "check_unique_idx catches dup" die check_unique_idx
mkc 'A|2g|1|password12|1.2.3.4|1080|||1|1'
vrun "check_unique_idx passes unique" ok check_unique_idx

echo "== conf helpers =="
mkc 'A|2g|3|password12|1.2.3.4|1080|||1|1
B|5g|1|password12|5.6.7.8|1080|||1|0'
eq "desired_idx sorted"  "$(CONF="$STUB/c.conf" desired_idx | tr '\n' ' ')" "1 3 "
# validate_conf accepts 10, 11 or 12 columns. An SSID that names its proxy_type
# has 12, and desired_idx feeds emit_stale_uci -- so a row it cannot see is an
# SSID that apply.sh tears down as if it had been removed.
mkc 'A|2g|3|password12|1.2.3.4|1080|||1|1
B|5g|1|password12|5.6.7.8|1080|||1|0|aa:bb:cc
C|2g|7|password12|9.9.9.9|8080|||1|0|aa:bb:cc|http'
eq "desired_idx sees every column count validate_conf allows" \
   "$(CONF="$STUB/c.conf" desired_idx | tr '\n' ' ')" "1 3 7 "
mkc 'A|2g|3|password12|1.2.3.4|1080|||1|1
B|5g|1|password12|5.6.7.8|1080|||1|0'
eq "band_of_idx 3 -> 2g" "$(CONF="$STUB/c.conf" band_of_idx 3)" "2g"
eq "band_of_idx 1 -> 5g" "$(CONF="$STUB/c.conf" band_of_idx 1)" "5g"
eq "band_of_idx missing -> empty" "$(CONF="$STUB/c.conf" band_of_idx 9)" ""
printf '3|aa:bb:cc:dd:ee:ff\n5|11:22:33:44:55:66\n3|AA:BB:CC:00:00:01\n' > "$STUB/bans"
eq "bans_for_idx 3 (sorted, lowercased)" "$(BANS_FILE="$STUB/bans" bans_for_idx 3 | tr '\n' ',')" "aa:bb:cc:00:00:01,aa:bb:cc:dd:ee:ff,"
eq "bans_for_idx 9 empty" "$(BANS_FILE="$STUB/bans" bans_for_idx 9)" ""

echo "== emit_stale_uci =="
mkc 'A|2g|1|password12|1.2.3.4|1080|||1|1
B|5g|3|password12|5.6.7.8|1080|||1|0'
printf '1 2 3\n' > "$STUB/managed"
stale="$(CONF="$STUB/c.conf" MANAGED_FILE="$STUB/managed" emit_stale_uci)"
match   "stale deletes removed idx 2" "$stale" 'delete wireless.w2'
nomatch "stale keeps desired idx 1"   "$stale" 'delete wireless.w1'
nomatch "stale keeps desired idx 3"   "$stale" 'delete wireless.w3'

echo "== emit_uci_one (MAC vendor logic) =="
emit1() { UCI_STATE="$1" emit_uci_one A 2g 1 password12 1.2.3.4 1080 "" "" 1 1 "$2"; }
out="$(emit1 /dev/null 50:C7:BF)"
match   "vendor MAC when none stored"   "$out" 'set wireless.w1.macaddr=50:c7:bf:'
match   "ipaddr from idx"               "$out" 'set network.w1.ipaddr=192.168.11.1'
match   "ssid quoted"                   "$out" 'set wireless.w1.ssid="A"'
match   "isolate value"                 "$out" 'set wireless.w1.isolate=1'
match   "admin-port block rule"         "$out" 'set firewall.z1adm.name=block-admin-w1'
match   "admin block limited to router" "$out" 'set firewall.z1adm.dest_ip=192.168.11.1'
match   "admin ports overwrite old list" "$out" 'set firewall.z1adm.dest_port="22 80 443"'
nomatch "admin ports do not accumulate" "$out" 'add_list firewall.z1adm.dest_port='
out="$(emit1 /dev/null '')"
match   "locally-admin MAC when no vendor & none stored" "$out" 'set wireless.w1.macaddr=02:'
printf 'wireless.w1.macaddr=50:c7:bf:12:34:56\n' > "$STUB/us"
out="$(emit1 "$STUB/us" 50:C7:BF)"
match   "keep stored MAC matching vendor" "$out" 'set wireless.w1.macaddr=50:c7:bf:12:34:56'
printf 'wireless.w1.macaddr=02:11:22:33:44:55\n' > "$STUB/us"
out="$(emit1 "$STUB/us" 50:C7:BF)"
match   "regenerate MAC on vendor change" "$out" 'set wireless.w1.macaddr=50:c7:bf:'
nomatch "old MAC dropped on vendor change" "$out" '02:11:22:33:44:55'
printf 'wireless.w1.macaddr=aa:bb:cc:dd:ee:ff\n' > "$STUB/us"
out="$(emit1 "$STUB/us" '')"
match   "keep stored MAC when no vendor" "$out" 'set wireless.w1.macaddr=aa:bb:cc:dd:ee:ff'

echo "== validate_admin_rule_scope (CLI + Agent apply guard) =="
mkc 'NewAgentWifi|2g|7|password12|1.2.3.4|1080|||1|1|'
admin_batch="$(UCI_STATE=/dev/null emit_uci_one NewAgentWifi 2g 7 password12 1.2.3.4 1080 "" "" 1 1 "")"
printf '%s\n' "$admin_batch" > "$STUB/admin-good.batch"
if ( CONF="$STUB/c.conf" validate_admin_rule_scope "$STUB/admin-good.batch" ) >/dev/null 2>&1; then
  ok "new Agent WiFi admin rule is gateway-scoped"
else
  no "new Agent WiFi admin rule is gateway-scoped"
fi
grep -v 'firewall.z7adm.dest_ip=' "$STUB/admin-good.batch" > "$STUB/admin-no-ip.batch"
L="guard rejects unscoped admin rule"; CONF="$STUB/c.conf" dies validate_admin_rule_scope "$STUB/admin-no-ip.batch"
cp "$STUB/admin-good.batch" "$STUB/admin-add-list.batch"
printf '%s\n' 'add_list firewall.z7adm.dest_port=443' >> "$STUB/admin-add-list.batch"
L="guard rejects accumulating admin ports"; CONF="$STUB/c.conf" dies validate_admin_rule_scope "$STUB/admin-add-list.batch"
agent_cgi="$(cat "$ROOT/agent/cgi/sbproxy")"
match "Agent apply uses shared guarded apply.sh" "$agent_cgi" 'sh scripts/apply\.sh --no-backup'
match "Agent exposes candidate config dry-run" "$agent_cgi" 'dryrun_conf\)'
match "Agent apply enforces quiet dry-run" "$agent_cgi" 'DRYRUN=1 DRYRUN_QUIET=1 sh scripts/apply\.sh'
match "Agent accepts Bearer authorization" "$agent_cgi" 'HTTP_AUTHORIZATION#Bearer'
match "Agent CORS allows Authorization" "$agent_cgi" 'Access-Control-Allow-Headers: Authorization'
match "Agent exposes runtime BSSID" "$agent_cgi" 'macaddr:\$mac'
match "Agent exposes rotate_mac action" "$agent_cgi" 'rotate_mac\)'
match "Agent exposes gateway status" "$agent_cgi" 'gateway\)'
match "Agent checks NUL with BusyBox hexdump fallback" "$agent_cgi" 'elif have hexdump'
agent_install="$(cat "$ROOT/agent/install-agent.sh")"
match "Agent install preserves an existing token" "$agent_install" 'if \[ ! -s /etc/sbproxy/token \]'
match "Agent install protects token permissions" "$agent_install" 'chmod 600 /etc/sbproxy/token'
match "Agent install deploys native CGI" "$agent_install" 'cp "\$AGENT/cgi/sbproxy" /www/cgi-bin/sbproxy'
match "Agent install deploys self-hosted web console" "$agent_install" 'control-panel\.html" /www/sbproxy/index\.html'
match "Agent install enables health daemon" "$agent_install" '/etc/init\.d/sbproxy-healthd enable'
match "Agent install persists files across sysupgrade" "$agent_install" '/etc/sysupgrade\.conf'
desktop_py="$(cat "$ROOT/console/desktop/main.py")"
match "native app sends Bearer authorization" "$desktop_py" '"Authorization": f"Bearer \{self\.token\}"'
match "native app filters clients" "$desktop_py" 'def filter_clients\('
match "native app can rotate BSSID" "$desktop_py" 'def rotate_wifi_mac\('
match "native app offers router providers" "$desktop_py" 'MAC_VENDORS = \('
match "native app has Random MAC dialog" "$desktop_py" 'class RandomMacDialog\('
match "native app has modal loading screen" "$desktop_py" 'class LoadingWindow\('
match "native app dry-runs candidate config" "$desktop_py" 'client\.dryrun_conf\(content\)'
match "native app uses bounded apply timeout" "$desktop_py" '"apply", "POST", \{\}, timeout=120'
match "native app has advanced client filters" "$desktop_py" 'TRAFFIC_FILTERS = \('
match "native app supports client sorting" "$desktop_py" 'def client_sort_key\('
match "native app supports bulk client actions" "$desktop_py" 'selectmode="extended"'
match "native app supports auto refresh" "$desktop_py" 'def schedule_client_refresh\('
match "native app exports filtered CSV" "$desktop_py" 'def export_clients_csv\('
match "native app supports manual blocklist entry" "$desktop_py" 'class ManualBanDialog\('
match "native app exposes Wi-Fi row context menu" "$desktop_py" 'bind\("<Button-3>", self\.show_wifi_context_menu\)'
match "native app context menu selects clicked SSID" "$desktop_py" 'self\.wifi_tree\.selection_set\(row\)'
match "native app keeps selected client actions in edit panel" "$desktop_py" 'ĐIỀU KHIỂN THIẾT BỊ ĐANG CHỌN'
match "native app disables item actions without selection" "$desktop_py" 'def update_client_editor\('
match "native app warns before important actions" "$desktop_py" 'def confirm_important\('
match "important action warning defaults to No" "$desktop_py" 'default=messagebox\.NO'
match "quick proxy change requires warning" "$desktop_py" 'Đổi proxy .* đang dùng cho SSID'
match "native app checks Internet gateway" "$desktop_py" 'def refresh_gateway\('
match "native app names a bad egress" "$desktop_py" 'ĐI QUA SSID ĐƯỢC PROXY'
match "native app supports English and Vietnamese" "$desktop_py" 'EN_TRANSLATIONS = \{'
match "native app supports dark and light themes" "$desktop_py" 'PALETTES = \{"dark": DARK_PALETTE, "light": LIGHT_PALETTE\}'
match "native app persists UI preferences" "$desktop_py" 'def save_preferences\('
match "native app switches language live" "$desktop_py" 'def _on_language_changed\('
match "native app switches theme live" "$desktop_py" 'def _on_theme_changed\('
gateway_script="$(cat "$ROOT/scripts/gateway.sh")"
match "gateway check resolves actual route" "$gateway_script" 'ip -4 route get'
match "gateway check binds HTTP probe to route device" "$gateway_script" 'curl -4.*--interface'
match "gateway check verifies DNS" "$gateway_script" 'nslookup "\$DNS_NAME"'
apply_script="$(cat "$ROOT/scripts/apply.sh")"
match "quiet dry-run hides generated secrets" "$apply_script" 'DRYRUN_QUIET'
rotate_mac="$(cat "$ROOT/scripts/rotate-mac.sh")"
match "rotate MAC validates managed idx" "$rotate_mac" 'band_of_idx "\$IDX"'
match "rotate MAC preserves configured OUI" "$rotate_mac" 'gen_mac "\$OUI"'
match "rotate MAC persists in UCI" "$rotate_mac" 'uci set "wireless\.w\$IDX\.macaddr=\$NEW"'
match "rotate MAC reloads selected radio" "$rotate_mac" 'wifi reload "\$RADIO"'
match "rotate MAC accepts provider OUI" "$rotate_mac" 'REQUESTED_OUI='
match "rotate MAC persists provider in config" "$rotate_mac" '\$11=oui'

cat > "$STUB/id" <<'SH'
#!/bin/sh
[ "${1:-}" = "-u" ] && echo 0 || echo 0
SH
cat > "$STUB/wifi" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$STUB/backup" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$STUB/id" "$STUB/wifi" "$STUB/backup"
printf '%s\n' 'A|2g|1|password12|1.2.3.4|1080|||1|1|50:C7:BF' > "$STUB/rotate.conf"
printf '%s\n' 'wireless.w1.ssid=A' 'wireless.w1.macaddr=50:c7:bf:11:22:33' > "$STUB/rotate-uci"
rotate_out="$(CONF="$STUB/rotate.conf" BACKUP_SCRIPT="$STUB/backup" UCI_STATE="$STUB/rotate-uci" \
  sh "$ROOT/scripts/rotate-mac.sh" 1 AC:9E:17 2>&1)"
eq "rotate MAC writes selected provider" "$(awk -F'|' 'NR==1{print $11}' "$STUB/rotate.conf")" "AC:9E:17"
match "rotate MAC reports selected provider" "$rotate_out" 'OUI=AC:9E:17'

echo "== build_nft =="
mkc 'A|2g|1|password12|1.2.3.4|1080|||1|1|
B|5g|2|password12|dns.example.com|1080|||1|0|'
( CONF="$STUB/c.conf" NFT_FILE="$STUB/x.nft" build_nft ) >/dev/null 2>&1
nft="$(cat "$STUB/x.nft" 2>/dev/null)"
# Each SSID now has its own chain, entered from a verdict map, so the
# interface is matched once instead of on every rule. Same behaviour, so these
# assert the same facts against the new shape. tests/test_pool.sh checks the
# structure itself, including that the rule order per SSID is unchanged.
match   "every SSID is dispatched by verdict map" "$nft" 'iifname vmap [{] "br-w1" : jump w1, "br-w2" : jump w2 [}]'
match   "DNS hijack covers tcp and udp"  "$nft" 'meta l4proto [{] tcp, udp [}] th dport 53 tproxy ip to :12001'
match   "tproxy rule for the first SSID" "$nft" 'meta l4proto [{] tcp, udp [}] tproxy ip to :12001'
match   "second SSID tproxy port"        "$nft" 'meta l4proto [{] tcp, udp [}] tproxy ip to :12002'
match   "block QUIC"                     "$nft" 'udp dport 443 drop'
match   "bypass proxy hosts by set"      "$nft" 'ip daddr @proxy_hosts return'
match   "literal sock IP is a set element" "$nft" 'elements = [{] 1[.]2[.]3[.]4 [}]'
nomatch "no hostname bypass"          "$nft" 'dns\.example\.com'
match   "RFC1918 return"              "$nft" 'ip daddr \{ 127.0.0.0/8'
match   "webrtc drop for webrtc=1"    "$nft" 'iifname "br-w1" udp dport \{ 3478'
nomatch "no webrtc drop for webrtc=0" "$nft" 'iifname "br-w2" udp dport \{ 3478'

echo "== build_singbox =="
if command -v jq >/dev/null 2>&1; then
  mkc 'A|2g|1|password12|1.2.3.4|1080|user1|pass1|1|1|
B|5g|2|password12|5.6.7.8|8080|||1|0||http'
  ( CONF="$STUB/c.conf" SINGBOX_CONF="$STUB/config.json" FAKEIP_RANGE="198.18.0.0/15" build_singbox ) >/dev/null 2>&1
  cfg="$(cat "$STUB/config.json" 2>/dev/null)"
  if printf '%s' "$cfg" | jq -e . >/dev/null 2>&1; then ok "JSON parses"; else no "JSON parses"; fi
  eq      "fakeip inet4_range"   "$(printf '%s' "$cfg" | jq -r '.dns.servers[]|select(.type=="fakeip").inet4_range')" "198.18.0.0/15"
  match   "HTTPS/SVCB predefined NOTIMP" "$cfg" 'NOTIMP'
  nomatch "no inet6_range (IPv4-only)"   "$cfg" 'inet6_range'
  match   "cache_file store_fakeip"      "$cfg" 'store_fakeip'
  match   "hijack-dns route rule"        "$cfg" 'hijack-dns'
  eq      "socks outbound count"  "$(printf '%s' "$cfg" | jq '[.outbounds[]|select(.type=="socks")]|length')" "1"
  eq      "http outbound count"   "$(printf '%s' "$cfg" | jq '[.outbounds[]|select(.type=="http")]|length')" "1"
  eq      "socks outbound network" "$(printf '%s' "$cfg" | jq -r '.outbounds[]|select(.tag=="out-w1")|.network')" "tcp"
  eq      "auth on user row"      "$(printf '%s' "$cfg" | jq -r '.outbounds[]|select(.tag=="out-w1")|.username')" "user1"
  eq      "no auth on empty row"  "$(printf '%s' "$cfg" | jq -r '.outbounds[]|select(.tag=="out-w2")|.username // "none"')" "none"
else
  sk "build_singbox" "no jq"
fi

echo "== clients.sh (integration) =="
if command -v jq >/dev/null 2>&1; then
  printf '{"radio0":{"interfaces":[{"section":"w1","ifname":"phy0-ap0"}]}}\n' > "$STUB/wifi.json"
  mkdir -p "$STUB/iwd"
  printf 'Station aa:bb:cc:dd:ee:ff (on phy0-ap0)\n\trx bytes:\t1048576\n\ttx bytes:\t2097152\n\tsignal:  \t-52 dBm\n\tconnected time:\t3600 seconds\n' > "$STUB/iwd/phy0-ap0.txt"
  printf '111 aa:bb:cc:dd:ee:ff 192.168.11.100 my-phone *\n222 11:22:33:44:55:66 192.168.12.101 old-tablet *\n' > "$STUB/leases"
  printf '1|aa:bb:cc:dd:ee:ff\n2|11:22:33:44:55:66\n' > "$STUB/bans2"
  printf 'wireless.w1.ssid=Alpha\nwireless.w2.ssid=Bravo\n' > "$STUB/uci_ssid"
  # settings.sh reassigns BANS_FILE, so override it via a custom SETTINGS that
  # sources the real one first (clients.sh re-sources settings in a subprocess).
  printf '. "%s/config/settings.sh"\nBANS_FILE="%s/bans2"\n' "$ROOT" "$STUB" > "$STUB/settings.sh"
  out="$(UBUS_WIFI_JSON="$STUB/wifi.json" IW_DUMP_DIR="$STUB/iwd" LEASES="$STUB/leases" \
         SETTINGS="$STUB/settings.sh" UCI_STATE="$STUB/uci_ssid" sh "$ROOT/scripts/clients.sh" 2>/dev/null)"
  eq "ok true"        "$(printf '%s' "$out" | jq -r '.ok')" "true"
  eq "online + blocked offline" "$(printf '%s' "$out" | jq -r '.clients|length')" "2"
  eq "mac"            "$(printf '%s' "$out" | jq -r '.clients[]|select(.online)|.mac')" "aa:bb:cc:dd:ee:ff"
  eq "ip from lease"  "$(printf '%s' "$out" | jq -r '.clients[]|select(.online)|.ip')" "192.168.11.100"
  eq "host from lease" "$(printf '%s' "$out" | jq -r '.clients[]|select(.online)|.host')" "my-phone"
  eq "connected_s"    "$(printf '%s' "$out" | jq -r '.clients[]|select(.online)|.connected_s')" "3600"
  eq "rx_bytes"       "$(printf '%s' "$out" | jq -r '.clients[]|select(.online)|.rx_bytes')" "1048576"
  eq "tx_bytes"       "$(printf '%s' "$out" | jq -r '.clients[]|select(.online)|.tx_bytes')" "2097152"
  eq "signal_dbm"     "$(printf '%s' "$out" | jq -r '.clients[]|select(.online)|.signal_dbm')" "-52"
  eq "banned true"    "$(printf '%s' "$out" | jq -r '.clients[]|select(.online)|.banned')" "true"
  eq "ssid"           "$(printf '%s' "$out" | jq -r '.clients[]|select(.online)|.ssid')" "Alpha"
  eq "band"           "$(printf '%s' "$out" | jq -r '.clients[]|select(.online)|.band')" "2g"
  eq "offline blocklist included" "$(printf '%s' "$out" | jq -r '.clients[]|select(.online|not)|.mac')" "11:22:33:44:55:66"
  eq "offline banned true" "$(printf '%s' "$out" | jq -r '.clients[]|select(.online|not)|.banned')" "true"
else
  sk "clients.sh integration" "no jq"
fi

echo "== clients.sh proxy pin (integration) =="
if command -v jq >/dev/null 2>&1; then
  # Two SSIDs: w1 has a pool of two proxies, w3 has none. Four devices between
  # them cover every state a pin can be in.
  printf '{"radio0":{"interfaces":[{"section":"w1","ifname":"phy0-ap0"},{"section":"w3","ifname":"phy0-ap2"}]}}\n' > "$STUB/wifi2.json"
  mkdir -p "$STUB/iwd2"
  printf 'Station aa:bb:cc:dd:ee:01 (on phy0-ap0)\n\tsignal:  \t-40 dBm\nStation aa:bb:cc:dd:ee:02 (on phy0-ap0)\n\tsignal:  \t-41 dBm\nStation aa:bb:cc:dd:ee:03 (on phy0-ap0)\n\tsignal:  \t-42 dBm\nStation aa:bb:cc:dd:ee:05 (on phy0-ap0)\n\tsignal:  \t-44 dBm\n' > "$STUB/iwd2/phy0-ap0.txt"
  printf 'Station aa:bb:cc:dd:ee:04 (on phy0-ap2)\n\tsignal:  \t-43 dBm\n' > "$STUB/iwd2/phy0-ap2.txt"
  : > "$STUB/leases2"
  : > "$STUB/bans3"
  printf 'wireless.w1.ssid=Alpha\nwireless.w3.ssid=Charlie\n' > "$STUB/uci_ssid2"
  printf '1|socks5|1.2.3.4|1080|user1|hunter2secret|alpha\n1|http|5.6.7.8|8080|||\n' > "$STUB/pools2"
  # ee:01 pinned to a live slot, ee:02 pinned past the end of the pool,
  # ee:03 not pinned at all, ee:04 on an SSID with no pool.
  printf '1|aa:bb:cc:dd:ee:01|0|manual\n1|aa:bb:cc:dd:ee:02|7|manual\n1|aa:bb:cc:dd:ee:05|1|auto\n' > "$STUB/assign2"
  printf '. "%s/config/settings.sh"\nBANS_FILE="%s/bans3"\nASSIGN_FILE="%s/assign2"\n' \
    "$ROOT" "$STUB" "$STUB" > "$STUB/settings2.sh"
  out2="$(UBUS_WIFI_JSON="$STUB/wifi2.json" IW_DUMP_DIR="$STUB/iwd2" LEASES="$STUB/leases2" \
          SETTINGS="$STUB/settings2.sh" UCI_STATE="$STUB/uci_ssid2" POOLS="$STUB/pools2" \
          sh "$ROOT/scripts/clients.sh" 2>/dev/null)"
  pin() { printf '%s' "$out2" | jq -r --arg m "$1" '.clients[]|select(.mac==$m)|'"$2"; }
  eq "five devices listed"     "$(printf '%s' "$out2" | jq -r '.clients|length')" "5"
  eq "pinned slot"             "$(pin aa:bb:cc:dd:ee:01 .slot)"         "0"
  eq "pinned host:port"        "$(pin aa:bb:cc:dd:ee:01 .proxy_host)"   "1.2.3.4:1080"
  eq "pinned label"            "$(pin aa:bb:cc:dd:ee:01 .proxy_label)"  "alpha"
  eq "pinned state"            "$(pin aa:bb:cc:dd:ee:01 .proxy_state)"  "pinned"
  eq "pool size reported"      "$(pin aa:bb:cc:dd:ee:01 .pool_size)"    "2"
  # The second proxy carries no label, so the console has to fall back to
  # host:port rather than print an empty cell.
  eq "unlabelled slot has an empty label" "$(pin aa:bb:cc:dd:ee:05 .proxy_label)" ""
  eq "unlabelled slot still has a host"   "$(pin aa:bb:cc:dd:ee:05 .proxy_host)" "5.6.7.8:8080"
  # A pin left behind by a shrunken pool must be visible as broken, not silently
  # reported as if the device still had a proxy.
  eq "stale pin keeps its slot"  "$(pin aa:bb:cc:dd:ee:02 .slot)"        "7"
  eq "stale pin has no host"     "$(pin aa:bb:cc:dd:ee:02 .proxy_host)"  ""
  eq "stale pin state"           "$(pin aa:bb:cc:dd:ee:02 .proxy_state)" "stale"
  # has("slot") as well as its value: a missing key and a null one read the
  # same through `.slot`, and only one of them is the contract.
  eq "unpinned row still carries the key" "$(pin aa:bb:cc:dd:ee:03 'has("slot")')" "true"
  eq "unpinned slot is null"     "$(pin aa:bb:cc:dd:ee:03 '.slot|type')" "null"
  eq "unpinned state"            "$(pin aa:bb:cc:dd:ee:03 .proxy_state)" "unpinned"
  eq "unpinned still knows the pool" "$(pin aa:bb:cc:dd:ee:03 .pool_size)" "2"
  eq "no pool at all"            "$(pin aa:bb:cc:dd:ee:04 .proxy_state)" "none"
  eq "no pool means size zero"   "$(pin aa:bb:cc:dd:ee:04 .pool_size)"   "0"
  nomatch "the proxy password never reaches the client list" "$out2" 'hunter2secret'
  nomatch "the proxy username never reaches it either"       "$out2" 'user1'
else
  sk "clients.sh proxy pin" "no jq"
fi

echo "== what a snapshot carries =="
snapdir="$STUB/snap"; mkdir -p "$snapdir"
mkdir -p "$STUB/live"
printf 'conf\n'   > "$STUB/live/wifi-socks.conf"
printf 'pool\n'   > "$STUB/live/proxy-pools.conf"
printf 'assign\n' > "$STUB/live/sbproxy.assign"
printf 'nft\n'    > "$STUB/live/sbproxy.nft"
printf 'bans\n'   > "$STUB/live/sbproxy.bans"
snap_env() {
  CONF="$STUB/live/wifi-socks.conf" POOLS="$STUB/live/proxy-pools.conf" \
  ASSIGN_FILE="$STUB/live/sbproxy.assign" NFT_FILE="$STUB/live/sbproxy.nft" \
  BANS_FILE="$STUB/live/sbproxy.bans" "$@"
}

names="$(snap_env backup_paths | cut -d'|' -f1 | tr '\n' ' ')"
# pool.sh takes a snapshot immediately before replacing a pool, so a snapshot
# without the pool and the pins is the one thing that cannot undo that.
contains "a snapshot carries the pool"  "$names" "proxy-pools.conf"
contains "and the device pins"          "$names" "sbproxy.assign"
contains "and the SSID configuration"   "$names" "wifi-socks.conf"
contains "and the generated ruleset"    "$names" "sbproxy.nft"
contains "and the blocklist"            "$names" "sbproxy.bans"

# Old snapshots must stay restorable, so the two names that already existed
# keep the spelling they had.
eq "the config keeps its old snapshot name" \
   "$(snap_env backup_paths | awk -F'|' '$1=="wifi-socks.conf" { print $2 }')" \
   "$STUB/live/wifi-socks.conf"
eq "so does the ruleset" \
   "$(snap_env backup_paths | awk -F'|' '$1=="sbproxy.nft" { print $2 }')" \
   "$STUB/live/sbproxy.nft"

eq "a path that is not configured is left out" \
   "$(CONF="$STUB/live/wifi-socks.conf" POOLS="" ASSIGN_FILE="" NFT_FILE="" BANS_FILE="" \
      backup_paths | wc -l | tr -d ' ')" "1"

snap_env backup_snapshot_files "$snapdir"
eq "the pool reaches the snapshot" "$(cat "$snapdir/proxy-pools.conf" 2>/dev/null)" "pool"
eq "the pins reach it too"         "$(cat "$snapdir/sbproxy.assign" 2>/dev/null)" "assign"

printf 'clobbered\n' > "$STUB/live/proxy-pools.conf"
rm -f "$STUB/live/sbproxy.assign"
snap_env restore_snapshot_files "$snapdir"
eq "restoring puts the pool back"  "$(cat "$STUB/live/proxy-pools.conf")" "pool"
eq "and the pins, even when deleted" "$(cat "$STUB/live/sbproxy.assign")" "assign"

# A file the snapshot never held must not be invented on restore.
rm -f "$snapdir/sbproxy.bans" "$STUB/live/sbproxy.bans"
snap_env restore_snapshot_files "$snapdir"
eq "a file absent from the snapshot is not created" \
   "$([ -f "$STUB/live/sbproxy.bans" ] && echo yes || echo no)" "no"

# A live file that has gone missing must not stop the rest of the snapshot.
rm -f "$STUB/live/wifi-socks.conf"
rm -rf "$snapdir"; mkdir -p "$snapdir"
snap_env backup_snapshot_files "$snapdir" 2>/dev/null
# The restore above put "pool" back, so that is what a fresh snapshot holds.
eq "a missing live file does not stop the snapshot" \
   "$(cat "$snapdir/proxy-pools.conf" 2>/dev/null)" "pool"

contains "backup.sh goes through the shared list" \
   "$(cat "$ROOT/scripts/backup.sh")" "backup_snapshot_files"
contains "and so does rollback.sh" \
   "$(cat "$ROOT/scripts/rollback.sh")" "restore_snapshot_files"

echo "== the pool file counts as a secret =="
contains "security-audit checks the pool file's permissions" \
   "$(cat "$ROOT/scripts/security-audit.sh")" "proxy-pools.conf"

echo "== preflight checks the pool's own preconditions =="
pre="$(cat "$ROOT/scripts/preflight.sh")"
contains "preflight validates the pool port arithmetic" "$pre" "validate_pool_settings"
contains "preflight asks nft whether it understands the syntax" "$pre" "use_divert"
contains "preflight checks dnsmasq's dhcpscript" "$pre" "dhcpscript"

echo "== pc update package manifest =="
match   "update.sh packages console" "$(sed -n '/tar czf/,/^$/p' "$ROOT/pc/update.sh")" 'README.md VERSION agent config console docs etc scripts'
nomatch "update.sh drops old ui path" "$(sed -n '/tar czf/,/^$/p' "$ROOT/pc/update.sh")" 'scripts tools ui'
match   "update.ps1 packages console" "$(sed -n '/tar -czf/,/if (\$LASTEXITCODE/p' "$ROOT/pc/update.ps1")" 'README.md VERSION agent config console docs etc scripts'
nomatch "update.ps1 drops old ui path" "$(sed -n '/tar -czf/,/if (\$LASTEXITCODE/p' "$ROOT/pc/update.ps1")" 'scripts tools ui'
match   "make-package.sh ships VERSION for the downgrade guard" "$(cat "$ROOT/pc/make-package.sh")" 'README.md VERSION agent config console docs etc scripts'
match   "make-package.ps1 ships VERSION for the downgrade guard" "$(cat "$ROOT/pc/make-package.ps1")" 'README.md VERSION agent config console docs etc scripts'

echo "== versioning and self-update =="
project_version="$(tr -d ' \r\n' < "$ROOT/VERSION")"
match "VERSION is semver or snapshot" "$project_version" '^[0-9]+\.[0-9]+\.[0-9]+(-SNAPSHOT)?$'
ui_version="$(sed -n 's/.*const UI_VERSION = "\([0-9.]*\(-SNAPSHOT\)\{0,1\}\)".*/\1/p' "$ROOT/console/web/control-panel.html")"
eq "web console version matches VERSION file" "$ui_version" "$project_version"
desktop_version="$(sed -n 's/^APP_VERSION = "\([0-9.]*\(-SNAPSHOT\)\{0,1\}\)"$/\1/p' "$ROOT/console/desktop/main.py")"
eq "desktop console version matches VERSION file" "$desktop_version" "$project_version"
desktop_main="$(cat "$ROOT/console/desktop/main.py")"
match "desktop shows agent version from status meta" "$desktop_main" 'clean_agent_version\(meta\)'
match "desktop keeps a plain-token fallback for POSIX builds" "$desktop_main" 'token_plain'
match "desktop locks down POSIX config permissions" "$desktop_main" '0o600'
match "desktop Linux build script uses PyInstaller" "$(cat "$ROOT/console/desktop/build.sh")" 'PyInstaller "\$@" main\.py'
match "desktop Linux build sets onefile windowed flags" "$(cat "$ROOT/console/desktop/build.sh")" 'set -- --noconfirm --clean --onefile --windowed --name sbproxy-console'
match "desktop Linux build rejects relative runtime tmpdir" "$(cat "$ROOT/console/desktop/build.sh")" 'must be an absolute path'
match "desktop Windows build isolates the bundled runtime" "$(cat "$ROOT/console/desktop/build.ps1")" 'runtime-tmpdir "%LOCALAPPDATA%\\sbproxy-console-native\\runtime"'
match "desktop isolates every write under one home" "$desktop_main" 'def resolve_app_home\('
match "desktop supports a portable data folder" "$desktop_main" 'portable = frozen_dir\(\) / "data"'
match "desktop writes a rotating debug log" "$desktop_main" 'RotatingFileHandler'
match "desktop logs uncaught exceptions" "$desktop_main" 'def install_exception_logging\('
match "desktop redacts secrets before logging" "$desktop_main" 'SECRET_PATTERN'
match "desktop migrates legacy config into the private home" "$desktop_main" 'def migrate_legacy_config\('
match "desktop Linux run script starts from source" "$(cat "$ROOT/console/desktop/run.sh")" 'exec "\$PY" main\.py'
agent_cgi="$(cat "$ROOT/agent/cgi/sbproxy")"
match "Agent status exposes version" "$agent_cgi" 'version:\$ver'
match "Agent exposes self-update action" "$agent_cgi" 'sh scripts/self-update\.sh'
match "Agent exempts only update from NUL check" "$agent_cgi" '\[ "\$ACTION" != "update" \]'
match "Agent caps update body size" "$agent_cgi" 'MAX_UPDATE_BYTES'
selfupdate="$(cat "$ROOT/scripts/self-update.sh")"
match "self-update blocks path traversal" "$selfupdate" 'unsafe path \(absolute or containing \.\.\)'
match "self-update guards downgrades" "$selfupdate" 'use --force to downgrade'
match "self-update pins the umask so uhttpd can execute the new CGI" "$selfupdate" '^umask 022'
match "self-update deploys with an explicit 755" "$selfupdate" 'chmod 755 "\$2"'
match "agent install marks the CGI 755, not umask-dependent +x" "$agent_install" 'chmod 755 /www/cgi-bin/sbproxy'
match "agent update action pins the umask" "$agent_cgi" 'umask 022'
match "self-update backs up before overwrite" "$selfupdate" 'backup\.sh pre-update'
match "self-update preserves live config" "$selfupdate" 'wifi-socks\.conf proxy-pools\.conf settings\.sh'
match "self-update validates package contents" "$selfupdate" 'scripts/apply\.sh scripts/lib\.sh agent/cgi/sbproxy'

echo "== self-update merges newly shipped settings =="
# An update keeps the router's settings.sh, which is right -- it holds choices
# nobody wants overwritten. The cost is that a key introduced by a new version
# never arrives, so the code falls back to whatever default it hardcodes, and
# the file stops describing what the router is doing. Merging closes that
# without touching a single value the operator set.
SU="$ROOT/scripts/self-update.sh"
mrg() { # packaged-content current-content -> prints added keys; file left in $STUB/cur.sh
  printf '%s\n' "$1" > "$STUB/pkg.sh"
  printf '%s\n' "$2" > "$STUB/cur.sh"
  sh "$SU" --merge-settings "$STUB/pkg.sh" "$STUB/cur.sh"
}

eq "a key the router has never seen is added" \
  "$(mrg 'OLD=1
NEW_KEY=7' 'OLD=9')" "NEW_KEY"
contains "the added key arrives with its shipped value" "$(cat "$STUB/cur.sh")" 'NEW_KEY=7'
contains "and the router's own value is untouched" "$(cat "$STUB/cur.sh")" 'OLD=9'
not_contains "the packaged value never replaces it" "$(cat "$STUB/cur.sh")" 'OLD=1'

eq "nothing new means nothing to say" "$(mrg 'A=1
B=2' 'A=9
B=8')" ""
eq "and the file is left exactly as it was" "$(cat "$STUB/cur.sh")" "A=9
B=8"

# A setting is worth little without the paragraph that explains it, and that
# paragraph is the reason settings.sh is readable at all.
mrg '# What this does.
# Second line.
DOCUMENTED=3' 'OTHER=1' >/dev/null
contains "the comment block above a new key comes with it" "$(cat "$STUB/cur.sh")" '# What this does.'
contains "including the rest of the block" "$(cat "$STUB/cur.sh")" '# Second line.'

# Commented out is not set: the code is running on its hardcoded default, so
# the shipped one should arrive and say so.
eq "a key commented out in the router file counts as absent" \
  "$(mrg 'PORT=13000' '#PORT=1')" "PORT"

eq "a key shipped twice is added once" \
  "$(mrg 'DUP=1
DUP=2' 'X=1')" "DUP"
eq "and only the first of them is written" \
  "$(grep -c '^DUP=' "$STUB/cur.sh")" "1"

# Copying one line out of a multi-line value would append an unterminated
# string and every later `. settings.sh` would fail -- a broken router, from a
# cosmetic feature.
eq "a value with an unbalanced quote is skipped, not half-copied" \
  "$(mrg 'SAFE=1
BROKEN="start
end"' 'X=1')" "SAFE"
not_contains "the half of it that would break sourcing is not there" "$(cat "$STUB/cur.sh")" 'BROKEN='
eq "the merged file still sources cleanly" \
  "$(sh -c '. "$1" && echo sourced' _ "$STUB/cur.sh" 2>&1)" "sourced"

eq "a missing packaged file is not an error" "$(sh "$SU" --merge-settings "$STUB/nope.sh" "$STUB/cur.sh"; echo $?)" "0"
match "web console can upload update package" "$(cat "$ROOT/console/web/control-panel.html")" 'apiUrl\("update"\)'
web_console="$(cat "$ROOT/console/web/control-panel.html")"
match "web console offers English and Vietnamese" "$web_console" 'id="languageSelect"'
match "web console persists language preference" "$web_console" 'localStorage\.setItem\(LANGUAGE_KEY, language\)'
match "web console switches language live" "$web_console" 'function setLanguage\(next\)'
match "web console defaults to English" "$web_console" '<html lang="en">'
match "web console translates icon-prefixed labels" "$web_console" 'function translatePhrase\(vi\)'
match "web console translates blocks with inline markup" "$web_console" 'const EN_HTML = \{'
match "web console leaves the mixed-content note to updateConnHint" "$web_console" 'id="mixedNote" data-i18n-skip'

echo ""
printf 'TOTAL: pass=%d  fail=%d  skip=%d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
