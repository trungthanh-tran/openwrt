#!/bin/sh
# install-agent.sh — install the uhttpd CGI, health daemon, and self-hosted UI.
# Run on the router after the project and apply.sh are working.
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$SB_ROOT/agent"

log() { printf '[agent] %s\n' "$*"; }
[ "$(id -u)" = "0" ] || { echo "Root privileges are required."; exit 1; }

log "1) Installing packages: curl jq (uhttpd is usually preinstalled)"
if command -v apk >/dev/null 2>&1; then
  pkg_update() { apk update >/dev/null 2>&1 || true; }; pkg_has() { apk list -I "$1" 2>/dev/null | grep -q "^$1-"; }; pkg_add() { apk add "$1"; }
else
  pkg_update() { opkg update >/dev/null 2>&1 || true; }; pkg_has() { opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "; }; pkg_add() { opkg install "$1"; }
fi
pkg_update
for p in curl jq; do
  pkg_has "$p" || pkg_add "$p" || echo "  warning: could not install $p"
done
[ -f /etc/init.d/uhttpd ] || echo "  warning: uhttpd was not found — install the uhttpd package"

log "2) env agent -> /etc/sbproxy/env"
mkdir -p /etc/sbproxy
cat > /etc/sbproxy/env <<EOF
SB_ROOT=$SB_ROOT
CONF=$SB_ROOT/config/wifi-socks.conf
HEALTH_FILE=/tmp/sbproxy-health.json
BACKUP_DIR=/root/sbproxy-backups
PROBE_URL=https://www.gstatic.com/generate_204
INTERVAL=15
SLOW_MS=800
# Leave unset: any uplink the default route picks is accepted, and only an
# egress through a proxied SSID bridge is reported as wrong. Set it to a
# logical interface name (wan, wwan, ...) to enforce one specific uplink.
#GATEWAY_EXPECTED_INTERFACE=
GATEWAY_PROBE_URL=https://www.gstatic.com/generate_204
GATEWAY_PROBE_TIMEOUT=8
EOF

log "3) Authentication token -> /etc/sbproxy/token"
if [ ! -s /etc/sbproxy/token ]; then
  head -c 18 /dev/urandom | hexdump -v -e '/1 "%02x"' > /etc/sbproxy/token
  echo >> /etc/sbproxy/token
fi
chmod 600 /etc/sbproxy/token
TOKEN="$(cat /etc/sbproxy/token)"

log "4) CGI -> /www/cgi-bin/sbproxy"
mkdir -p /www/cgi-bin
cp "$AGENT/cgi/sbproxy" /www/cgi-bin/sbproxy
chmod +x /www/cgi-bin/sbproxy

log "5) UI self-host -> /www/sbproxy/index.html"
mkdir -p /www/sbproxy
cp "$SB_ROOT/console/web/control-panel.html" /www/sbproxy/index.html

log "6) Health daemon -> /usr/sbin/ + procd"
cp "$AGENT/sbproxy-healthd" /usr/sbin/sbproxy-healthd
chmod +x /usr/sbin/sbproxy-healthd
cp "$AGENT/init.d/sbproxy-healthd" /etc/init.d/sbproxy-healthd
chmod +x /etc/init.d/sbproxy-healthd
/etc/init.d/sbproxy-healthd enable
/etc/init.d/sbproxy-healthd restart

# Preserve agent files across standard OpenWrt backups and upgrades.
for p in /etc/sbproxy/ /www/cgi-bin/sbproxy /www/sbproxy/ /usr/sbin/sbproxy-healthd /etc/init.d/sbproxy-healthd; do
  grep -qxF "$p" /etc/sysupgrade.conf 2>/dev/null || echo "$p" >> /etc/sysupgrade.conf
done

# uhttpd normally enables /cgi-bin already; reload to ensure the CGI is visible.
/etc/init.d/uhttpd reload 2>/dev/null || true

IP="$(uci -q get network.lan.ipaddr || echo 192.168.8.1)"
cat <<EOF

============================================================
 AGENT INSTALLATION COMPLETE.
 UI (open FROM THE ROUTER using http to avoid mixed content):
     http://$IP/sbproxy/
 API:
     http://$IP/cgi-bin/sbproxy?action=status
 TOKEN (paste into the "Connect router" field in the UI):
     $TOKEN
------------------------------------------------------------
 SECURITY:
  - Only expose this on the management LAN/VLAN. DO NOT expose it to the WAN.
  - Keep the token secret. To rotate it, delete /etc/sbproxy/token and run this script again.
  - Test: curl -H "Authorization: Bearer \$TOKEN" http://$IP/cgi-bin/sbproxy?action=status
============================================================
EOF
