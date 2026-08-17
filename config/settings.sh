# settings.sh — tunables cho toàn bộ project. Source bởi lib.sh.
# Sửa file này cho khớp phần cứng của bạn TRƯỚC khi chạy apply.sh.

# --- Ánh xạ radio ↔ băng tần ------------------------------------------------
# CẢNH BÁO: OpenWrt KHÔNG đảm bảo radio0=2.4G. Kiểm tra bằng: scripts/preflight.sh
# rồi sửa lại 2 dòng dưới cho đúng.
RADIO_2G="radio0"
RADIO_5G="radio1"
# Bắt buộc đổi thành mã quốc gia ISO 3166-1 alpha-2 nơi router hoạt động.
# Để trống sẽ làm preflight/apply dừng nhằm tránh phát WiFi sai quy định.
WIFI_COUNTRY=""

# --- Giới hạn phần cứng -----------------------------------------------------
# Số BSSID tối đa mỗi radio (verify bằng `iw list` -> "valid interface combinations").
BSSID_LIMIT=16

# --- Mạng -------------------------------------------------------------------
# Subnet octet thứ 3 = NET_BASE + idx  (idx bắt đầu từ 1). vd NET_BASE=10, idx=1 -> 192.168.11.0/24
NET_BASE=10
# Cổng TPROXY của sing-box = TPROXY_PORT_BASE + idx
TPROXY_PORT_BASE=12000
# fwmark + bảng định tuyến cho TPROXY (phải khớp etc/init.d/sbproxy)
TPROXY_MARK=1
TPROXY_TABLE=100
TPROXY_RULE_PRIORITY=10000
TPROXY_MARK_MASK=255

# v0.2 chỉ proxy IPv4. "disable" tắt RA/DHCPv6 trên các SSID sbproxy để tránh
# IPv6 đi thẳng ra WAN; chưa hỗ trợ giá trị khác.
IPV6_MODE="disable"

# --- Firewall ---------------------------------------------------------------
# Chính sách input cho zone khách. ACCEPT = client chắc chắn lấy được DHCP/DNS và
# TPROXY hoạt động ổn (đã chặn cổng admin bằng rule riêng). Đổi sang REJECT nếu bạn
# tự thêm rule cho phép 53/67 và đã test TPROXY chạy.
ZONE_INPUT="ACCEPT"
# Cổng quản trị router sẽ bị chặn truy cập từ zone khách.
ADMIN_PORTS="22 80 443"

# --- WiFi mặc định ----------------------------------------------------------
WIFI_ENCRYPTION="psk2"     # WPA2-PSK. Dùng "sae" cho WPA3, "sae-mixed" cho hỗn hợp.

# --- Đường dẫn --------------------------------------------------------------
SINGBOX_CONF="/etc/sing-box/config.json"
NFT_FILE="/etc/sbproxy.nft"
BACKUP_DIR="/root/sbproxy-backups"

# --- STUN/TURN chặn WebRTC (cổng) -------------------------------------------
STUN_TCP_PORTS="3478, 3479, 5349, 5350"
STUN_UDP_PORTS="3478, 3479, 5349, 5350, 19302-19309"
