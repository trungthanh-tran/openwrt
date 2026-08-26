#!/bin/sh
# install-deps.sh — install required packages and enable services.
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root

if command -v apk >/dev/null 2>&1; then
  PKG_MANAGER=apk
  pkg_update() { run "apk update"; }
  pkg_installed() { apk list -I "$1" 2>/dev/null | grep -q "^$1-"; }
  pkg_install() { run "apk add '$1'"; }
elif command -v opkg >/dev/null 2>&1; then
  PKG_MANAGER=opkg
  pkg_update() { run "opkg update"; }
  pkg_installed() { opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "; }
  pkg_install() { run "opkg install '$1'"; }
else
  die "Neither apk nor opkg was found."
fi
log "$PKG_MANAGER update..."
pkg_update

PKGS="nftables kmod-nft-tproxy kmod-nft-core kmod-nft-socket ip-full iw-full jq sing-box"
for p in $PKGS; do
  if pkg_installed "$p"; then
    log "[installed] $p"
  else
    log "Installing $p..."
    pkg_install "$p" || warn "Could not install $p — check the firmware package feed."
  fi
done

# Install the project's TPROXY init script.
if [ -f "$SB_ROOT/etc/init.d/sbproxy" ]; then
  run "cp '$SB_ROOT/etc/init.d/sbproxy' /etc/init.d/sbproxy"
  run "chmod +x /etc/init.d/sbproxy"
  run "/etc/init.d/sbproxy enable"
  log "Installed /etc/init.d/sbproxy"
fi

# Enable sing-box at boot.
[ -f /etc/init.d/sing-box ] && run "/etc/init.d/sing-box enable" || warn "/etc/init.d/sing-box was not found"

# Register project files that standard OpenWrt sysupgrade backups must preserve.
log "Registering files in /etc/sysupgrade.conf (to preserve sbproxy configuration during backup/upgrades)..."
for p in /etc/sing-box/ /etc/sbproxy.nft /etc/sbproxy.env /etc/sbproxy.managed /etc/init.d/sbproxy $SB_ROOT/config/; do
  grep -qxF "$p" /etc/sysupgrade.conf 2>/dev/null || echo "$p" >> /etc/sysupgrade.conf
done

log "install-deps complete. Next: scripts/apply.sh"
