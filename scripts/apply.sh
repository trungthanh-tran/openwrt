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
check_unique_idx
check_bssid_limit

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
  echo "set wireless.$RADIO_2G.country=$WIFI_COUNTRY"
  echo "set wireless.$RADIO_5G.country=$WIFI_COUNTRY"
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

# Re-apply persistent MAC bans so they survive this re-apply (before wifi reload).
apply_bans

# 2) Install validated artifacts using atomic renames on the target filesystem.
mkdir -p "$(dirname "$REAL_SINGBOX_CONF")" "$(dirname "$REAL_NFT_FILE")"
cp "$SINGBOX_CONF" "$REAL_SINGBOX_CONF.new"
cp "$NFT_FILE" "$REAL_NFT_FILE.new"
mv "$REAL_SINGBOX_CONF.new" "$REAL_SINGBOX_CONF"
mv "$REAL_NFT_FILE.new" "$REAL_NFT_FILE"
SINGBOX_CONF="$REAL_SINGBOX_CONF"; NFT_FILE="$REAL_NFT_FILE"
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
log "Reloading services..."
run "/etc/init.d/network reload"
run "/etc/init.d/dnsmasq restart"
run "/etc/init.d/firewall reload"
run "/etc/init.d/sbproxy restart"
run "/etc/init.d/sing-box restart"
run "wifi reload"

log "APPLY COMPLETE. Run the test scripts described in docs/TESTING.md."
log "If networking is lost or an error occurs: scripts/rollback.sh (see docs/ROLLBACK.md)"
