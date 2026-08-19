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

echo "== uci_dquote =="
eq "escape double-quote" "$(uci_dquote 'a"b')" 'a\"b'
eq "escape backslash"    "$(uci_dquote 'a\b')" 'a\\b'
eq "plain passes through" "$(uci_dquote 'plain')" 'plain'

echo "== gen_mac =="
match "gen_mac vendor OUI prefix + 6 octets" "$(gen_mac 50:C7:BF)" '^50:c7:bf:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$'
match "gen_mac lowercases OUI"               "$(gen_mac AC:9E:17)" '^ac:9e:17:'
match "gen_mac default is locally-admin 02:" "$(gen_mac)"          '^02:([0-9a-f]{2}:){4}[0-9a-f]{2}$'

echo "== validate_conf =="
mkc 'A|2g|1|password12|1.2.3.4|1080|u|p|1|1|50:C7:BF'; vrun "accept 11-col"        ok  validate_conf
mkc 'A|2g|1|password12|1.2.3.4|1080|||1|0';            vrun "accept 10-col"        ok  validate_conf
mkc 'A|2g|1|password12|1.2.3.4|1080|||1|1|ZZ:GG:HH';   vrun "reject bad mac_oui"   die validate_conf
mkc 'A|2g|1|short|1.2.3.4|1080|||1|1';                 vrun "reject short wifi_key" die validate_conf
mkc 'A|2g|1|password12|1.2.3.4|1080|||1';              vrun "reject NF=9"          die validate_conf
mkc 'A|2g|0|password12|1.2.3.4|1080|||1|1';            vrun "reject idx=0"         die validate_conf
mkc 'A|2g|201|password12|1.2.3.4|1080|||1|1';          vrun "reject idx>200"       die validate_conf
mkc 'A|3g|1|password12|1.2.3.4|1080|||1|1';            vrun "reject band 3g"       die validate_conf
mkc 'A|2g|1|password12|1.2.3.4|70000|||1|1';           vrun "reject port>65535"    die validate_conf
mkc 'A|2g|1|password12||1080|||1|1';                   vrun "reject empty sock_host" die validate_conf
mkc 'A|2g|1|password12|1.2.3.4|1080|||2|1';            vrun "reject isolate=2"     die validate_conf
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
match   "admin-port dest_port add_list" "$out" 'add_list firewall.z1adm.dest_port=22'
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

echo "== build_nft =="
mkc 'A|2g|1|password12|1.2.3.4|1080|||1|1|
B|5g|2|password12|dns.example.com|1080|||1|0|'
( CONF="$STUB/c.conf" NFT_FILE="$STUB/x.nft" build_nft ) >/dev/null 2>&1
nft="$(cat "$STUB/x.nft" 2>/dev/null)"
match   "DNS hijack udp dport 53"     "$nft" 'iifname "br-w1" udp dport 53 tproxy ip to :12001'
match   "DNS hijack tcp dport 53"     "$nft" 'iifname "br-w1" tcp dport 53 tproxy ip to :12001'
match   "tcp tproxy rule"             "$nft" 'iifname "br-w1" meta l4proto tcp tproxy ip to :12001'
match   "second SSID tproxy port"     "$nft" 'iifname "br-w2" meta l4proto udp tproxy ip to :12002'
match   "bypass literal sock IP"      "$nft" 'ip daddr 1.2.3.4 return'
nomatch "no hostname bypass"          "$nft" 'ip daddr dns.example.com'
match   "RFC1918 return"              "$nft" 'ip daddr \{ 127.0.0.0/8'
match   "webrtc drop for webrtc=1"    "$nft" 'iifname "br-w1" udp dport \{ 3478'
nomatch "no webrtc drop for webrtc=0" "$nft" 'iifname "br-w2" udp dport \{ 3478'

echo "== build_singbox =="
if command -v jq >/dev/null 2>&1; then
  mkc 'A|2g|1|password12|1.2.3.4|1080|user1|pass1|1|1|
B|5g|2|password12|5.6.7.8|1080|||1|0|'
  ( CONF="$STUB/c.conf" SINGBOX_CONF="$STUB/config.json" FAKEIP_RANGE="198.18.0.0/15" build_singbox ) >/dev/null 2>&1
  cfg="$(cat "$STUB/config.json" 2>/dev/null)"
  if printf '%s' "$cfg" | jq -e . >/dev/null 2>&1; then ok "JSON parses"; else no "JSON parses"; fi
  eq      "fakeip inet4_range"   "$(printf '%s' "$cfg" | jq -r '.dns.servers[]|select(.type=="fakeip").inet4_range')" "198.18.0.0/15"
  match   "HTTPS/SVCB predefined NOTIMP" "$cfg" 'NOTIMP'
  nomatch "no inet6_range (IPv4-only)"   "$cfg" 'inet6_range'
  match   "cache_file store_fakeip"      "$cfg" 'store_fakeip'
  match   "hijack-dns route rule"        "$cfg" 'hijack-dns'
  eq      "socks outbound count"  "$(printf '%s' "$cfg" | jq '[.outbounds[]|select(.type=="socks")]|length')" "2"
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
  printf '111 aa:bb:cc:dd:ee:ff 192.168.11.100 my-phone *\n' > "$STUB/leases"
  printf '1|aa:bb:cc:dd:ee:ff\n' > "$STUB/bans2"
  printf 'wireless.w1.ssid=Alpha\n' > "$STUB/uci_ssid"
  # settings.sh reassigns BANS_FILE, so override it via a custom SETTINGS that
  # sources the real one first (clients.sh re-sources settings in a subprocess).
  printf '. "%s/config/settings.sh"\nBANS_FILE="%s/bans2"\n' "$ROOT" "$STUB" > "$STUB/settings.sh"
  out="$(UBUS_WIFI_JSON="$STUB/wifi.json" IW_DUMP_DIR="$STUB/iwd" LEASES="$STUB/leases" \
         SETTINGS="$STUB/settings.sh" UCI_STATE="$STUB/uci_ssid" sh "$ROOT/scripts/clients.sh" 2>/dev/null)"
  eq "ok true"        "$(printf '%s' "$out" | jq -r '.ok')" "true"
  eq "one client"     "$(printf '%s' "$out" | jq -r '.clients|length')" "1"
  eq "mac"            "$(printf '%s' "$out" | jq -r '.clients[0].mac')" "aa:bb:cc:dd:ee:ff"
  eq "ip from lease"  "$(printf '%s' "$out" | jq -r '.clients[0].ip')" "192.168.11.100"
  eq "host from lease" "$(printf '%s' "$out" | jq -r '.clients[0].host')" "my-phone"
  eq "connected_s"    "$(printf '%s' "$out" | jq -r '.clients[0].connected_s')" "3600"
  eq "rx_bytes"       "$(printf '%s' "$out" | jq -r '.clients[0].rx_bytes')" "1048576"
  eq "tx_bytes"       "$(printf '%s' "$out" | jq -r '.clients[0].tx_bytes')" "2097152"
  eq "signal_dbm"     "$(printf '%s' "$out" | jq -r '.clients[0].signal_dbm')" "-52"
  eq "banned true"    "$(printf '%s' "$out" | jq -r '.clients[0].banned')" "true"
  eq "ssid"           "$(printf '%s' "$out" | jq -r '.clients[0].ssid')" "Alpha"
else
  sk "clients.sh integration" "no jq"
fi

echo "== pc update package manifest =="
match   "update.sh packages console" "$(sed -n '/tar czf/,/^$/p' "$ROOT/pc/update.sh")" 'README.md agent config console docs etc scripts tools'
nomatch "update.sh drops old ui path" "$(sed -n '/tar czf/,/^$/p' "$ROOT/pc/update.sh")" 'scripts tools ui'
match   "update.ps1 packages console" "$(sed -n '/tar -czf/,/if (\$LASTEXITCODE/p' "$ROOT/pc/update.ps1")" 'README.md agent config console docs etc scripts tools'
nomatch "update.ps1 drops old ui path" "$(sed -n '/tar -czf/,/if (\$LASTEXITCODE/p' "$ROOT/pc/update.ps1")" 'scripts tools ui'

echo ""
printf 'TOTAL: pass=%d  fail=%d  skip=%d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
