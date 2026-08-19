#!/bin/sh
# tests/run.sh — POSIX-sh unit tests for the pure logic in scripts/lib.sh
# (validators + generators). No router needed; router-only tools (uci/ubus) are
# stubbed and jq-dependent tests self-skip when jq is absent. Exit 1 on failure.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB_ROOT="$ROOT"; export SB_ROOT

# Stub router-only tools so sourcing/functions never touch the host.
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT INT TERM
for c in uci ubus; do printf '#!/bin/sh\nexit 1\n' > "$STUB/$c"; chmod +x "$STUB/$c"; done
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
mkc()     { printf '%s\n' "$1" > "$STUB/c.conf"; }
valid()   { ( CONF="$STUB/c.conf" validate_conf ) >/dev/null 2>&1; }

echo "== derived values =="
eq "net_octet 1"    "$(net_octet 1)"    "11"
eq "net_octet 30"   "$(net_octet 30)"   "40"
eq "tproxy_port 3"  "$(tproxy_port 3)"  "12003"

echo "== gen_mac =="
match "gen_mac vendor OUI prefix + 6 octets" "$(gen_mac 50:C7:BF)" '^50:c7:bf:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$'
match "gen_mac lowercases OUI"               "$(gen_mac AC:9E:17)" '^ac:9e:17:'
match "gen_mac default is locally-admin 02:" "$(gen_mac)"          '^02:([0-9a-f]{2}:){4}[0-9a-f]{2}$'

echo "== validate_conf =="
mkc 'A|2g|1|password12|1.2.3.4|1080|u|p|1|1|50:C7:BF'; if valid; then ok "accept 11-col"; else no "accept 11-col"; fi
mkc 'A|2g|1|password12|1.2.3.4|1080|||1|0';            if valid; then ok "accept 10-col"; else no "accept 10-col"; fi
mkc 'A|2g|1|password12|1.2.3.4|1080|||1|1|ZZ:GG:HH';   if valid; then no "reject bad mac_oui"; else ok "reject bad mac_oui"; fi
mkc 'A|2g|1|short|1.2.3.4|1080|||1|1';                 if valid; then no "reject short wifi_key"; else ok "reject short wifi_key"; fi
mkc 'A|2g|1|password12|1.2.3.4|1080|||1';              if valid; then no "reject NF=9"; else ok "reject NF=9"; fi
mkc 'A|2g|0|password12|1.2.3.4|1080|||1|1';            if valid; then no "reject idx=0"; else ok "reject idx=0"; fi

echo "== conf helpers =="
mkc 'A|2g|3|password12|1.2.3.4|1080|||1|1
B|5g|1|password12|5.6.7.8|1080|||1|0'
eq "desired_idx sorted"  "$(CONF="$STUB/c.conf" desired_idx | tr '\n' ' ')" "1 3 "
eq "band_of_idx 3 -> 2g" "$(CONF="$STUB/c.conf" band_of_idx 3)" "2g"
eq "band_of_idx 1 -> 5g" "$(CONF="$STUB/c.conf" band_of_idx 1)" "5g"
printf '3|aa:bb:cc:dd:ee:ff\n5|11:22:33:44:55:66\n' > "$STUB/bans"
eq "bans_for_idx 3" "$(BANS_FILE="$STUB/bans" bans_for_idx 3)" "aa:bb:cc:dd:ee:ff"
eq "bans_for_idx 9 empty" "$(BANS_FILE="$STUB/bans" bans_for_idx 9)" ""

echo "== build_nft =="
mkc 'A|2g|1|password12|1.2.3.4|1080|||1|1|
B|5g|2|password12|dns.example.com|1080|||1|0|'
( CONF="$STUB/c.conf" NFT_FILE="$STUB/x.nft" build_nft ) >/dev/null 2>&1
nft="$(cat "$STUB/x.nft" 2>/dev/null)"
match   "nft: DNS hijack dport 53"     "$nft" 'iifname "br-w1" udp dport 53 tproxy ip to :12001'
match   "nft: tcp tproxy rule"         "$nft" 'iifname "br-w1" meta l4proto tcp tproxy ip to :12001'
match   "nft: bypass literal sock IP"  "$nft" 'ip daddr 1.2.3.4 return'
nomatch "nft: no hostname bypass"      "$nft" 'ip daddr dns.example.com'
match   "nft: RFC1918 return"          "$nft" 'ip daddr \{ 127.0.0.0/8'

echo "== build_singbox =="
if command -v jq >/dev/null 2>&1; then
  ( CONF="$STUB/c.conf" SINGBOX_CONF="$STUB/config.json" FAKEIP_RANGE="198.18.0.0/15" build_singbox ) >/dev/null 2>&1
  cfg="$(cat "$STUB/config.json" 2>/dev/null)"
  if command -v node >/dev/null 2>&1; then
    if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "$STUB/config.json" 2>/dev/null; then ok "singbox JSON parses"; else no "singbox JSON parses"; fi
  elif printf '%s' "$cfg" | jq -e . >/dev/null 2>&1; then ok "singbox JSON parses"; else no "singbox JSON parses"; fi
  match "singbox: fakeip server"   "$cfg" '"fakeip"'
  match "singbox: hijack-dns rule" "$cfg" 'hijack-dns'
  match "singbox: socks outbound"  "$cfg" '"out-w1"'
else
  sk "build_singbox" "no jq"
fi

echo ""
printf 'TOTAL: pass=%d  fail=%d  skip=%d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
