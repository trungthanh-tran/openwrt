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
# The console stores the uplink choice here, and this file is rewritten whole,
# so carry an existing choice across a reinstall. Anything that is not a plain
# interface name is dropped rather than written back into a sourced file.
KEEP_UPLINK=""
if [ -f /etc/sbproxy/env ]; then
  KEEP_UPLINK="$(sed -n 's/^[[:space:]]*GATEWAY_EXPECTED_INTERFACE=\(.*\)$/\1/p' \
    /etc/sbproxy/env | tail -n 1)"
  case "$KEEP_UPLINK" in
    *[!A-Za-z0-9_.-]*) KEEP_UPLINK="" ;;
  esac
fi
cat > /etc/sbproxy/env <<EOF
SB_ROOT=$SB_ROOT
CONF=$SB_ROOT/config/wifi-socks.conf
HEALTH_FILE=/tmp/sbproxy-health.json
BACKUP_DIR=/root/sbproxy-backups
PROBE_URL=https://www.gstatic.com/generate_204
INTERVAL=15
SLOW_MS=800
# Which interface the gateway check treats as the uplink. Empty means
# automatic: whatever the default route uses is accepted, and only an egress
# through a proxied SSID bridge is reported as wrong. The console writes this
# when someone picks an interface; there is no built-in default name.
GATEWAY_EXPECTED_INTERFACE=$KEEP_UPLINK
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

log "3b) Web console account -> /etc/sbproxy/webauth"
cp "$AGENT/sbproxy-webauth" /usr/sbin/sbproxy-webauth
chmod 755 /usr/sbin/sbproxy-webauth
# A dedicated username/password for the web UI, separate from the router's
# root account, kept across reinstalls. By default NO account is created here:
# the first visit to the web UI asks the operator to create it (the CGI's
# setup_account only works while no account exists). Non-interactive
# provisioning can still pre-create one through SBPROXY_WEB_USER /
# SBPROXY_WEB_PASS; change it later with: sbproxy-webauth set <user>
WEB_USER=""
WEB_PASS_SHOWN=""
if [ -s /etc/sbproxy/webauth ]; then
  WEB_USER="$(/usr/sbin/sbproxy-webauth show 2>/dev/null || echo "?")"
elif [ -n "${SBPROXY_WEB_USER:-}" ] || [ -n "${SBPROXY_WEB_PASS:-}" ]; then
  WEB_USER="${SBPROXY_WEB_USER:-admin}"
  WEB_PASS="${SBPROXY_WEB_PASS:-$(head -c 9 /dev/urandom | hexdump -v -e '/1 "%02x"')}"
  printf '%s\n' "$WEB_PASS" | /usr/sbin/sbproxy-webauth set "$WEB_USER" -
  WEB_PASS_SHOWN="$WEB_PASS"
fi

log "4) CGI -> /www/cgi-bin/sbproxy"
mkdir -p /www/cgi-bin
cp "$AGENT/cgi/sbproxy" /www/cgi-bin/sbproxy
chmod 755 /www/cgi-bin/sbproxy

log "5) UI self-host -> /www/sbproxy/ (index.html + offline Bootstrap assets)"
mkdir -p /www/sbproxy/assets
cp "$SB_ROOT/console/web/control-panel.html" /www/sbproxy/index.html
cp "$SB_ROOT/console/web/assets/"* /www/sbproxy/assets/ 2>/dev/null \
  || echo "  warning: console/web/assets/ was not found — the UI falls back to its built-in styling"

log "6) Health daemon -> /usr/sbin/ + procd"
mkdir -p /usr/libexec
cp "$AGENT/sbproxy-dhcp-assign" /usr/libexec/sbproxy-dhcp-assign
chmod 755 /usr/libexec/sbproxy-dhcp-assign
cp "$AGENT/sbproxy-healthd" /usr/sbin/sbproxy-healthd
chmod 755 /usr/sbin/sbproxy-healthd
cp "$AGENT/init.d/sbproxy-healthd" /etc/init.d/sbproxy-healthd
chmod 755 /etc/init.d/sbproxy-healthd
/etc/init.d/sbproxy-healthd enable
/etc/init.d/sbproxy-healthd restart

cp "$AGENT/sbproxy-assignd" /usr/sbin/sbproxy-assignd
chmod 755 /usr/sbin/sbproxy-assignd
cp "$AGENT/init.d/sbproxy-assignd" /etc/init.d/sbproxy-assignd
chmod 755 /etc/init.d/sbproxy-assignd
/etc/init.d/sbproxy-assignd enable
/etc/init.d/sbproxy-assignd restart

# Preserve agent files across standard OpenWrt backups and upgrades.
for p in /etc/sbproxy/ /www/cgi-bin/sbproxy /www/sbproxy/ /usr/sbin/sbproxy-healthd /etc/init.d/sbproxy-healthd \
         /usr/sbin/sbproxy-assignd /etc/init.d/sbproxy-assignd /usr/libexec/sbproxy-dhcp-assign \
         /usr/sbin/sbproxy-webauth; do
  grep -qxF "$p" /etc/sysupgrade.conf 2>/dev/null || echo "$p" >> /etc/sysupgrade.conf
done

# uhttpd normally enables /cgi-bin already; reload to ensure the CGI is visible.
/etc/init.d/uhttpd reload 2>/dev/null || true

IP="$(uci -q get network.lan.ipaddr || echo 192.168.8.1)"
if [ -n "$WEB_USER" ]; then
  WEB_LOGIN_1="user: $WEB_USER"
  WEB_LOGIN_2="pass: ${WEB_PASS_SHOWN:-(unchanged — reset with: sbproxy-webauth set $WEB_USER)}"
else
  WEB_LOGIN_1="no account yet — the FIRST visit to the UI asks you to create it"
  WEB_LOGIN_2="(or create one now: sbproxy-webauth set admin)"
fi
cat <<EOF

============================================================
 AGENT INSTALLATION COMPLETE.
 UI (open FROM THE ROUTER using http to avoid mixed content):
     http://$IP/sbproxy/
 WEB LOGIN (username/password dedicated to sbproxy):
     $WEB_LOGIN_1
     $WEB_LOGIN_2
 API:
     http://$IP/cgi-bin/sbproxy?action=status
 TOKEN (used by the desktop app; the web UI gets it by logging in):
     $TOKEN
------------------------------------------------------------
 SECURITY:
  - Only expose this on the management LAN/VLAN. DO NOT expose it to the WAN.
  - Keep the token secret. To rotate it, delete /etc/sbproxy/token and run this script again.
  - Change the web password in the UI (Đổi mật khẩu) or with: sbproxy-webauth set <user>
    Disable password login entirely with:  sbproxy-webauth disable
  - Test: curl -H "Authorization: Bearer \$TOKEN" http://$IP/cgi-bin/sbproxy?action=status
============================================================
EOF
