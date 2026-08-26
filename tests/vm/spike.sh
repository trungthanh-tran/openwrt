#!/bin/sh
# tests/vm/spike.sh — the P1 spike: ask a real kernel whether the proxy-pool
# design is actually loadable. Run this on an OpenWrt VM or on the router.
#
#   sh tests/vm/spike.sh            # everything except the RAM measurement
#   sh tests/vm/spike.sh --ram      # also measure sing-box RSS per slot count
#
# WHY THIS EXISTS
#
# The workstation suites check the *text* the generator produces. They cannot
# check whether the kernel accepts it: `nft -c` parses and validates against the
# local nft binary, but expression support lives in the kernel modules, and a
# rule that parses can still fail to load. Every decision marked "⚠️ phải spike"
# in docs/plan-proxy-pool.md comes down to that difference.
#
# WHAT IT DOES TO THE MACHINE
#
# It loads real rules into a table of its own, `inet sbproxy_spike`, and deletes
# it again on exit. It never touches `inet sbproxy`. Every chain hooks
# prerouting at priority 1000 -- after everything else -- and every rule matches
# only 203.0.113.199, an address from TEST-NET-3 that no real traffic uses. So
# the rules prove the kernel accepts them without diverting a single packet.
#
# Running it on a live router is safe by that construction, but it does need
# root, and it does briefly add a table.
set -u

TABLE="sbproxy_spike"
NEVER="203.0.113.199"        # TEST-NET-3, RFC 5737: never appears on the wire
n_ok=0; n_bad=0; n_skip=0
ok()   { n_ok=$((n_ok + 1));   printf '  ok    %s\n' "$1"; }
no()   { n_bad=$((n_bad + 1)); printf '  FAIL  %s\n' "$1"; }
skip() { n_skip=$((n_skip + 1)); printf '  skip  %s (%s)\n' "$1" "$2"; }

cleanup() { nft delete table inet "$TABLE" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

[ "$(id -u)" = "0" ] || { echo "spike.sh must run as root (it loads nftables rules)"; exit 1; }
command -v nft >/dev/null 2>&1 || { echo "spike.sh needs nft"; exit 1; }

echo "== what this kernel is =="
echo "  $(uname -srm)"
[ -f /etc/openwrt_release ] && sed -n 's/^DISTRIB_DESCRIPTION=//p' /etc/openwrt_release | tr -d "'"
echo "  nft $(nft --version 2>/dev/null | head -1)"

# Loads a ruleset and reports whether the kernel took it. The whole table goes
# in and comes back out each time, so one failure cannot affect the next case.
try_load() { # label ruleset
  cleanup
  if printf '%s\n' "$2" | nft -f - >/dev/null 2>&1; then ok "$1"; cleanup; return 0; fi
  # Rerun without silencing, so the operator sees the kernel's own words.
  printf '  ----- nft said -----\n' >&2
  printf '%s\n' "$2" | nft -f - >&2 2>&1 | sed 's/^/  /' >&2
  printf '  --------------------\n' >&2
  no "$1"; cleanup; return 1
}

echo
echo "== D2: the whole design rests on this one rule =="
# A map from source address straight to a TPROXY port. If the kernel refuses
# this, D2 is dead and D2a (one set per slot) has to replace F2-F4.
try_load "tproxy takes its port from a map keyed by source address" \
"table inet $TABLE {
  map w1map {
    type ipv4_addr : inet_service
    size 512
    elements = { $NEVER : 13256, 203.0.113.200 : 13257 }
  }
  chain pre {
    type filter hook prerouting priority 1000; policy accept;
    ip saddr $NEVER meta l4proto { tcp, udp } tproxy ip to :ip saddr map @w1map accept
  }
}"
D2_OK=$?

echo
echo "== D2a: the fallback, if D2 is dead =="
try_load "one set per slot, with a literal port" \
"table inet $TABLE {
  set slot0 { type ipv4_addr; size 512; elements = { $NEVER } }
  chain pre {
    type filter hook prerouting priority 1000; policy accept;
    ip saddr $NEVER ip saddr @slot0 meta l4proto { tcp, udp } tproxy ip to :13256 accept
  }
}"

echo
echo "== D9: divert, so lookups happen per connection not per packet =="
if [ -d /sys/module/nft_socket ] || grep -q nft_socket /proc/modules 2>/dev/null; then
  ok "nft_socket is loaded"
else
  skip "nft_socket is loaded" "not in /proc/modules; the load below is the real test"
fi
try_load "socket transparent 1 is accepted by the kernel" \
"table inet $TABLE {
  chain pre {
    type filter hook prerouting priority 1000; policy accept;
    ip saddr $NEVER meta l4proto tcp socket transparent 1 accept
  }
}"

echo
echo "== D3: one chain per SSID, entered through a verdict map =="
try_load "iifname vmap dispatches into per-SSID chains" \
"table inet $TABLE {
  chain w1 { ip saddr $NEVER accept }
  chain w2 { ip saddr $NEVER accept }
  chain pre {
    type filter hook prerouting priority 1000; policy accept;
    ip saddr $NEVER iifname vmap { \"br-w1\" : jump w1, \"br-w2\" : jump w2 }
  }
}"

echo
echo "== D4: pins baked into the generated file, restored with the table =="
try_load "a map with a declared size and inline elements" \
"table inet $TABLE {
  map w1map {
    type ipv4_addr : inet_service
    size 512
    elements = { $NEVER : 13256 }
  }
}"

echo
echo "== the live path: add, list, delete one element =="
cleanup
if printf 'table inet %s {\n  map w1map { type ipv4_addr : inet_service; size 512; }\n}\n' "$TABLE" \
   | nft -f - >/dev/null 2>&1; then
  if nft add element inet "$TABLE" w1map "{ $NEVER : 13256 }" >/dev/null 2>&1; then
    ok "nft add element pins a device without reloading anything"
  else
    no "nft add element pins a device without reloading anything"
  fi
  # assign_map_size() in scripts/lib.sh counts elements out of this output. If
  # the shape differs here, self-healing will reload the map on every sweep.
  listed="$(nft list map inet "$TABLE" w1map 2>/dev/null \
            | awk '/elements = \{/, /\}/' | tr ',' '\n' | grep -c ':')"
  if [ "$listed" = "1" ]; then
    ok "nft list map is countable the way assign_map_size counts it"
  else
    no "nft list map is countable the way assign_map_size counts it — got [$listed], want [1]"
    printf '  ----- nft list map said -----\n'
    nft list map inet "$TABLE" w1map 2>&1 | sed 's/^/  /'
    printf '  -----------------------------\n'
  fi
  if nft delete element inet "$TABLE" w1map "{ $NEVER }" >/dev/null 2>&1; then
    ok "nft delete element unpins one device"
  else
    no "nft delete element unpins one device"
  fi
else
  no "a bare map could not be created at all"
fi
cleanup

echo
echo "== how big a ruleset this kernel will take =="
# 32 SSIDs is the ceiling D12 falls back to. Loading that shape proves the
# generated file will load; it says nothing about throughput.
rules="table inet $TABLE {"
i=1
while [ "$i" -le 32 ]; do
  rules="$rules
  map w${i}map { type ipv4_addr : inet_service; size 512; }
  chain w$i { ip saddr $NEVER meta l4proto { tcp, udp } tproxy ip to :ip saddr map @w${i}map accept }"
  i=$((i + 1))
done
rules="$rules
  chain pre { type filter hook prerouting priority 1000; policy accept; }
}"
if [ "$D2_OK" = "0" ]; then
  try_load "32 SSIDs' worth of maps and chains load together" "$rules"
else
  skip "32 SSIDs' worth of maps and chains load together" "D2 failed, so this shape is moot"
fi

if [ "${1:-}" = "--ram" ]; then
  echo
  echo "== D10: sing-box RSS against slot count =="
  if command -v sing-box >/dev/null 2>&1; then
    echo "  Not implemented yet: this needs a generated config per slot count and"
    echo "  a running instance to measure. See docs/plan-proxy-pool.md section 3.5."
    skip "sing-box RSS per slot count" "measurement harness not written"
  else
    skip "sing-box RSS per slot count" "sing-box is not installed"
  fi
fi

echo
printf 'SPIKE TOTAL: pass=%s fail=%s skip=%s\n' "$n_ok" "$n_bad" "$n_skip"
if [ "$n_bad" -ne 0 ] && [ "$D2_OK" != "0" ]; then
  echo
  echo "D2 did not load. docs/plan-proxy-pool.md D2a is the documented fallback:"
  echo "one set per slot with a literal tproxy port, which is linear in the"
  echo "number of slots. build_nft() in scripts/lib.sh is the only place to change."
fi
[ "$n_bad" -eq 0 ]
