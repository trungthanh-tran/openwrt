#!/bin/sh
# install-agent.sh — cài agent kiến trúc B (CGI trên uhttpd + health daemon + UI self-host).
# Chạy trên router SAU khi project đã ở /root/sbproxy và apply.sh chạy được.
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$SB_ROOT/agent"

log() { printf '[agent] %s\n' "$*"; }
[ "$(id -u)" = "0" ] || { echo "Cần root."; exit 1; }

log "1) Cài gói: curl jq (uhttpd thường đã có)"
opkg update >/dev/null 2>&1 || true
for p in curl jq; do
  opkg list-installed 2>/dev/null | grep -q "^$p " || opkg install "$p" || echo "  cảnh báo: chưa cài được $p"
done
[ -f /etc/init.d/uhttpd ] || echo "  cảnh báo: chưa thấy uhttpd — cài: opkg install uhttpd"

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
EOF

log "3) Token xác thực -> /etc/sbproxy/token"
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
cp "$SB_ROOT/ui/control-panel.html" /www/sbproxy/index.html

log "6) Health daemon -> /usr/sbin/ + procd"
cp "$AGENT/sbproxy-healthd" /usr/sbin/sbproxy-healthd
chmod +x /usr/sbin/sbproxy-healthd
cp "$AGENT/init.d/sbproxy-healthd" /etc/init.d/sbproxy-healthd
chmod +x /etc/init.d/sbproxy-healthd
/etc/init.d/sbproxy-healthd enable
/etc/init.d/sbproxy-healthd restart

# Đăng ký file agent vào /etc/sysupgrade.conf (giữ khi backup/nâng cấp)
for p in /etc/sbproxy/ /www/cgi-bin/sbproxy /www/sbproxy/ /usr/sbin/sbproxy-healthd /etc/init.d/sbproxy-healthd; do
  grep -qxF "$p" /etc/sysupgrade.conf 2>/dev/null || echo "$p" >> /etc/sysupgrade.conf
done

# uhttpd CGI mặc định đã bật cgi_prefix=/cgi-bin; chỉ reload cho chắc
/etc/init.d/uhttpd reload 2>/dev/null || true

IP="$(uci -q get network.lan.ipaddr || echo 192.168.1.1)"
cat <<EOF

============================================================
 AGENT ĐÃ CÀI XONG.
 UI (mở TỪ ROUTER, http để tránh mixed-content):
     http://$IP/sbproxy/
 API:
     http://$IP/cgi-bin/sbproxy?action=status
 TOKEN (dán vào ô "Kết nối router" trên UI):
     $TOKEN
------------------------------------------------------------
 BẢO MẬT:
  - Chỉ mở trên LAN/VLAN quản trị. KHÔNG expose ra WAN.
  - Giữ token bí mật. Đổi token: xoá /etc/sbproxy/token rồi chạy lại.
  - Kiểm tra: curl -H "X-SB-Token: \$TOKEN" http://$IP/cgi-bin/sbproxy?action=status
============================================================
EOF
