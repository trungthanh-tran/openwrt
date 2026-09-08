#!/bin/sh
# apply.sh — apply the complete wifi-socks.conf configuration to the router.
# Creates a backup before changes. DRYRUN=1 previews without applying changes.
#
# Usage:
#   scripts/apply.sh            # back up, apply, and reload
#   DRYRUN=1 scripts/apply.sh   # print the proposed changes only
#   scripts/apply.sh --no-backup
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root
require_conf
validate_platform
validate_settings
validate_conf
validate_pools
validate_routes
check_unique_idx
check_bssid_limit
# A pool that shrank leaves pins pointing at slots that no longer exist. Heal
# them before generating, so the ruleset is built from a consistent state.
assign_prune

NO_BACKUP=0
[ "$1" = "--no-backup" ] && NO_BACKUP=1

if [ "$NO_BACKUP" = "0" ] && [ "${DRYRUN:-0}" != "1" ]; then
  log "Backing up before apply..."
  "$SB_ROOT/scripts/backup.sh" pre-apply
fi

# 1) Generate UCI commands in a temporary file, then load them with `uci batch`.
TMP="/tmp/sbproxy-uci.$$"
: > "$TMP"; trap 'rm -rf "$TMP" "${STAGE:-}"' EXIT INT TERM
{
  if radio_country_set; then
    echo "set wireless.$RADIO_2G.country=$WIFI_COUNTRY"
    echo "set wireless.$RADIO_5G.country=$WIFI_COUNTRY"
  fi
} >> "$TMP"
emit_stale_uci >> "$TMP"
emit_all() { emit_uci_one "$@" >> "$TMP"; }
for_each_ssid emit_all
# This same guarded path is used by the Agent/UI `apply` endpoint. Never allow
# a new SSID to recreate an unscoped 80/443 INPUT reject that breaks TPROXY.
validate_admin_rule_scope "$TMP"

# Generate and validate staged artifacts without touching active files.
STAGE="/tmp/sbproxy-stage.$$"
mkdir -p "$STAGE"
REAL_SINGBOX_CONF="$SINGBOX_CONF"; REAL_NFT_FILE="$NFT_FILE"
SINGBOX_CONF="$STAGE/config.json"; NFT_FILE="$STAGE/sbproxy.nft"
build_singbox
build_nft
command -v sing-box >/dev/null 2>&1 || die "sing-box is missing."
require_singbox_version
singbox_check "$SINGBOX_CONF" || die "The sing-box configuration is invalid."
nft --check --file "$NFT_FILE" || die "The nftables configuration is invalid."

if [ "${DRYRUN:-0}" = "1" ]; then
  if [ "${DRYRUN_QUIET:-0}" != "1" ]; then
    echo "===== UCI configuration to be loaded ====="; cat "$TMP"
    echo "===== sing-box ====="; cat "$SINGBOX_CONF"
    echo "===== nftables ====="; cat "$NFT_FILE"
  fi
  log "DRY RUN complete — no system files were changed."; exit 0
fi

log "Loading UCI configuration..."
uci batch < "$TMP"
rm -f "$TMP"
uci commit network
uci commit dhcp
uci commit firewall
uci commit wireless

wire_dhcp_hook

# The package init script can restart sing-box when this logical uplink comes
# up. Persist it while the current route is still known, before network reload
# briefly removes dynamic routes.
ensure_singbox_uplink_trigger

# Re-apply persistent MAC bans so they survive this re-apply (before wifi reload).
apply_bans

# 2) Install validated artifacts using atomic renames on the target filesystem.
mkdir -p "$(dirname "$REAL_SINGBOX_CONF")" "$(dirname "$REAL_NFT_FILE")"
cp "$SINGBOX_CONF" "$REAL_SINGBOX_CONF.new"
cp "$NFT_FILE" "$REAL_NFT_FILE.new"
mv "$REAL_SINGBOX_CONF.new" "$REAL_SINGBOX_CONF"
mv "$REAL_NFT_FILE.new" "$REAL_NFT_FILE"
SINGBOX_CONF="$REAL_SINGBOX_CONF"; NFT_FILE="$REAL_NFT_FILE"
# The staged copy carried the right mode; `cp` to the live path re-applies the
# caller's umask, so the installed file gets the access fix too.
ensure_singbox_conf_access "$REAL_SINGBOX_CONF"
desired_idx | tr '\n' ' ' > /etc/sbproxy.managed
cat > /etc/sbproxy.env.new <<EOF
NFT_FILE=$NFT_FILE
TPROXY_MARK=$TPROXY_MARK
TPROXY_MARK_MASK=$TPROXY_MARK_MASK
TPROXY_TABLE=$TPROXY_TABLE
TPROXY_RULE_PRIORITY=$TPROXY_RULE_PRIORITY
SINGBOX_COMPAT_ENV="$SINGBOX_COMPAT_ENV"
EOF
mv /etc/sbproxy.env.new /etc/sbproxy.env
ensure_singbox_compat_env

# 3) Reload services in dependency order: network, firewall, TPROXY, proxy, Wi-Fi.
# Do not restart dnsmasq here. The DHCP init script already subscribes to the
# managed interface events emitted by network/wifi reload. An explicit restart
# caused a second ujail teardown and an extra, harmless
# "procd: Got unexpected signal 1" on current OpenWrt snapshots.
log "Reloading services..."
run "/etc/init.d/network reload"
run "/etc/init.d/firewall reload"
run "/etc/init.d/sbproxy restart"
ensure_singbox_privileges
ensure_singbox_service
# A dynamic uplink may need a few seconds to reacquire DHCP after network
# reload. Starting sing-box before that produced "missing default interface"
# and left fake-IP DNS unavailable until another restart.
if ! wait_for_default_route; then
  warn "No IPv4 default route after ${SINGBOX_ROUTE_WAIT:-15}s; starting sing-box anyway. Its uplink trigger will retry when the route appears."
fi
run "/etc/init.d/sing-box restart"
run "wifi reload"
recover_wifi_networks
# Verify sing-box only after Wi-Fi is back up: when sing-box cannot start,
# the apply must fail loudly, but with the SSIDs broadcasting (unproxied
# clients are held by nftables anyway) — dying before `wifi reload` used to
# leave every SSID down AND the operator without a management path.
verify_singbox_running

log "APPLY COMPLETE. Run the test scripts described in docs/TESTING.md."
log "If networking is lost or an error occurs: scripts/rollback.sh (see docs/ROLLBACK.md)"
