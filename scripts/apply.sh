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
  log "Backup trước khi apply..."
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

# Generate and validate staged artifacts without touching active files.
STAGE="/tmp/sbproxy-stage.$$"
mkdir -p "$STAGE"
REAL_SINGBOX_CONF="$SINGBOX_CONF"; REAL_NFT_FILE="$NFT_FILE"
SINGBOX_CONF="$STAGE/config.json"; NFT_FILE="$STAGE/sbproxy.nft"
build_singbox
build_nft
command -v sing-box >/dev/null 2>&1 || die "Thiếu sing-box."
sing-box check -c "$SINGBOX_CONF" || die "sing-box config không hợp lệ."
nft --check --file "$NFT_FILE" || die "nftables config không hợp lệ."

if [ "${DRYRUN:-0}" = "1" ]; then
  echo "===== UCI sẽ nạp ====="; cat "$TMP"
  echo "===== sing-box ====="; cat "$SINGBOX_CONF"
  echo "===== nftables ====="; cat "$NFT_FILE"
  log "DRYRUN xong — không có file hệ thống nào bị thay đổi."; exit 0
fi

log "Nạp UCI..."
uci batch < "$TMP"
rm -f "$TMP"
uci commit network
uci commit dhcp
uci commit firewall
uci commit wireless

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
EOF
mv /etc/sbproxy.env.new /etc/sbproxy.env

# 3) Reload services in dependency order: network, firewall, TPROXY, proxy, Wi-Fi.
log "Reload dịch vụ..."
run "/etc/init.d/network reload"
run "/etc/init.d/dnsmasq restart"
run "/etc/init.d/firewall reload"
run "/etc/init.d/sbproxy restart"
run "/etc/init.d/sing-box restart"
run "wifi reload"

log "APPLY XONG. Chạy scripts kiểm thử trong docs/TESTING.md."
log "Nếu mất mạng/lỗi: scripts/rollback.sh  (xem docs/ROLLBACK.md)"
