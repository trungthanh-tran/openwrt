#!/bin/sh
# install-cloud-agent.sh — cài cloud-agent lên router (poll cloud server).
# Tiền đề: đã cài project sbproxy (scripts/*) + agent health (/tmp/sbproxy-health.json),
#          và đã tạo /etc/sbproxy/cloud.env chứa CLOUD_URL + DEVICE_KEY.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
log() { printf '[cloud-agent] %s\n' "$*"; }
[ "$(id -u)" = "0" ] || { echo "Cần root."; exit 1; }

[ -f /etc/sbproxy/cloud.env ] || { echo "Thiếu /etc/sbproxy/cloud.env (CLOUD_URL + DEVICE_KEY). Xem hướng dẫn 'Thêm router' trên web."; exit 1; }

if command -v apk >/dev/null 2>&1; then
  pkg_update() { apk update >/dev/null 2>&1 || true; }; pkg_has() { apk list -I "$1" 2>/dev/null | grep -q "^$1-"; }; pkg_add() { apk add "$1"; }
else
  pkg_update() { opkg update >/dev/null 2>&1 || true; }; pkg_has() { opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "; }; pkg_add() { opkg install "$1"; }
fi
pkg_update
for p in curl jq; do pkg_has "$p" || { log "cài $p"; pkg_add "$p" || true; }; done

log "cài /usr/sbin/sbproxy-cloud-agent"
cp "$HERE/sbproxy-cloud-agent" /usr/sbin/sbproxy-cloud-agent
chmod +x /usr/sbin/sbproxy-cloud-agent

log "cài /etc/init.d/sbproxy-cloud + enable"
cp "$HERE/init.d/sbproxy-cloud" /etc/init.d/sbproxy-cloud
chmod +x /etc/init.d/sbproxy-cloud
/etc/init.d/sbproxy-cloud enable
/etc/init.d/sbproxy-cloud restart

# giữ khi sysupgrade/backup
for x in /etc/sbproxy/cloud.env /usr/sbin/sbproxy-cloud-agent /etc/init.d/sbproxy-cloud; do
  grep -qxF "$x" /etc/sysupgrade.conf 2>/dev/null || echo "$x" >> /etc/sysupgrade.conf
done

log "XONG. Kiểm tra kết nối:"
log "  logread -e sbproxy-cloud | tail"
log "  (trên web) router sẽ chuyển 'online' sau ~10s."
