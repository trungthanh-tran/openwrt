#!/bin/sh
# backup.sh — snapshot cấu hình để rollback. Tạo 2 lớp:
#   1) tar toàn bộ /etc/config + /etc/sing-box + /etc/sbproxy.nft + wifi-socks.conf
#   2) sysupgrade -b (backup chuẩn OpenWrt) để phục hồi nhanh bằng công cụ hãng
#
# Dùng: scripts/backup.sh [nhãn]
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root

LABEL="${1:-manual}"
# Không dùng ngày giờ ngẫu nhiên khó đọc — dùng timestamp epoch cho ổn định/sort được.
TS="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_DIR/$TS-$LABEL"
mkdir -p "$DEST"

log "Backup -> $DEST"

# Lớp 1: tar các file cấu hình liên quan
tar czf "$DEST/etc-config.tar.gz" \
  -C / etc/config etc/sing-box 2>/dev/null || warn "Một số path chưa tồn tại (bình thường ở lần đầu)."
[ -f "$NFT_FILE" ] && cp "$NFT_FILE" "$DEST/sbproxy.nft" 2>/dev/null || true
[ -f "$CONF" ] && cp "$CONF" "$DEST/wifi-socks.conf" 2>/dev/null || true

# Lớp 2: sysupgrade backup chuẩn
if command -v sysupgrade >/dev/null 2>&1; then
  sysupgrade -b "$DEST/sysupgrade-backup.tar.gz" 2>/dev/null || warn "sysupgrade -b lỗi (bỏ qua)."
fi

# Cập nhật con trỏ 'latest'
ln -sfn "$DEST" "$BACKUP_DIR/latest"

# Dọn: giữ 20 bản gần nhất
ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null | grep -v "^$BACKUP_DIR/latest/$" | tail -n +21 | while read -r old; do rm -rf "$old"; done

log "Backup xong: $DEST"
log "Danh sách: scripts/rollback.sh --list"
