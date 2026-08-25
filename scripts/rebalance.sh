#!/bin/sh
# rebalance.sh — spread a set of devices evenly over one Wi-Fi's proxy pool.
#
# Devices are shuffled and then dealt round-robin, so the number of devices per
# proxy differs by at most one and the layout is not predictable from the order
# of the MAC list. Nothing is reloaded: each device is pinned by adding one
# element to that SSID's nftables map.
#
# Usage:
#   scripts/rebalance.sh <idx> --macs AA:..:01,AA:..:02   # these devices
#   scripts/rebalance.sh <idx> --online                   # everything connected now
#   scripts/rebalance.sh <idx> --online --dry-run         # show the layout only
#
# POOL_SHUFFLE_SEED=<n> reproduces a previous layout; --dry-run prints the seed
# it used so the same split can be committed afterwards.
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_conf

IDX=""; MACS=""; ONLINE=0; DRYRUN_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --macs) MACS="$(printf '%s' "${2:-}" | tr ',' ' ')"; shift 2 ;;
    --online) ONLINE=1; shift ;;
    --dry-run) DRYRUN_ONLY=1; shift ;;
    -*) die "Usage: rebalance.sh <idx> [--macs a,b,c] [--online] [--dry-run]" ;;
    *) IDX="$1"; shift ;;
  esac
done
[ -n "$IDX" ] || die "Usage: rebalance.sh <idx> [--macs a,b,c] [--online] [--dry-run]"
case "$IDX" in *[!0-9]*) die "idx must be a positive integer" ;; esac

SLOTS="$(pool_count "$IDX")"
[ "$SLOTS" -gt 0 ] || die "Wi-Fi idx=$IDX has no proxy pool (see config/proxy-pools.conf)"

if [ "$ONLINE" = "1" ]; then
  ifname="$(ifname_of_idx "$IDX")"
  [ -n "$ifname" ] || die "Wi-Fi idx=$IDX is not up, so its clients cannot be listed"
  MACS="$MACS $(iw dev "$ifname" station dump 2>/dev/null \
    | awk '/^Station/ { print tolower($2) }' | tr '\n' ' ')"
fi

# Normalise and drop anything that is not a MAC, rather than failing the whole
# run on one bad entry from a pasted list.
CLEAN=""
for m in $MACS; do
  m="$(printf '%s' "$m" | tr 'A-Z' 'a-z')"
  if assign_valid_mac "$m"; then CLEAN="$CLEAN $m"; else warn "Ignoring '$m': not a MAC address"; fi
done
CLEAN="${CLEAN# }"
[ -n "$CLEAN" ] || die "No devices to rebalance"

# The seed is chosen here, not inside assign_spread, so a --dry-run preview and
# the run that commits it can be given the same one.
POOL_SHUFFLE_SEED="${POOL_SHUFFLE_SEED:-$(head -c 8 /dev/urandom | cksum | cut -d' ' -f1)}"
export POOL_SHUFFLE_SEED

if [ "$DRYRUN_ONLY" = "1" ]; then
  echo "Layout for idx=$IDX with seed $POOL_SHUFFLE_SEED (nothing written):"
  ASSIGN_FILE="$(mktemp)"; : > "$ASSIGN_FILE"
  assign_spread "$IDX" "$CLEAN" >/dev/null 2>&1
  awk -F'|' -v root="$SB_ROOT" '{ printf "  %s -> slot %s\n", $2, $3 }' "$ASSIGN_FILE" | sort
  rm -f "$ASSIGN_FILE"
  echo "Re-run with POOL_SHUFFLE_SEED=$POOL_SHUFFLE_SEED to commit exactly this layout."
  exit 0
fi

require_root
assign_spread "$IDX" "$CLEAN"

# Push every pin into the running ruleset.
for m in $CLEAN; do
  slot="$(awk -F'|' -v i="$IDX" -v m="$m" '$1==i && $2==m { print $3; exit }' "$ASSIGN_FILE")"
  [ -n "$slot" ] && assign_live_update "$IDX" "$m" "$slot"
done

log "Rebalanced on idx=$IDX. Connections already open keep their previous proxy until they close."
log "To cut over immediately, kick the devices: scripts/kick.sh $IDX <mac>"
