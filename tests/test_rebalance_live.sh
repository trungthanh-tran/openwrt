#!/bin/sh
# Live acceptance test. Run as root on the router, for example:
#   sh tests/test_rebalance_live.sh 4
#
# This intentionally commits assignments for currently online clients on the
# selected SSID. It is separate from the fixture tests because it needs iw,
# the real nftables state, and a real proxy pool.
set -eu

SB_ROOT="${SB_ROOT:-/root/sbproxy}"
IDX="${1:-4}"
MAC="${MAC:-f0:20:ff:20:08:a5}"
REBALANCE="$SB_ROOT/scripts/rebalance.sh"

[ "$(id -u)" = 0 ] || { echo "FAIL: run as root" >&2; exit 1; }
[ -x "$REBALANCE" ] || { echo "FAIL: missing $REBALANCE" >&2; exit 1; }

clients="$(sh "$SB_ROOT/scripts/clients.sh")"
printf '%s' "$clients" | jq -e --arg mac "$MAC" --argjson idx "$IDX" \
  '.clients[] | select(.mac == $mac and .online == true and .idx == $idx)' >/dev/null \
  || { echo "FAIL: real client $MAC is not online on idx=$IDX" >&2; exit 1; }
pool_size="$(printf '%s' "$clients" | jq -r --arg mac "$MAC" '.clients[] | select(.mac == $mac) | .pool_size')"
[ "$pool_size" -gt 0 ] || { echo "FAIL: client has no proxy pool" >&2; exit 1; }
printf 'PASS: real client online mac=%s pool_size=%s\n' "$MAC" "$pool_size"

seed="$(cd "$SB_ROOT" && sh scripts/rebalance.sh "$IDX" --online --dry-run \
  | sed -n 's/.*with seed \([0-9][0-9]*\) (nothing written).*/\1/p' \
  | head -n 1)"
[ -n "$seed" ] || { echo "FAIL: dry-run did not produce a numeric seed" >&2; exit 1; }
printf 'PASS: dry-run generated seed=%s without requiring cksum\n' "$seed"

same="$(cd "$SB_ROOT" && sh scripts/rebalance.sh "$IDX" --online --dry-run --seed "$seed")"
printf '%s\n' "$same" | grep -q "with seed $seed"
printf 'PASS: explicit seed reproduces preview\n'

out="$(cd "$SB_ROOT" && sh scripts/rebalance.sh "$IDX" --online --seed "$seed" 2>&1)"
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q 'Rebalanced on idx='
after="$(sh "$SB_ROOT/scripts/clients.sh")"
printf '%s' "$after" | jq -e --arg mac "$MAC" \
  '.clients[] | select(.mac == $mac and .online == true and .proxy_state == "pinned" and .slot != null)' >/dev/null \
  || { echo "FAIL: live client is not pinned after commit" >&2; exit 1; }
printf 'PASS: live rebalance commit and pin idx=%s seed=%s\n' "$IDX" "$seed"
