#!/bin/sh
# install-deps.sh — cài gói cần thiết + bật service.
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root

log "opkg update..."
run "opkg update"

PKGS="nftables kmod-nft-tproxy kmod-nft-core ip-full iw-full sing-box"
for p in $PKGS; do
  if opkg list-installed 2>/dev/null | grep -q "^$p "; then
    log "[đã có] $p"
  else
    log "Cài $p..."
    run "opkg install $p" || warn "Không cài được $p — kiểm tra feed/opkg. sing-box có thể phải tải binary aarch64 thủ công."
  fi
done

# Cài init script TPROXY của project
if [ -f "$SB_ROOT/etc/init.d/sbproxy" ]; then
  run "cp '$SB_ROOT/etc/init.d/sbproxy' /etc/init.d/sbproxy"
  run "chmod +x /etc/init.d/sbproxy"
  run "/etc/init.d/sbproxy enable"
  log "Đã cài /etc/init.d/sbproxy"
fi

# Bật sing-box autostart
[ -f /etc/init.d/sing-box ] && run "/etc/init.d/sing-box enable" || warn "Chưa thấy /etc/init.d/sing-box"

# Đăng ký file cần GIỮ khi sysupgrade/backup chuẩn OpenWrt (mặc định KHÔNG gồm các path này)
log "Đăng ký /etc/sysupgrade.conf (để backup/nâng cấp giữ được config sbproxy)..."
for p in /etc/sing-box/ /etc/sbproxy.nft /etc/init.d/sbproxy $SB_ROOT/config/; do
  grep -qxF "$p" /etc/sysupgrade.conf 2>/dev/null || echo "$p" >> /etc/sysupgrade.conf
done

log "Xong install-deps. Tiếp theo: scripts/apply.sh"
