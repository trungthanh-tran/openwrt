#!/bin/sh
# uninstall.sh — remove project-managed SSIDs, zones, and interfaces by config index.
# Does not remove packages. Creates a backup first.
#
# Usage: scripts/uninstall.sh
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root
require_conf

log "Backup trước khi gỡ..."
"$SB_ROOT/scripts/backup.sh" pre-uninstall

del_one() {
  idx="$3"
  for s in "wireless.w$idx" "network.w$idx" "network.brw$idx" "dhcp.w$idx" \
           "firewall.z$idx" "firewall.z${idx}adm"; do
    uci -q delete "$s" 2>/dev/null || true
  done
  log "Đã xoá section idx=$idx"
}
for_each_ssid del_one

uci commit
log "Dừng tproxy + xoá nft/sing-box config..."
/etc/init.d/sbproxy stop 2>/dev/null || true
nft delete table inet sbproxy 2>/dev/null || true
rm -f "$NFT_FILE"
/etc/init.d/sing-box stop 2>/dev/null || true
rm -f "${SINGBOX_CACHE:-/etc/sing-box/cache.db}"
rm -f "${BANS_FILE:-/etc/sbproxy.bans}"
# Remove the compat env line apply.sh injected into the packaged init script.
[ -f /etc/init.d/sing-box ] && sed -i '/procd_set_param env ENABLE_DEPRECATED/d' /etc/init.d/sing-box

/etc/init.d/network reload  || true
/etc/init.d/firewall reload || true
wifi reload || true

log "GỠ XONG. (Gói opkg vẫn còn — muốn xoá: opkg remove sing-box ...)"
