#!/bin/sh
# tests/test_pool.sh — unit tests for the proxy-pool layer of scripts/lib.sh:
# the pool config file, its validation, and the TPROXY port arithmetic.
#
# No router needed. The pool file is a plain text table, so every case here is
# a workstation test; nothing is stubbed beyond pointing POOLS at a fixture.
# shellcheck disable=SC2034  # POOL_* and POOLS are read by the lib.sh functions under test.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB_ROOT="$ROOT"; export SB_ROOT
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT INT TERM

CONF="$ROOT/config/wifi-socks.conf.example"; export CONF
# shellcheck source=/dev/null
. "$ROOT/scripts/lib.sh"

# Overrides go *after* sourcing: lib.sh sources settings.sh and would win.
POOL_PORT_BASE=13000
POOL_PORT_STRIDE=256
POOL_SLOTS_PER_SSID_MAX=256
TPROXY_PORT_BASE=12000

# Deliberately not named pass/fail: build_singbox assigns an SSID's proxy
# password to a global called `pass`, which would silently reset the counter
# and make every later assertion score 1. tests/run.sh only escapes this
# because it happens to call the generator inside a command substitution.
n_ok=0; n_bad=0
ok()   { n_ok=$((n_ok + 1)); printf '  ok   %s\n' "$1"; }
no()   { n_bad=$((n_bad + 1)); printf '  FAIL %s\n' "$1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want[$3] got[$2]"; fi; }
contains() { if printf '%s' "$2" | grep -qF "$3"; then ok "$1"; else no "$1 — missing[$3]"; fi; }
match() { if printf '%s' "$2" | grep -Eq "$3"; then ok "$1"; else no "$1 — no /$3/"; fi; }

# Write a pool fixture and point POOLS at it.
mkpool() { printf '%s\n' "$1" > "$STUB/pool.conf"; POOLS="$STUB/pool.conf"; }

# Run validate_pools in a subshell so its die() cannot kill the runner.
vrun() { # label expected(ok|die)
  if ( POOLS="$STUB/pool.conf" validate_pools ) >/dev/null 2>&1; then r=ok; else r=die; fi
  if [ "$r" = "$2" ]; then ok "$1"; else no "$1 — got $r want $2"; fi
}

GOOD='# idx|proxy_type|host|port|user|pass|label
1|socks5|1.2.3.4|1080|u1|p1|VN-01
1|http|5.6.7.8|8080|||US-02

# a comment in the middle
1|socks5|proxy.example.com|1080|a|b|SG-03
2|socks5|9.9.9.9|1080|||'

echo "== port arithmetic =="
eq "pool_port idx=1 slot=0"   "$(pool_port 1 0)"     "13256"
eq "pool_port idx=1 slot=5"   "$(pool_port 1 5)"     "13261"
eq "pool_port idx=2 slot=0"   "$(pool_port 2 0)"     "13512"
eq "pool_port idx=200 slot=255" "$(pool_port 200 255)" "64455"
eq "highest pool port fits in a u16" "$([ "$(pool_port 200 255)" -le 65535 ] && echo yes)" "yes"

# The legacy per-SSID ports must never collide with a pool port.
lo="$(pool_port 1 0)"; legacy_hi=$((TPROXY_PORT_BASE + 200))
eq "pool range starts above the legacy range" "$([ "$lo" -gt "$legacy_hi" ] && echo yes)" "yes"

echo "== reading the pool file =="
mkpool "$GOOD"
eq "pool_count counts only its own idx"  "$(pool_count 1)" "3"
eq "pool_count for a second idx"         "$(pool_count 2)" "1"
eq "pool_count for an idx with no rows"  "$(pool_count 7)" "0"
eq "pool_enabled is true with rows"      "$(pool_enabled 1 && echo yes)" "yes"
eq "pool_enabled is false without rows"  "$(pool_enabled 7 || echo no)"  "no"

POOLS="$STUB/nonexistent.conf"
eq "a missing pool file means the feature is off" "$(pool_count 1)" "0"
eq "pool_enabled is false without a file" "$(pool_enabled 1 || echo no)" "no"

echo "== iterating slots =="
mkpool "$GOOD"
show() { printf '%s:%s:%s:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }
rows="$(for_each_pool 1 show)"
eq "slots are numbered from zero in file order" \
  "$(printf '%s' "$rows" | awk -F: 'NR==1{print $1} NR==2{print $1} NR==3{print $1}' | tr '\n' ' ')" \
  "0 1 2 "
contains "slot 0 carries every field"  "$rows" "0:socks5:1.2.3.4:1080:u1:p1:VN-01"
contains "an unauthenticated row keeps empty credentials" "$rows" "1:http:5.6.7.8:8080:::US-02"
contains "a hostname is passed through" "$rows" "2:socks5:proxy.example.com:1080:a:b:SG-03"
eq "a row without the optional label still parses" \
  "$(for_each_pool 2 show)" "0:socks5:9.9.9.9:1080:::"

echo "== validation accepts =="
mkpool "$GOOD";                                          vrun "a well-formed pool" ok
mkpool '# only comments';                                vrun "a file with no rows" ok
mkpool '1|socks5|1.2.3.4|1080|||';                       vrun "no credentials and no label" ok
mkpool '1|socks5|1.2.3.4|1080|u|p';                      vrun "six columns (label omitted)" ok
mkpool '1|HTTP|1.2.3.4|8080|||';                         vrun "proxy_type is case-insensitive" ok
mkpool '1|socks5|2001:db8::1|1080|||';                   vrun "an IPv6 literal host" ok

echo "== validation rejects =="
mkpool '1|socks5|1.2.3.4';                               vrun "too few columns" die
mkpool '1|socks5|1.2.3.4|1080|u|p|label|extra';          vrun "too many columns" die
mkpool '0|socks5|1.2.3.4|1080|||';                       vrun "idx zero" die
mkpool '201|socks5|1.2.3.4|1080|||';                     vrun "idx above 200" die
mkpool 'x|socks5|1.2.3.4|1080|||';                       vrun "a non-numeric idx" die
mkpool '1|socks4|1.2.3.4|1080|||';                       vrun "an unsupported proxy type" die
mkpool '1|socks5||1080|||';                              vrun "an empty host" die
mkpool '1|socks5|1.2.3.4 evil|1080|||';                  vrun "a host with a space" die
mkpool '1|socks5|1.2.3.4;rm|1080|||';                    vrun "a host with a shell metacharacter" die
mkpool '1|socks5|1.2.3.4|0|||';                          vrun "port zero" die
mkpool '1|socks5|1.2.3.4|65536|||';                      vrun "a port above 65535" die
mkpool '1|socks5|1.2.3.4|http|||';                       vrun "a non-numeric port" die
mkpool "1|socks5|1.2.3.4|1080|$(printf 'a\tb')|p|";      vrun "a control character in the user" die
mkpool "1|socks5|1.2.3.4|1080|u|p|$(printf 'l\001b')";   vrun "a control character in the label" die

long="$(awk 'BEGIN{ for (i=0;i<300;i++) printf "a" }')"
mkpool "1|socks5|1.2.3.4|1080|$long|p|";                 vrun "an over-long user" die
mkpool "1|socks5|$long.example.com|1080|||";             vrun "an over-long host" die

# One SSID must not claim more slots than its port stride allows.
too_many="$(awk -v n="$((POOL_SLOTS_PER_SSID_MAX + 1))" \
  'BEGIN{ for (i=0;i<n;i++) printf "1|socks5|10.0.0.1|%d|||\n", 1080+i }')"
mkpool "$too_many";                                      vrun "more slots than the per-SSID cap" die

echo "== settings sanity =="
# Overrides are applied inside the subshell that runs the check, but the
# assertion itself must stay in this shell: a counter bumped inside ( ) is
# discarded, which would make every case here pass no matter what.
vsrun() { # label expected(ok|die) [VAR=VALUE ...]
  _lbl="$1"; _want="$2"; shift 2
  if ( for _kv in "$@"; do eval "$_kv"; done; validate_pool_settings ) >/dev/null 2>&1
  then r=ok; else r=die; fi
  if [ "$r" = "$_want" ]; then ok "$_lbl"; else no "$_lbl — got $r want $_want"; fi
}
vsrun "the shipped defaults are sane" ok
vsrun "per-SSID cap above the stride"            die "POOL_SLOTS_PER_SSID_MAX=257"
vsrun "a pool base that overlaps the legacy range" die "POOL_PORT_BASE=12000"
vsrun "a stride that pushes ports past 65535"    die "POOL_PORT_STRIDE=400"
vsrun "a zero stride"                            die "POOL_PORT_STRIDE=0"
vsrun "a non-numeric stride"                     die "POOL_PORT_STRIDE=abc"

# Exit status alone is not enough here: a garbage value also makes `[ -ge ]`
# fail, so these assert on the message that identifies which guard fired.
vsmsg() { # label pattern VAR=VALUE...
  _lbl="$1"; _pat="$2"; shift 2
  _out="$( ( for _kv in "$@"; do eval "$_kv"; done; validate_pool_settings ) 2>&1 )"
  if printf '%s' "$_out" | grep -Eq "$_pat"; then ok "$_lbl"; else no "$_lbl — no /$_pat/ in [$_out]"; fi
}
vsmsg "a non-numeric stride is named as such" "must be integers" "POOL_PORT_STRIDE=abc"
vsmsg "a non-numeric base is named as such"   "must be integers" "POOL_PORT_BASE=13o00"
vsmsg "an over-large stride names the port"   "past 65535"       "POOL_PORT_STRIDE=400"
vsmsg "an overlap names both ranges"          "overlaps TPROXY_PORT_BASE" "POOL_PORT_BASE=12000"
vsmsg "a cap above the stride names both"     "must not exceed POOL_PORT_STRIDE" "POOL_SLOTS_PER_SSID_MAX=257"
vsrun "a base just clear of the legacy range"    ok  "POOL_PORT_BASE=12201"

echo "== sing-box generation =="
if ! command -v jq >/dev/null 2>&1; then
  printf '  skip sing-box generation (jq is not installed)
'
else
  # build_singbox writes to $SINGBOX_CONF; point everything at the sandbox.
  SINGBOX_CONF="$STUB/config.json"
  SINGBOX_CACHE="/etc/sing-box/cache.db"
  FAKEIP_RANGE="198.18.0.0/15"; DNS_UPSTREAM="1.1.1.1"; SINGBOX_LOG_LEVEL="warn"
  NET_BASE=10

  gen() { # <pool file or ->  : regenerate and echo the config path
    if [ "$1" = "-" ]; then POOLS="$STUB/no-such-pool.conf"; else POOLS="$1"; fi
    build_singbox >/dev/null 2>&1
    printf '%s' "$SINGBOX_CONF"
  }
  tags() { jq -c "[.$2[].tag]" "$1"; }

  # The invariant for every step: an SSID with no pool generates exactly what
  # it did before the pool feature existed. The golden file was produced by the
  # pre-F2 generator; if this ever fails, the change was not backwards
  # compatible and the fixture must not simply be refreshed to match.
  CONF="$ROOT/config/wifi-socks.conf.example"
  gen - >/dev/null
  if cmp -s "$SINGBOX_CONF" "$ROOT/tests/fixtures/singbox-nopool.json"; then
    ok "no pool generates a byte-identical config"
  else
    no "no pool generates a byte-identical config — output drifted from the golden"
  fi

  POOL3="$STUB/p3.conf"
  printf '%s
'     '1|socks5|9.9.9.9|1080|pu|pw|VN-01'     '1|http|10.0.0.7|8080|||US-02'     '1|socks5|proxy.example.com|1080|a|b|SG-03' > "$POOL3"

  gen "$POOL3" >/dev/null
  eq "a pooled config is valid JSON" "$(jq -e . "$SINGBOX_CONF" >/dev/null 2>&1 && echo yes)" "yes"
  eq "pool slots add inbounds, legacy inbound stays"     "$(tags "$SINGBOX_CONF" inbounds)"     '["in-w1","in-w1-s0","in-w1-s1","in-w1-s2","in-w2","in-w3"]'
  eq "pool slots add outbounds, direct stays last"     "$(tags "$SINGBOX_CONF" outbounds)"     '["out-w1","out-w1-s0","out-w1-s1","out-w1-s2","out-w2","out-w3","direct"]'
  eq "slot inbounds listen on the pool ports"     "$(jq -c '[.inbounds[]|select(.tag|startswith("in-w1-s"))|.listen_port]' "$SINGBOX_CONF")"     "[$(pool_port 1 0),$(pool_port 1 1),$(pool_port 1 2)]"
  eq "the legacy inbound keeps its own port"     "$(jq -r '.inbounds[]|select(.tag=="in-w1")|.listen_port' "$SINGBOX_CONF")" "$(tproxy_port 1)"
  eq "every slot inbound is a tproxy listener"     "$(jq -c '[.inbounds[]|select(.tag|startswith("in-w1-s"))|.type]|unique' "$SINGBOX_CONF")"     '["tproxy"]'

  eq "a socks5 slot becomes a socks outbound"     "$(jq -c '.outbounds[]|select(.tag=="out-w1-s0")|[.type,.server,.server_port,.version,.network,.username,.password]' "$SINGBOX_CONF")"     '["socks","9.9.9.9",1080,"5","tcp","pu","pw"]'
  eq "an http slot becomes an http outbound"     "$(jq -c '.outbounds[]|select(.tag=="out-w1-s1")|[.type,.server,.server_port]' "$SINGBOX_CONF")"     '["http","10.0.0.7",8080]'
  eq "a slot without credentials carries no auth fields"     "$(jq -c '.outbounds[]|select(.tag=="out-w1-s1")|has("username")' "$SINGBOX_CONF")" "false"
  eq "a hostname slot is passed through unresolved"     "$(jq -r '.outbounds[]|select(.tag=="out-w1-s2")|.server' "$SINGBOX_CONF")" "proxy.example.com"

  eq "each slot is routed to its own outbound"     "$(jq -c '[.route.rules[]|select((.inbound[0]? // "")|startswith("in-w1-s"))|select(.outbound)|.outbound]' "$SINGBOX_CONF")"     '["out-w1-s0","out-w1-s1","out-w1-s2"]'
  eq "each slot inbound is sniffed"     "$(jq '[.route.rules[]|select((.inbound[0]? // "")|startswith("in-w1-s"))|select(.action=="sniff")]|length' "$SINGBOX_CONF")" "3"
  eq "the legacy route rule survives for unpinned devices"     "$(jq -c '[.route.rules[]|select(.inbound==["in-w1"])|select(.outbound)|.outbound]' "$SINGBOX_CONF")"     '["out-w1"]'

  # A credential is quoted through jq, so JSON metacharacters must survive.
  NASTY="$STUB/nasty.conf"
  printf '%s
' '1|socks5|9.9.9.9|1080|u"x|p\y|L' > "$NASTY"
  gen "$NASTY" >/dev/null
  eq "a password with a quote and a backslash round-trips"     "$(jq -r '.outbounds[]|select(.tag=="out-w1-s0")|.password' "$SINGBOX_CONF")" 'p\y'
  eq "a config with nasty credentials is still valid JSON"     "$(jq -e . "$SINGBOX_CONF" >/dev/null 2>&1 && echo yes)" "yes"

  # A pool on an SSID that has no wifi-socks.conf row must not invent one.
  ORPHAN="$STUB/orphan.conf"
  printf '%s
' '9|socks5|9.9.9.9|1080|||' > "$ORPHAN"
  gen "$ORPHAN" >/dev/null
  eq "a pool for an unknown idx generates nothing"     "$(jq -c '[.inbounds[].tag]' "$SINGBOX_CONF")" '["in-w1","in-w2","in-w3"]'

  # An empty wifi-socks.conf must still produce loadable JSON (0.4.9 regression).
  : > "$STUB/empty.conf"
  CONF="$STUB/empty.conf"; gen - >/dev/null
  eq "an empty SSID table is still valid JSON"     "$(jq -e . "$SINGBOX_CONF" >/dev/null 2>&1 && echo yes)" "yes"
  CONF="$ROOT/config/wifi-socks.conf.example"
fi

echo "== nftables structure =="
NFT_FILE="$STUB/sbproxy.nft"
TPROXY_MARK=1
STUN_TCP_PORTS="3478, 3479, 5349, 5350"
STUN_UDP_PORTS="3478, 3479, 5349, 5350, 19302-19309"
CONF="$ROOT/config/wifi-socks.conf.example"

nftgen() { # <pool file or -> [POOL_DIVERT value]
  if [ "$1" = "-" ]; then POOLS="$STUB/no-such-pool.conf"; else POOLS="$1"; fi
  POOL_DIVERT="${2:-off}"
  build_nft >/dev/null 2>&1
}
# Body of one chain, without its type/policy line.
chain_body() {
  awk -v c="  chain $1 {" '$0==c {inside=1; next} inside && /^  }/ {exit} inside && !/type [a-z]+ hook/' "$NFT_FILE"
}
# Element list of one named map, or empty when it declares none.
map_elements() { sed -n "s/.*map $1 {.*elements = { \\([^}]*\\) }.*/\\1/p" "$NFT_FILE"; }
# Marker sequence of a chain, so order can be asserted without pinning wording.
chain_shape() {
  chain_body "$1" | awk '
    /dport 53/            { print "dns" }
    /127\.0\.0\.0\/8/       { print "localnet" }
    /@proxy_hosts/        { print "hosts" }
    /dport 443 drop/      { print "quic" }
    /tproxy ip to :ip saddr map/ { print "pin" }
    /tproxy ip to :[0-9]+ meta mark set/ && !/dport 53/ { print "tproxy" }
  ' | tr '\n' ' '
}

nftgen -
eq "one chain per SSID" \
  "$(grep -c '^  chain w[0-9]* {' "$NFT_FILE")" "3"
eq "every SSID is dispatched from the verdict map" \
  "$(grep -o 'iifname vmap { [^}]*}' "$NFT_FILE")" \
  'iifname vmap { "br-w1" : jump w1, "br-w2" : jump w2, "br-w3" : jump w3 }'
eq "prerouting no longer carries per-SSID rules" \
  "$(chain_body prerouting | grep -c 'br-w')" "1"

# Rule order inside an SSID chain must match the old flat chain's order.
eq "chain w1 keeps the original rule order" "$(chain_shape w1)" "dns localnet hosts quic tproxy "
eq "chain w3 has the identical shape"       "$(chain_shape w3)" "dns localnet hosts quic tproxy "
eq "an SSID chain is a constant number of rules" \
  "$(chain_body w1 | grep -vc '^ *#')" "$(chain_body w3 | grep -vc '^ *#')"

eq "DNS still goes to the SSID's own port" \
  "$(chain_body w2 | grep 'dport 53' | grep -c ":$(tproxy_port 2)")" "1"
eq "tcp and udp share one DNS rule now" \
  "$(chain_body w2 | grep -c 'dport 53')" "1"
eq "tcp and udp share one tproxy rule now" \
  "$(chain_body w2 | grep -c 'meta l4proto { tcp, udp } tproxy')" "1"
eq "the default tproxy target is the SSID port" \
  "$(chain_body w2 | grep -c "tproxy ip to :$(tproxy_port 2) meta mark set 1 accept")" "2"

# Proxy hosts move from one rule each into a single set.
eq "numeric proxy hosts become set elements" \
  "$(grep -o 'elements = { [^}]*}' "$NFT_FILE")" \
  'elements = { 1.2.3.4, 5.6.7.8, 9.9.9.9 }'
eq "the set is keyed by IPv4 address" \
  "$(grep -c 'set proxy_hosts { type ipv4_addr' "$NFT_FILE")" "1"

POOLHOSTS="$STUB/ph.conf"
printf '%s\n' '1|socks5|203.0.113.7|1080|||' '1|socks5|1.2.3.4|1080|||' \
               '1|socks5|proxy.example.com|1080|||' > "$POOLHOSTS"
nftgen "$POOLHOSTS"
eq "pool hosts are bypassed too, deduplicated, hostnames excluded" \
  "$(grep -o 'elements = { [^}]*}' "$NFT_FILE")" \
  'elements = { 1.2.3.4, 5.6.7.8, 9.9.9.9, 203.0.113.7 }'

# WebRTC lives on the forward hook and must not move into the verdict map.
nftgen -
eq "the webrtc chain still hooks forward" \
  "$(grep -c 'chain webrtc' "$NFT_FILE")" "1"
eq "webrtc rules stay interface-matched, only for SSIDs that asked" \
  "$(chain_body webrtc | grep -c 'br-w')" "4"
eq "webrtc is untouched for the SSID with the flag off" \
  "$(chain_body webrtc | grep -c 'br-w3')" "0"

echo "== nftables divert rule =="
nftgen - on
eq "divert is the first rule in prerouting" \
  "$(chain_body prerouting | grep -v '^ *#' | head -1)" \
  "    meta l4proto tcp socket transparent 1 meta mark set 1 accept"
eq "divert is tcp only" "$(chain_body prerouting | grep -c 'socket transparent 1')" "1"
nftgen - off
eq "divert can be turned off" "$(grep -c 'socket transparent' "$NFT_FILE")" "0"
eq "the chains are otherwise unchanged without divert" "$(chain_shape w1)" "dns localnet hosts quic tproxy "

echo "== nftables edge cases =="
: > "$STUB/empty.conf"; CONF="$STUB/empty.conf"; nftgen -
eq "no SSIDs produces no empty verdict map" "$(grep -c 'iifname vmap' "$NFT_FILE")" "0"
eq "no SSIDs still produces a table" "$(grep -c '^table inet sbproxy {' "$NFT_FILE")" "1"
eq "no SSIDs produces no dangling chain" "$(grep -c '^  chain w[0-9]* {' "$NFT_FILE")" "0"

NOIP="$STUB/noip.conf"
printf '%s\n' 'Only|2g|1|password12|proxy.example.com|1080|||1|0||socks5' > "$NOIP"
CONF="$NOIP"; nftgen -
eq "an all-hostname config emits no empty element list" "$(grep -c 'elements = { }' "$NFT_FILE")" "0"
eq "the bypass rule is still present for later additions" \
  "$(chain_body w1 | grep -c '@proxy_hosts')" "1"
CONF="$ROOT/config/wifi-socks.conf.example"

echo "== nftables device pinning =="
ASSIGN_FILE="$STUB/assign"; LEASES="$STUB/leases"
: > "$ASSIGN_FILE"; : > "$LEASES"
POOL_MAP_SIZE=512

POOL1="$STUB/pin.conf"
printf '%s\n' '1|socks5|9.9.9.9|1080|||A' '1|socks5|8.8.8.8|1080|||B' > "$POOL1"

# No pool anywhere: the map and the pin rule must not appear at all, so an
# unchanged deployment keeps generating exactly what F3 generated.
nftgen -
eq "no pool means no map"      "$(grep -c 'map w[0-9]*map' "$NFT_FILE")" "0"
eq "no pool means no pin rule" "$(grep -c 'ip saddr map' "$NFT_FILE")" "0"
eq "no pool keeps the F3 chain shape" "$(chain_shape w1)" "dns localnet hosts quic tproxy "

nftgen "$POOL1"
eq "a pooled SSID declares one map"  "$(grep -c 'map w1map' "$NFT_FILE")" "1"
eq "only the pooled SSID gets a map" "$(grep -c 'map w2map\|map w3map' "$NFT_FILE")" "0"
eq "the map is keyed by IPv4 and yields a port" \
  "$(grep -o 'map w1map { type [a-z0-9_]* : [a-z_]*' "$NFT_FILE")" \
  'map w1map { type ipv4_addr : inet_service'
eq "the map declares a size, for the fixed-size hash backend" \
  "$(grep -c 'map w1map {.*size 512' "$NFT_FILE")" "1"
eq "the map declares no timeout, which would force the resizable backend" \
  "$(grep -c 'map w1map {.*timeout' "$NFT_FILE")" "0"
eq "the pin rule sits before the default tproxy rule" "$(chain_shape w1)" \
  "dns localnet hosts quic pin tproxy "
eq "an SSID without a pool keeps the plain shape" "$(chain_shape w2)" \
  "dns localnet hosts quic tproxy "
eq "the pin rule covers tcp and udp" \
  "$(chain_body w1 | grep -c 'meta l4proto { tcp, udp } tproxy ip to :ip saddr map @w1map meta mark set 1 accept')" "1"

echo "== nftables map elements =="
# The state file identifies a device by MAC; the map is keyed by the IP that
# device currently holds, so the two are joined through the DHCP leases.
printf '%s\n' '1|aa:bb:cc:dd:ee:01|0|auto' '1|aa:bb:cc:dd:ee:02|1|manual' > "$ASSIGN_FILE"
printf '%s\n' '1700000000 aa:bb:cc:dd:ee:01 192.168.11.23 phone-a *' \
               '1700000000 aa:bb:cc:dd:ee:02 192.168.11.24 phone-b *' > "$LEASES"
nftgen "$POOL1"
eq "each pinned device maps to its slot port" \
  "$(map_elements w1map)" \
  "192.168.11.23 : $(pool_port 1 0), 192.168.11.24 : $(pool_port 1 1)"

# A device with no lease has no IP to key on. It must simply be absent, so it
# falls through to the SSID default rather than breaking the ruleset.
printf '%s\n' '1|aa:bb:cc:dd:ee:01|0|auto' '1|aa:bb:cc:dd:ee:99|1|auto' > "$ASSIGN_FILE"
nftgen "$POOL1"
eq "a device with no DHCP lease is left unpinned" \
  "$(map_elements w1map)" \
  "192.168.11.23 : $(pool_port 1 0)"

# An empty map must still be declared: the rule references it either way.
: > "$ASSIGN_FILE"; nftgen "$POOL1"
eq "an empty map is still declared" "$(grep -c 'map w1map' "$NFT_FILE")" "1"
eq "an empty map emits no element list" "$(grep -c 'elements = { }' "$NFT_FILE")" "0"
eq "the pin rule survives an empty map" "$(chain_body w1 | grep -c '@w1map')" "1"

echo "== nftables assignment hygiene =="
# Every identity below owns a lease, including the malformed ones. That is the
# point: if a guard is removed the row reaches the map and the elements change,
# instead of being filtered out a second time by a missing lease.
printf '%s\n' \
  '1700000000 aa:bb:cc:dd:ee:01 192.168.11.23 phone-a *' \
  '1700000000 aa:bb:cc:dd:ee:02 192.168.11.24 phone-b *' \
  '1700000000 aa:bb:cc:dd:ee:0 192.168.11.25 short *' \
  '1700000000 not-a-mac 192.168.11.26 bogus *' > "$LEASES"

hygiene() { # label row... -> expected element list
  _hy_lbl="$1"; _hy_want="$2"; shift 2
  printf '%s\n' "$@" > "$ASSIGN_FILE"
  nftgen "$POOL1"
  # Scoped to the map line: the proxy_hosts set also has an `elements =` list.
  eq "$_hy_lbl" "$(map_elements w1map)" "$_hy_want"
}

PIN0="192.168.11.23 : $(pool_port 1 0)"
hygiene "a well-formed row is pinned" "$PIN0" '1|aa:bb:cc:dd:ee:01|0|auto'

# Each of these differs from the row above in exactly one way.
hygiene "a MAC of the wrong length is rejected" "" '1|aa:bb:cc:dd:ee:0|0|auto'
hygiene "a MAC that is not hex is rejected"     "" '1|not-a-mac|0|auto'
hygiene "an empty MAC is rejected"              "" '1||0|auto'
hygiene "a non-numeric idx is rejected"         "" 'x|aa:bb:cc:dd:ee:01|0|auto'
hygiene "a non-numeric slot is rejected"        "" '1|aa:bb:cc:dd:ee:01|0x1|auto'
hygiene "a negative slot is rejected"           "" '1|aa:bb:cc:dd:ee:01|-1|auto'
hygiene "a short row is rejected"               "" '1|aa:bb:cc:dd:ee:01'
hygiene "a comment is not a row"                "" '# 1|aa:bb:cc:dd:ee:01|0|auto'
hygiene "a slot past the end of the pool is dropped" "" '1|aa:bb:cc:dd:ee:01|5|auto'

# The idx filter: two SSIDs, both with a lease, only one has a pool.
hygiene "a row for another SSID does not leak into this map" "$PIN0" \
  '1|aa:bb:cc:dd:ee:01|0|auto' '2|aa:bb:cc:dd:ee:02|1|auto'

# The duplicate guard: an nft map cannot hold one key twice, so a second row
# for the same device must never be emitted.
hygiene "a device pinned twice keeps its first pin" "$PIN0" \
  '1|aa:bb:cc:dd:ee:01|0|auto' '1|aa:bb:cc:dd:ee:01|1|auto'

# The slot bound is what stops a stale pin from inventing a port that no
# sing-box inbound is listening on.
hygiene "the last valid slot is still accepted" \
  "192.168.11.23 : $(pool_port 1 1)" '1|aa:bb:cc:dd:ee:01|1|auto'
hygiene "one past the last valid slot is not" "" '1|aa:bb:cc:dd:ee:01|2|auto'
: > "$ASSIGN_FILE"; : > "$LEASES"

echo "== writing the pin state =="
ASSIGN_FILE="$STUB/assign"; LEASES="$STUB/leases"
POOLS="$STUB/pin.conf"
printf '%s\n' '1|socks5|9.9.9.9|1080|||A' '1|socks5|8.8.8.8|1080|||B' \
               '1|socks5|7.7.7.7|1080|||C' > "$POOLS"
printf '%s\n' '2|socks5|6.6.6.6|1080|||D' >> "$POOLS"

arun() { # label expected(ok|die) command...
  _lbl="$1"; _want="$2"; shift 2
  if ( "$@" ) >/dev/null 2>&1; then r=ok; else r=die; fi
  if [ "$r" = "$_want" ]; then ok "$_lbl"; else no "$_lbl — got $r want $_want"; fi
}

: > "$ASSIGN_FILE"
arun "pinning a device succeeds" ok assign_set 1 AA:BB:CC:DD:EE:01 0 manual
eq "the row is written lowercase with its source" \
  "$(cat "$ASSIGN_FILE")" "1|aa:bb:cc:dd:ee:01|0|manual"
assign_set 1 aa:bb:cc:dd:ee:01 2 auto
eq "re-pinning replaces rather than appends" \
  "$(cat "$ASSIGN_FILE")" "1|aa:bb:cc:dd:ee:01|2|auto"
eq "a device is pinned once per SSID" "$(wc -l < "$ASSIGN_FILE" | tr -d ' ')" "1"

assign_set 2 aa:bb:cc:dd:ee:01 0 auto
eq "the same device can be pinned on another SSID" \
  "$(sort "$ASSIGN_FILE" | tr '\n' ' ')" \
  "1|aa:bb:cc:dd:ee:01|2|auto 2|aa:bb:cc:dd:ee:01|0|auto "

assign_clear 1 aa:bb:cc:dd:ee:01
eq "clearing removes only that SSID's row" \
  "$(cat "$ASSIGN_FILE")" "2|aa:bb:cc:dd:ee:01|0|auto"

# Exit status alone cannot separate these: a bad value usually trips more than
# one guard. Assert the message so each guard is pinned to its own case.
amsg() { # label pattern command...
  _lbl="$1"; _pat="$2"; shift 2
  _out="$( "$@" 2>&1 )" || true
  match "$_lbl" "$_out" "$_pat"
}
amsg "an SSID with no pool says exactly that" "has no proxy pool" \
  assign_set 7 aa:bb:cc:dd:ee:02 0 auto
amsg "a slot past the pool names the valid range" "slot 5 does not exist" \
  assign_set 1 aa:bb:cc:dd:ee:02 5 auto
amsg "an invalid MAC names the expected form" "expected AA:BB:CC:DD:EE:FF" \
  assign_set 1 not-a-mac 0 auto
amsg "a bogus source names the two it accepts" "must be auto or manual" \
  assign_set 1 aa:bb:cc:dd:ee:02 0 whatever
amsg "spreading onto an SSID with no pool says exactly that" "has no proxy pool" \
  assign_spread 7 "aa:bb:cc:dd:ee:01"

arun "an invalid MAC is refused"      die assign_set 1 not-a-mac 0 auto
arun "a slot past the pool is refused" die assign_set 1 aa:bb:cc:dd:ee:02 9 auto
arun "a non-numeric slot is refused"   die assign_set 1 aa:bb:cc:dd:ee:02 x auto
arun "an SSID with no pool is refused" die assign_set 7 aa:bb:cc:dd:ee:02 0 auto
arun "a bogus source is refused"       die assign_set 1 aa:bb:cc:dd:ee:02 0 whatever

echo "== orphaned pins =="
printf '%s\n' '1|aa:bb:cc:dd:ee:01|0|auto' '1|aa:bb:cc:dd:ee:02|2|manual' \
               '2|aa:bb:cc:dd:ee:03|0|auto' > "$ASSIGN_FILE"
# The pool shrinks to one proxy: slot 2 no longer exists.
printf '%s\n' '1|socks5|9.9.9.9|1080|||A' '2|socks5|6.6.6.6|1080|||D' > "$POOLS"
out="$(assign_prune 2>&1)"
eq "a pin into a vanished slot is reassigned, not dropped" \
  "$(awk -F'|' '$2=="aa:bb:cc:dd:ee:02" {print $3}' "$ASSIGN_FILE")" "0"
eq "reassignment is recorded as automatic" \
  "$(awk -F'|' '$2=="aa:bb:cc:dd:ee:02" {print $4}' "$ASSIGN_FILE")" "auto"
eq "a still-valid pin is untouched" \
  "$(awk -F'|' '$2=="aa:bb:cc:dd:ee:01" {print $3}' "$ASSIGN_FILE")" "0"
eq "another SSID is untouched" \
  "$(awk -F'|' '$1==2 {print $3}' "$ASSIGN_FILE")" "0"
match "pruning says what it changed" "$out" "aa:bb:cc:dd:ee:02"

# An SSID that loses its pool entirely has nothing left to pin to.
printf '%s\n' '1|aa:bb:cc:dd:ee:01|0|auto' '9|aa:bb:cc:dd:ee:04|0|auto' > "$ASSIGN_FILE"
assign_prune >/dev/null 2>&1
eq "pins for an SSID with no pool are removed" \
  "$(grep -c '^9|' "$ASSIGN_FILE")" "0"

echo "== spreading devices over a pool =="
printf '%s\n' '1|socks5|9.9.9.9|1080|||A' '1|socks5|8.8.8.8|1080|||B' \
               '1|socks5|7.7.7.7|1080|||C' > "$POOLS"
# Deterministic seed so the shuffle is reproducible inside the test.
counts() { awk -F'|' -v i="$1" '$1==i {print $3}' "$ASSIGN_FILE" | sort | uniq -c | awk '{print $1}' | sort -u | tr '\n' ' '; }

: > "$ASSIGN_FILE"
POOL_SHUFFLE_SEED=1 assign_spread 1 "aa:bb:cc:dd:ee:01 aa:bb:cc:dd:ee:02 aa:bb:cc:dd:ee:03 aa:bb:cc:dd:ee:04 aa:bb:cc:dd:ee:05 aa:bb:cc:dd:ee:06"
eq "six devices over three proxies land two each" "$(counts 1)" "2 "
eq "every device is pinned"        "$(grep -c '^1|' "$ASSIGN_FILE")" "6"
eq "every slot is used"            "$(awk -F'|' '{print $3}' "$ASSIGN_FILE" | sort -u | tr '\n' ' ')" "0 1 2 "

: > "$ASSIGN_FILE"
POOL_SHUFFLE_SEED=1 assign_spread 1 "aa:bb:cc:dd:ee:01 aa:bb:cc:dd:ee:02 aa:bb:cc:dd:ee:03 aa:bb:cc:dd:ee:04"
eq "four devices over three proxies differ by at most one" "$(counts 1)" "1 2 "

: > "$ASSIGN_FILE"
POOL_SHUFFLE_SEED=1 assign_spread 1 "aa:bb:cc:dd:ee:01 aa:bb:cc:dd:ee:02"
eq "fewer devices than proxies means one each" "$(counts 1)" "1 "
eq "spare proxies simply go unused" "$(grep -c '^1|' "$ASSIGN_FILE")" "2"

: > "$ASSIGN_FILE"
arun "spreading nothing is not an error" ok assign_spread 1 ""
eq "spreading nothing writes nothing" "$(wc -c < "$ASSIGN_FILE" | tr -d ' ')" "0"
arun "spreading onto an SSID with no pool is refused" die assign_spread 7 "aa:bb:cc:dd:ee:01"

# The same seed must reproduce the same layout, or a preview shown to the
# operator would not match what is then written.
: > "$ASSIGN_FILE"
POOL_SHUFFLE_SEED=42 assign_spread 1 "aa:bb:cc:dd:ee:01 aa:bb:cc:dd:ee:02 aa:bb:cc:dd:ee:03"
first="$(sort "$ASSIGN_FILE")"
: > "$ASSIGN_FILE"
POOL_SHUFFLE_SEED=42 assign_spread 1 "aa:bb:cc:dd:ee:01 aa:bb:cc:dd:ee:02 aa:bb:cc:dd:ee:03"
eq "the same seed reproduces the same layout" "$(sort "$ASSIGN_FILE")" "$first"

# And the shuffle has to actually shuffle: across a handful of seeds the layout
# must not always come out identical, or the deal would just follow MAC order.
layouts=""
for s in 1 2 3 4 5 6 7 8; do
  : > "$ASSIGN_FILE"
  POOL_SHUFFLE_SEED="$s" assign_spread 1     "aa:bb:cc:dd:ee:01 aa:bb:cc:dd:ee:02 aa:bb:cc:dd:ee:03 aa:bb:cc:dd:ee:04" >/dev/null 2>&1
  layouts="$layouts$(sort "$ASSIGN_FILE" | tr -d '
')
"
done
eq "different seeds produce different layouts"   "$(printf '%s' "$layouts" | sort -u | wc -l | tr -d ' ' | awk '{print ($1 > 1) ? "yes" : "no"}')" "yes"

echo "== choosing a slot automatically =="
printf '%s
' '1|socks5|9.9.9.9|1080|||A' '1|socks5|8.8.8.8|1080|||B'                '1|socks5|7.7.7.7|1080|||C' > "$POOLS"
: > "$ASSIGN_FILE"
eq "an empty pool starts at slot 0" "$(assign_pick_slot 1)" "0"
assign_set 1 aa:bb:cc:dd:ee:01 0 auto
eq "the next device goes to an unused slot" "$(assign_pick_slot 1)" "1"
assign_set 1 aa:bb:cc:dd:ee:02 1 auto
eq "and then to the last unused one" "$(assign_pick_slot 1)" "2"
assign_set 1 aa:bb:cc:dd:ee:03 2 auto
assign_set 1 aa:bb:cc:dd:ee:04 1 auto
eq "once every slot is used, the least loaded wins" "$(assign_pick_slot 1)" "0"
# All three slots hold one device: a tie must resolve to the lowest slot, or
# `auto` would not be reproducible.
: > "$ASSIGN_FILE"
assign_set 1 aa:bb:cc:dd:ee:01 0 auto
assign_set 1 aa:bb:cc:dd:ee:02 1 auto
assign_set 1 aa:bb:cc:dd:ee:03 2 auto
eq "a tie goes to the lowest slot" "$(assign_pick_slot 1)" "0"
: > "$ASSIGN_FILE"

echo "== apply and preflight validate the pool =="
match "apply.sh validates the pool file"    "$(cat "$ROOT/scripts/apply.sh")"    'validate_pools'
match "apply.sh reassigns orphaned pins"    "$(cat "$ROOT/scripts/apply.sh")"    'assign_prune'
match "preflight.sh validates the pool file" "$(cat "$ROOT/scripts/preflight.sh")" 'validate_pools'
match "assign.sh exists and takes idx/mac/slot" "$(cat "$ROOT/scripts/assign.sh")" 'Usage: assign.sh'
match "rebalance.sh exists"                  "$(cat "$ROOT/scripts/rebalance.sh")" 'Usage: rebalance.sh'

echo
echo "POOL TOTAL: pass=$n_ok fail=$n_bad"
[ "$n_bad" -eq 0 ]
