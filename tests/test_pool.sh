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

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no()   { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want[$3] got[$2]"; fi; }
contains() { if printf '%s' "$2" | grep -qF "$3"; then ok "$1"; else no "$1 — missing[$3]"; fi; }

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
vsrun "a base just clear of the legacy range"    ok  "POOL_PORT_BASE=12201"

echo
echo "POOL TOTAL: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
