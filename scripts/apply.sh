#!/bin/sh
# apply.sh — áp toàn bộ config từ wifi-socks.conf lên router.
# Tự backup trước khi đổi. Hỗ trợ DRYRUN=1 để xem trước không thực thi.
#
# Dùng:
#   scripts/apply.sh            # backup + áp + reload
#   DRYRUN=1 scripts/apply.sh   # chỉ in ra những gì sẽ làm
#   scripts/apply.sh --no-backup
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root
require_conf
check_unique_idx
check_bssid_limit

NO_BACKUP=0
[ "$1" = "--no-backup" ] && NO_BACKUP=1

if [ "$NO_BACKUP" = "0" ] && [ "${DRYRUN:-0}" != "1" ]; then
  log "Backup trước khi apply..."
  "$SB_ROOT/scripts/backup.sh" pre-apply
fi

# 1) Sinh lệnh UCI vào file tạm rồi nạp bằng `uci batch`
TMP="/tmp/sbproxy-uci.$$"
: > "$TMP"
emit_all() { emit_uci_one "$@" >> "$TMP"; }
for_each_ssid emit_all

if [ "${DRYRUN:-0}" = "1" ]; then
  echo "===== UCI sẽ nạp ====="; cat "$TMP"
  echo "===== sing-box ====="; build_singbox; cat "$SINGBOX_CONF" 2>/dev/null || true
  echo "===== nftables ====="; build_nft; cat "$NFT_FILE" 2>/dev/null || true
  rm -f "$TMP"; log "DRYRUN xong — không có gì bị thay đổi."; exit 0
fi

log "Nạp UCI..."
uci batch < "$TMP"
rm -f "$TMP"
uci commit network
uci commit dhcp
uci commit firewall
uci commit wireless

# 2) sing-box + nftables
build_singbox
build_nft

# 3) Reload dịch vụ (thứ tự: mạng -> firewall -> tproxy -> proxy -> wifi)
log "Reload dịch vụ..."
run "/etc/init.d/network reload"
run "/etc/init.d/dnsmasq restart"
run "/etc/init.d/firewall reload"
run "/etc/init.d/sbproxy restart"
run "/etc/init.d/sing-box restart"
run "wifi reload"

log "APPLY XONG. Chạy scripts kiểm thử trong docs/TESTING.md."
log "Nếu mất mạng/lỗi: scripts/rollback.sh  (xem docs/ROLLBACK.md)"
