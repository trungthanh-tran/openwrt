#!/bin/sh
# rollback.sh — khôi phục cấu hình từ backup gần nhất (hoặc bản chỉ định).
#
# Dùng:
#   scripts/rollback.sh --list          # liệt kê các bản backup
#   scripts/rollback.sh                  # rollback về bản 'latest'
#   scripts/rollback.sh 20260812-101500-pre-apply
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root

if [ "$1" = "--list" ]; then
  echo "Backup có sẵn trong $BACKUP_DIR:"
  ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null | sed "s#$BACKUP_DIR/##;s#/\$##" || echo "  (chưa có)"
  echo "'latest' -> $(readlink -f "$BACKUP_DIR/latest" 2>/dev/null || echo none)"
  exit 0
fi

if [ -n "$1" ]; then SRC="$BACKUP_DIR/$1"; else SRC="$(readlink -f "$BACKUP_DIR/latest" 2>/dev/null)"; fi
[ -n "$SRC" ] && [ -d "$SRC" ] || die "Không tìm thấy backup: ${1:-latest}. Xem: rollback.sh --list"

log "Rollback từ: $SRC"
# SB_YES=1 -> bỏ qua xác nhận (agent/CGI gọi không tương tác)
if [ "$SB_YES" != "1" ]; then
  printf "Việc này GHI ĐÈ /etc/config, /etc/sing-box, %s. Tiếp tục? [y/N] " "$NFT_FILE"
  read -r ans; case "$ans" in y|Y) : ;; *) die "Đã huỷ."; esac
fi

# 1) Khôi phục file cấu hình
[ -f "$SRC/etc-config.tar.gz" ] && tar xzf "$SRC/etc-config.tar.gz" -C / && log "Đã phục hồi /etc/config + /etc/sing-box"
[ -f "$SRC/sbproxy.nft" ] && cp "$SRC/sbproxy.nft" "$NFT_FILE" && log "Đã phục hồi $NFT_FILE"
[ -f "$SRC/wifi-socks.conf" ] && cp "$SRC/wifi-socks.conf" "$CONF" && log "Đã phục hồi wifi-socks.conf"

# 2) Reload toàn bộ dịch vụ
log "Reload dịch vụ..."
uci commit 2>/dev/null || true
/etc/init.d/network reload  || true
/etc/init.d/dnsmasq restart || true
/etc/init.d/firewall reload || true
/etc/init.d/sbproxy restart 2>/dev/null || true
/etc/init.d/sing-box restart 2>/dev/null || true
wifi reload || true

log "ROLLBACK XONG. Kiểm tra lại mạng."
log "Nếu vẫn hỏng nặng: dùng bản sysupgrade ($SRC/sysupgrade-backup.tar.gz) qua LuCI"
log "  System > Backup/Flash > Restore, hoặc: sysupgrade -r $SRC/sysupgrade-backup.tar.gz && reboot"
