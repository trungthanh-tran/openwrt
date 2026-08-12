# lib.sh — helpers + generators. Source bởi các script khác. POSIX sh (busybox ash).
# shellcheck shell=sh

# --- Resolve paths ----------------------------------------------------------
SB_ROOT="${SB_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"
CONF="${CONF:-$SB_ROOT/config/wifi-socks.conf}"
SETTINGS="${SETTINGS:-$SB_ROOT/config/settings.sh}"

# shellcheck source=/dev/null
[ -f "$SETTINGS" ] && . "$SETTINGS"

# --- Logging ----------------------------------------------------------------
log()  { printf '[sbproxy] %s\n' "$*" >&2; }
warn() { printf '[sbproxy][WARN] %s\n' "$*" >&2; }
die()  { printf '[sbproxy][ERR] %s\n' "$*" >&2; exit 1; }

# DRYRUN=1 -> chỉ in ra, không thực thi lệnh thay đổi hệ thống.
run() {
  if [ "${DRYRUN:-0}" = "1" ]; then printf 'DRYRUN> %s\n' "$*" >&2
  else eval "$@"; fi
}

require_root() { [ "$(id -u)" = "0" ] || die "Cần chạy bằng root."; }
require_conf() { [ -f "$CONF" ] || die "Thiếu config: $CONF (copy từ config/wifi-socks.conf.example)"; }

# --- Helpers dẫn xuất từ idx ------------------------------------------------
net_octet()    { echo $(( NET_BASE + $1 )); }         # 192.168.<octet>.0/24
tproxy_port()  { echo $(( TPROXY_PORT_BASE + $1 )); }
radio_of() { case "$1" in 2g) echo "$RADIO_2G";; 5g) echo "$RADIO_5G";; *) die "band không hợp lệ: $1";; esac; }

# MAC ngẫu nhiên hợp lệ: locally-administered + unicast (octet đầu = 02).
gen_mac() {
  printf '02:%02x:%02x:%02x:%02x:%02x\n' \
    $(head -c5 /dev/urandom | hexdump -v -e '/1 "%u "')
}

# Lặp qua từng dòng SSID hợp lệ, gọi: cb name band idx key host port user pass isolate webrtc
for_each_ssid() {
  _cb="$1"
  while IFS='|' read -r name band idx key host port user pass isolate webrtc; do
    case "$name" in ''|\#*) continue;; esac
    [ -n "$idx" ] || { warn "Bỏ dòng thiếu idx: $name"; continue; }
    "$_cb" "$name" "$band" "$idx" "$key" "$host" "$port" "$user" "$pass" "${isolate:-1}" "${webrtc:-0}"
  done < "$CONF"
}

# --- Kiểm tra trùng idx -----------------------------------------------------
check_unique_idx() {
  dup=$(awk -F'|' '!/^#/ && NF>=3 {gsub(/ /,"",$3); if($3!="") print $3}' "$CONF" \
        | sort | uniq -d)
  [ -z "$dup" ] || die "idx bị trùng trong config: $dup"
}

# --- Cảnh báo vượt giới hạn BSSID ------------------------------------------
check_bssid_limit() {
  c2=$(awk -F'|' '!/^#/ && $2 ~ /2g/ {n++} END{print n+0}' "$CONF")
  c5=$(awk -F'|' '!/^#/ && $2 ~ /5g/ {n++} END{print n+0}' "$CONF")
  log "Số SSID: 2.4G=$c2 , 5G=$c5 (giới hạn/băng = $BSSID_LIMIT)"
  [ "$c2" -le "$BSSID_LIMIT" ] || warn "2.4G ($c2) VƯỢT giới hạn BSSID ($BSSID_LIMIT) -> có thể lỗi/không phát đủ."
  [ "$c5" -le "$BSSID_LIMIT" ] || warn "5G ($c5) VƯỢT giới hạn BSSID ($BSSID_LIMIT) -> có thể lỗi/không phát đủ."
}

# ---------------------------------------------------------------------------
# Sinh lệnh UCI cho 1 SSID -> in ra stdout (dùng với `uci batch`).
# MAC: giữ nguyên nếu section đã có (ổn định qua các lần apply); sinh mới nếu chưa.
# ---------------------------------------------------------------------------
emit_uci_one() {
  name="$1"; band="$2"; idx="$3"; key="$4"; isolate="$9"
  radio="$(radio_of "$band")"
  octet="$(net_octet "$idx")"
  mac="$(uci -q get "wireless.w$idx.macaddr")"
  [ -n "$mac" ] || mac="$(gen_mac)"

  # network: bridge device + interface L3
  cat <<EOF
set network.brw$idx=device
set network.brw$idx.name=br-w$idx
set network.brw$idx.type=bridge
set network.w$idx=interface
set network.w$idx.proto=static
set network.w$idx.device=br-w$idx
set network.w$idx.ipaddr=192.168.$octet.1
set network.w$idx.netmask=255.255.255.0
set dhcp.w$idx=dhcp
set dhcp.w$idx.interface=w$idx
set dhcp.w$idx.start=100
set dhcp.w$idx.limit=100
set dhcp.w$idx.leasetime=12h
set firewall.z$idx=zone
set firewall.z$idx.name=z$idx
set firewall.z$idx.network=w$idx
set firewall.z$idx.input=$ZONE_INPUT
set firewall.z$idx.output=ACCEPT
set firewall.z$idx.forward=REJECT
set wireless.w$idx=wifi-iface
set wireless.w$idx.device=$radio
set wireless.w$idx.mode=ap
set wireless.w$idx.network=w$idx
set wireless.w$idx.ssid=$name
set wireless.w$idx.encryption=$WIFI_ENCRYPTION
set wireless.w$idx.key=$key
set wireless.w$idx.isolate=$isolate
set wireless.w$idx.macaddr=$mac
set wireless.w$idx.disabled=0
EOF

  # Chặn cổng admin router từ zone khách (khi input=ACCEPT).
  if [ "$ZONE_INPUT" = "ACCEPT" ]; then
    p=$(echo "$ADMIN_PORTS" | tr ' ' ' ')
    cat <<EOF
set firewall.z${idx}adm=rule
set firewall.z${idx}adm.name=block-admin-w$idx
set firewall.z${idx}adm.src=z$idx
set firewall.z${idx}adm.proto=tcp
set firewall.z${idx}adm.dest_port=$p
set firewall.z${idx}adm.target=REJECT
EOF
  fi
}

# ---------------------------------------------------------------------------
# Sinh /etc/sing-box/config.json
# ---------------------------------------------------------------------------
build_singbox() {
  inbounds=""; outbounds=""; rules=""; sep=""
  _sb_row() {
    name="$1"; idx="$3"; host="$5"; port="$6"; user="$7"; pass="$8"
    tp="$(tproxy_port "$idx")"
    inbounds="$inbounds$sep{\"type\":\"tproxy\",\"tag\":\"in-w$idx\",\"listen\":\"0.0.0.0\",\"listen_port\":$tp,\"sniff\":true}"
    if [ -n "$user" ]; then
      auth=",\"username\":\"$user\",\"password\":\"$pass\""
    else auth=""; fi
    outbounds="$outbounds$sep{\"type\":\"socks\",\"tag\":\"out-w$idx\",\"server\":\"$host\",\"server_port\":$port,\"version\":\"5\"$auth}"
    rules="$rules$sep{\"inbound\":[\"in-w$idx\"],\"outbound\":\"out-w$idx\"}"
    sep=","
  }
  for_each_ssid _sb_row

  mkdir -p "$(dirname "$SINGBOX_CONF")"
  cat > "$SINGBOX_CONF" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [ $inbounds ],
  "outbounds": [
    $outbounds${outbounds:+,}
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [ $rules ],
    "final": "direct"
  }
}
EOF
  log "Đã ghi $SINGBOX_CONF"
}

# ---------------------------------------------------------------------------
# Sinh /etc/sbproxy.nft (TPROXY theo iifname + chặn WebRTC theo zone)
# ---------------------------------------------------------------------------
build_nft() {
  # Danh sách IP sock để bypass (không proxy chính traffic tới sock server).
  sock_bypass=""
  webrtc_rules=""
  tproxy_rules=""
  _nft_row() {
    idx="$3"; host="$5"; webrtc="${10}"
    tp="$(tproxy_port "$idx")"
    # bypass sock host
    case "$host" in
      *[!0-9.]*) : ;;  # là hostname, bỏ qua bypass theo IP (sing-box tự resolve)
      *) sock_bypass="$sock_bypass    ip daddr $host return\n" ;;
    esac
    tproxy_rules="$tproxy_rules    iifname \"br-w$idx\" meta l4proto tcp tproxy ip to :$tp meta mark set $TPROXY_MARK accept\n"
    tproxy_rules="$tproxy_rules    iifname \"br-w$idx\" meta l4proto udp tproxy ip to :$tp meta mark set $TPROXY_MARK accept\n"
    if [ "$webrtc" = "1" ]; then
      webrtc_rules="$webrtc_rules    iifname \"br-w$idx\" tcp dport { $STUN_TCP_PORTS } drop\n"
      webrtc_rules="$webrtc_rules    iifname \"br-w$idx\" udp dport { $STUN_UDP_PORTS } drop\n"
    fi
  }
  for_each_ssid _nft_row

  {
    echo "# GENERATED bởi sbproxy build_nft — KHÔNG sửa tay (sẽ bị ghi đè)."
    echo "table inet sbproxy {"
    echo "  chain webrtc {"
    echo "    type filter hook forward priority filter; policy accept;"
    printf "%b" "$webrtc_rules"
    echo "  }"
    echo "  chain prerouting {"
    echo "    type filter hook prerouting priority mangle; policy accept;"
    echo "    # Không proxy traffic nội bộ / multicast"
    echo "    ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return"
    echo "    # Bypass các SOCKS server (đi thẳng ra WAN)"
    printf "%b" "$sock_bypass"
    echo "    # TPROXY theo từng WiFi -> cổng sing-box tương ứng"
    printf "%b" "$tproxy_rules"
    echo "  }"
    echo "}"
  } > "$NFT_FILE"
  log "Đã ghi $NFT_FILE"
}
