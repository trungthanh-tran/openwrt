#!/bin/sh
# tests/test_assignd.sh — the automatic side of proxy pinning: which slot a
# device that has just appeared gets, whether it gets pinned twice, and how the
# live nftables map is put back after it drifts.
#
# No router needed. nft is stubbed by a script on PATH that records what it was
# asked to do, so the self-healing path can be driven without a kernel.
# shellcheck disable=SC2034  # POOL_* and ASSIGN_FILE are read by the lib.sh functions under test.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB_ROOT="$ROOT"; export SB_ROOT
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT INT TERM

CONF="$ROOT/config/wifi-socks.conf.example"; export CONF
# shellcheck source=/dev/null
. "$ROOT/scripts/lib.sh"

POOL_PORT_BASE=13000
POOL_PORT_STRIDE=256
POOL_SLOTS_PER_SSID_MAX=256
ASSIGN_FILE="$STUB/assign"
LEASES="$STUB/leases"
POOLS="$STUB/pool.conf"

n_ok=0; n_bad=0
ok()   { n_ok=$((n_ok + 1)); printf '  ok   %s\n' "$1"; }
no()   { n_bad=$((n_bad + 1)); printf '  FAIL %s\n' "$1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want[$3] got[$2]"; fi; }
contains()     { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 — missing[$3]"; fi; }
not_contains() { if printf '%s' "$2" | grep -qF -- "$3"; then no "$1 — found[$3]"; else ok "$1"; fi; }

mkpool() { printf '%s\n' "$1" > "$POOLS"; }
reset_state() { : > "$ASSIGN_FILE"; }
slot_of() { awk -F'|' -v i="$1" -v m="$2" '$1==i && $2==m { print $3; exit }' "$ASSIGN_FILE"; }
source_of() { awk -F'|' -v i="$1" -v m="$2" '$1==i && $2==m { print $4; exit }' "$ASSIGN_FILE"; }
rows_for() { awk -F'|' -v i="$1" '$1==i' "$ASSIGN_FILE" | wc -l | tr -d ' '; }

# A pool of four proxies on idx=1, and one on idx=2.
mkpool '1|socks5|1.0.0.1|1080|||a
1|socks5|1.0.0.2|1080|||b
1|socks5|1.0.0.3|1080|||c
1|socks5|1.0.0.4|1080|||d
2|http|2.0.0.1|8080|||'
printf '111 aa:bb:cc:dd:ee:01 192.168.11.11 h1 *\n' > "$LEASES"

echo "== the policies =="
reset_state
eq "least-loaded fills an empty pool from the lowest slot" \
   "$(POOL_ASSIGN_POLICY=least-loaded assign_policy_slot 1 aa:bb:cc:dd:ee:01)" "0"

# sticky-hash exists so a device lands on the same proxy after the state file
# has been thrown away, which is the whole reason to prefer it over random.
h1="$(POOL_ASSIGN_POLICY=sticky-hash assign_policy_slot 1 aa:bb:cc:dd:ee:07)"
reset_state
h2="$(POOL_ASSIGN_POLICY=sticky-hash assign_policy_slot 1 aa:bb:cc:dd:ee:07)"
eq "sticky-hash survives the state being wiped" "$h1" "$h2"
eq "sticky-hash stays inside the pool" "$([ "$h1" -ge 0 ] && [ "$h1" -lt 4 ] && echo yes)" "yes"
different=no
for m in 01 02 03 04 05 06 07 08; do
  s="$(POOL_ASSIGN_POLICY=sticky-hash assign_policy_slot 1 "aa:bb:cc:dd:ee:$m")"
  [ "$s" = "$h1" ] || different=yes
done
eq "sticky-hash does not send every device to one proxy" "$different" "yes"

reset_state
rr=""
for m in 01 02 03 04 05; do
  s="$(POOL_ASSIGN_POLICY=round-robin assign_policy_slot 1 "aa:bb:cc:dd:ee:$m")"
  rr="$rr$s"
  assign_set 1 "aa:bb:cc:dd:ee:$m" "$s" auto
done
eq "round-robin walks the pool and wraps" "$rr" "01230"

reset_state
seen=""
n=0
while [ "$n" -lt 40 ]; do
  s="$(POOL_ASSIGN_POLICY=random assign_policy_slot 1 aa:bb:cc:dd:ee:01)"
  case "$s" in 0|1|2|3) : ;; *) seen="out-of-range" ;; esac
  case "$seen" in *"$s"*) : ;; *) seen="$seen$s" ;; esac
  n=$(( n + 1 ))
done
eq "random stays inside the pool" "$(printf '%s' "$seen" | grep -c 'out-of-range')" "0"
eq "random does not always answer the same slot" \
   "$([ "${#seen}" -gt 1 ] && echo yes)" "yes"

eq "the default policy is random" \
   "$(unset POOL_ASSIGN_POLICY 2>/dev/null; sed -n 's/^POOL_ASSIGN_POLICY=//p' "$ROOT/config/settings.sh" | tr -d '"')" \
   "random"

if ( POOL_ASSIGN_POLICY=nonsense assign_policy_slot 1 aa:bb:cc:dd:ee:01 ) >/dev/null 2>&1; then
  no "an unknown policy is refused"
else
  ok "an unknown policy is refused"
fi

# od and hexdump are what broke self-update in 0.4.10: many OpenWrt images do
# not build them in, so the pool's randomness must not depend on either. This
# reads pool_random's own body rather than the whole library: rand_mac_bytes
# still uses hexdump with an od fallback and a die() if neither exists, which
# is a separate pre-existing weakness and not this feature's to change.
pool_random_src="$(awk '/^pool_random\(\) \{/, /^\}/' "$ROOT/scripts/lib.sh")"
not_contains "the pool RNG does not call hexdump" "$pool_random_src" "hexdump"
not_contains "the pool RNG does not call od"      "$pool_random_src" "od -"
contains     "it seeds from /dev/urandom"         "$pool_random_src" "/dev/urandom"
contains     "through cksum, which busybox always has" "$pool_random_src" "cksum"

echo "== pinning a device that has just appeared =="
reset_state
assign_ensure 1 aa:bb:cc:dd:ee:01 >/dev/null
eq "a new device is pinned"          "$(rows_for 1)" "1"
eq "and marked as automatic"         "$(source_of 1 aa:bb:cc:dd:ee:01)" "auto"
first="$(slot_of 1 aa:bb:cc:dd:ee:01)"
POOL_ASSIGN_POLICY=round-robin assign_ensure 1 aa:bb:cc:dd:ee:01 >/dev/null
POOL_ASSIGN_POLICY=round-robin assign_ensure 1 aa:bb:cc:dd:ee:01 >/dev/null
eq "a device already pinned is not pinned again" "$(rows_for 1)" "1"
eq "and keeps the slot it had"       "$(slot_of 1 aa:bb:cc:dd:ee:01)" "$first"
eq "the slot is reported back"       "$(assign_ensure 1 aa:bb:cc:dd:ee:01)" "$first"

# Rotation belongs to a genuine (re)connection. The safety-net sweep runs every
# few seconds, and if it rotated too the device would change proxy constantly.
reset_state
assign_set 1 aa:bb:cc:dd:ee:02 0 auto
POOL_ROTATE_ON_RECONNECT=1 POOL_ASSIGN_POLICY=round-robin assign_ensure 1 aa:bb:cc:dd:ee:02 >/dev/null
eq "a sweep never rotates, even with rotation on" "$(slot_of 1 aa:bb:cc:dd:ee:02)" "0"
POOL_ROTATE_ON_RECONNECT=1 POOL_ASSIGN_POLICY=round-robin assign_ensure 1 aa:bb:cc:dd:ee:02 1 >/dev/null
eq "a reconnection rotates when asked to" \
   "$([ "$(slot_of 1 aa:bb:cc:dd:ee:02)" != "0" ] && echo moved)" "moved"
reset_state
assign_set 1 aa:bb:cc:dd:ee:02 0 auto
POOL_ROTATE_ON_RECONNECT=0 POOL_ASSIGN_POLICY=round-robin assign_ensure 1 aa:bb:cc:dd:ee:02 1 >/dev/null
eq "rotation off means a reconnection changes nothing" "$(slot_of 1 aa:bb:cc:dd:ee:02)" "0"

# A manual pin is the operator's decision and a reconnection must not undo it.
reset_state
assign_set 1 aa:bb:cc:dd:ee:03 2 manual
POOL_ROTATE_ON_RECONNECT=1 POOL_ASSIGN_POLICY=round-robin assign_ensure 1 aa:bb:cc:dd:ee:03 1 >/dev/null
eq "a manual pin is never rotated away" "$(slot_of 1 aa:bb:cc:dd:ee:03)" "2"
eq "and stays manual"                   "$(source_of 1 aa:bb:cc:dd:ee:03)" "manual"

reset_state
assign_ensure 9 aa:bb:cc:dd:ee:01 >/dev/null 2>&1
eq "an SSID with no pool is left alone"  "$(rows_for 9)" "0"
eq "and that is not an error"            "$(assign_ensure 9 aa:bb:cc:dd:ee:01 >/dev/null 2>&1 && echo ok)" "ok"
assign_ensure 1 "not-a-mac" >/dev/null 2>&1
eq "a malformed MAC is ignored"          "$(rows_for 1)" "0"
eq "and that is not an error either"     "$(assign_ensure 1 'not-a-mac' >/dev/null 2>&1 && echo ok)" "ok"

echo "== healing the live map =="
mkdir -p "$STUB/bin"
cat > "$STUB/bin/nft" <<'NFT'
#!/bin/sh
echo "$*" >> "$NFT_LOG"
case "$1 $2" in
  "list map")
    [ -f "$NFT_MAP" ] || exit 1
    cat "$NFT_MAP"
    ;;
esac
exit 0
NFT
chmod +x "$STUB/bin/nft"
PATH="$STUB/bin:$PATH"; export PATH
NFT_LOG="$STUB/nft.log"; export NFT_LOG
NFT_MAP="$STUB/nft.map"; export NFT_MAP

map_with() { # elements...
  if [ -z "${1:-}" ]; then
    printf 'table inet sbproxy {\n\tmap w1map {\n\t\ttype ipv4_addr : inet_service\n\t\tsize 512\n\t}\n}\n' > "$NFT_MAP"
  else
    printf 'table inet sbproxy {\n\tmap w1map {\n\t\ttype ipv4_addr : inet_service\n\t\tsize 512\n\t\telements = { %s }\n\t}\n}\n' "$1" > "$NFT_MAP"
  fi
}

printf '111 aa:bb:cc:dd:ee:01 192.168.11.11 h1 *\n222 aa:bb:cc:dd:ee:02 192.168.11.12 h2 *\n' > "$LEASES"
reset_state
assign_set 1 aa:bb:cc:dd:ee:01 0 auto
assign_set 1 aa:bb:cc:dd:ee:02 1 auto

map_with '192.168.11.11 : 13256, 192.168.11.12 : 13257'
eq "the live map is counted, not guessed" "$(assign_map_size 1)" "2"
: > "$NFT_LOG"
assign_sync_map 1 >/dev/null 2>&1
not_contains "a map that agrees with the state is left alone" "$(cat "$NFT_LOG")" "flush map"

map_with '192.168.11.11 : 13256'
: > "$NFT_LOG"
assign_sync_map 1 >/dev/null 2>&1
contains "a short map is flushed"      "$(cat "$NFT_LOG")" "flush map inet sbproxy w1map"
contains "and reloaded from the state" "$(cat "$NFT_LOG")" "192.168.11.12 : 13257"

# Extra elements matter as much as missing ones: a device left in the map after
# its pin was cleared keeps using a proxy nobody assigned it.
map_with '192.168.11.11 : 13256, 192.168.11.12 : 13257, 192.168.11.99 : 13258'
: > "$NFT_LOG"
assign_sync_map 1 >/dev/null 2>&1
contains "a map with strangers in it is flushed too" "$(cat "$NFT_LOG")" "flush map inet sbproxy w1map"
not_contains "and the stranger does not come back" "$(cat "$NFT_LOG")" "192.168.11.99"

reset_state
map_with ''
: > "$NFT_LOG"
assign_sync_map 1 >/dev/null 2>&1
not_contains "an empty map with no pins needs no work" "$(cat "$NFT_LOG")" "flush map"

: > "$NFT_LOG"
assign_sync_map 9 >/dev/null 2>&1
eq "an SSID with no pool is not touched" "$(wc -l < "$NFT_LOG" | tr -d ' ')" "0"

printf '\nASSIGND TOTAL: pass=%s fail=%s\n' "$n_ok" "$n_bad"
[ "$n_bad" -eq 0 ]
