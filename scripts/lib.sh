# lib.sh — shared helpers and generators. POSIX sh for BusyBox ash.
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

# DRYRUN=1 prints mutating commands instead of executing them.
run() {
  if [ "${DRYRUN:-0}" = "1" ]; then printf 'DRYRUN> %s\n' "$*" >&2
  else eval "$@"; fi
}

require_root() { [ "$(id -u)" = "0" ] || die "Cần chạy bằng root."; }
require_conf() { [ -f "$CONF" ] || die "Thiếu config: $CONF (copy từ config/wifi-socks.conf.example)"; }

validate_platform() {
  board="$(ubus call system board 2>/dev/null | jsonfilter -e '@.board_name' 2>/dev/null || true)"
  model="$(cat /proc/device-tree/model 2>/dev/null | tr -d '\000' || true)"
  case "$board:$model" in
    glinet,gl-mt6000:*|*:*GL-MT6000*) : ;;
    *) die "Thiết bị chưa được hỗ trợ: board=${board:-?}, model=${model:-?} (cần GL-MT6000)." ;;
  esac
  [ -z "$(cat /etc/glversion 2>/dev/null)" ] || warn "Đang chạy firmware GL.iNet OEM; hỗ trợ experimental, cần test riêng."
}

validate_settings() {
  case "${WIFI_COUNTRY:-}" in
    [A-Z][A-Z]) : ;;
    *) die "WIFI_COUNTRY phải là mã quốc gia 2 chữ in hoa trong config/settings.sh (ví dụ VN)." ;;
  esac
  [ "${IPV6_MODE:-disable}" = "disable" ] || die "v0.2 chỉ hỗ trợ IPV6_MODE=disable."
}

validate_conf() {
  awk -F'|' -v net_base="${NET_BASE:-10}" -v port_base="${TPROXY_PORT_BASE:-12000}" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^#/ || /^[[:space:]]*$/ { next }
    NF != 10 && NF != 11 { printf "dòng %d: cần 10 hoặc 11 cột, hiện có %d\n", NR, NF; bad=1; next }
    {
      idx=trim($3); port=trim($6); band=trim($2); iso=trim($9); web=trim($10)
      oui=(NF==11)?trim($11):""
      if (oui != "" && oui !~ /^[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]$/) { printf "dòng %d: mac_oui phải dạng AA:BB:CC hoặc để trống\n", NR; bad=1 }
      if (idx !~ /^[1-9][0-9]*$/ || idx > 200) { printf "dòng %d: idx không hợp lệ\n", NR; bad=1 }
      if (idx ~ /^[1-9][0-9]*$/ && (net_base + idx > 254 || port_base + idx > 65535)) { printf "dòng %d: idx làm subnet/cổng vượt phạm vi\n", NR; bad=1 }
      if (port !~ /^[0-9]+$/ || port < 1 || port > 65535) { printf "dòng %d: port không hợp lệ\n", NR; bad=1 }
      if (band != "2g" && band != "5g") { printf "dòng %d: band phải là 2g hoặc 5g\n", NR; bad=1 }
      if (iso !~ /^[01]$/ || web !~ /^[01]$/) { printf "dòng %d: isolate/webrtc phải là 0 hoặc 1\n", NR; bad=1 }
      if (length($1) < 1 || length($1) > 32) { printf "dòng %d: SSID phải dài 1..32 byte/ký tự ASCII\n", NR; bad=1 }
      if (length($4) < 8 || length($4) > 63) { printf "dòng %d: mật khẩu WiFi phải dài 8..63 ký tự\n", NR; bad=1 }
      if (trim($5) == "") { printf "dòng %d: sock_host bị trống\n", NR; bad=1 }
      if ($1 ~ /[|\r\n]/ || $4 ~ /[|\r\n]/ || $5 ~ /[|\r\n]/ || $7 ~ /[|\r\n]/ || $8 ~ /[|\r\n]/) { printf "dòng %d: field chứa ký tự cấm\n", NR; bad=1 }
      seen[idx]++; if (seen[idx] > 1) { printf "dòng %d: idx %s bị trùng\n", NR, idx; bad=1 }
    }
    END { exit bad ? 1 : 0 }
  ' "$CONF" || die "wifi-socks.conf không hợp lệ."
}

# --- Values derived from the Wi-Fi index -----------------------------------
net_octet()    { echo $(( NET_BASE + $1 )); }         # 192.168.<octet>.0/24
tproxy_port()  { echo $(( TPROXY_PORT_BASE + $1 )); }
radio_of() { case "$1" in 2g) echo "$RADIO_2G";; 5g) echo "$RADIO_5G";; *) die "band không hợp lệ: $1";; esac; }

# Generate a random MAC.
#   gen_mac              -> locally administered, unicast, first octet 02.
#   gen_mac aa:bb:cc     -> given vendor OUI + 3 random octets (impersonates a
#                           common Wi-Fi vendor; OUI first octet is already
#                           globally-unique/unicast).
gen_mac() {
  oui="$(printf '%s' "${1:-}" | tr -d ' \r' | tr 'A-Z' 'a-z')"
  if [ -n "$oui" ]; then
    printf '%s:%02x:%02x:%02x\n' "$oui" \
      $(head -c3 /dev/urandom | hexdump -v -e '/1 "%u "')
  else
    printf '02:%02x:%02x:%02x:%02x:%02x\n' \
      $(head -c5 /dev/urandom | hexdump -v -e '/1 "%u "')
  fi
}

uci_dquote() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Iterate over valid SSID rows and call:
#   cb name band idx key host port user pass isolate webrtc mac_oui
# mac_oui (column 11) is optional; older 10-column configs pass it empty.
for_each_ssid() {
  _cb="$1"
  while IFS='|' read -r name band idx key host port user pass isolate webrtc mac_oui; do
    case "$name" in ''|\#*) continue;; esac
    [ -n "$idx" ] || { warn "Bỏ dòng thiếu idx: $name"; continue; }
    "$_cb" "$name" "$band" "$idx" "$key" "$host" "$port" "$user" "$pass" "${isolate:-1}" "${webrtc:-0}" "$mac_oui"
  done < "$CONF"
}

# --- Duplicate index validation --------------------------------------------
check_unique_idx() {
  dup=$(awk -F'|' '!/^#/ && NF>=3 {gsub(/ /,"",$3); if($3!="") print $3}' "$CONF" \
        | sort | uniq -d)
  [ -z "$dup" ] || die "idx bị trùng trong config: $dup"
}

# --- BSSID limit warning ----------------------------------------------------
check_bssid_limit() {
  c2=$(awk -F'|' '!/^#/ && $2 ~ /2g/ {n++} END{print n+0}' "$CONF")
  c5=$(awk -F'|' '!/^#/ && $2 ~ /5g/ {n++} END{print n+0}' "$CONF")
  log "Số SSID: 2.4G=$c2 , 5G=$c5 (giới hạn/băng = $BSSID_LIMIT)"
  [ "$c2" -le "$BSSID_LIMIT" ] || warn "2.4G ($c2) VƯỢT giới hạn BSSID ($BSSID_LIMIT) -> có thể lỗi/không phát đủ."
  [ "$c5" -le "$BSSID_LIMIT" ] || warn "5G ($c5) VƯỢT giới hạn BSSID ($BSSID_LIMIT) -> có thể lỗi/không phát đủ."
}

# ---------------------------------------------------------------------------
# Emit UCI commands for one SSID to stdout for `uci batch`.
# Keep an existing MAC stable across applies; generate one only when absent.
# ---------------------------------------------------------------------------
emit_uci_one() {
  name="$1"; band="$2"; idx="$3"; key="$4"; isolate="$9"
  mac_oui="$(printf '%s' "${11}" | tr -d ' \r' | tr 'A-Z' 'a-z')"
  name_q="$(uci_dquote "$name")"; key_q="$(uci_dquote "$key")"
  radio="$(radio_of "$band")"
  octet="$(net_octet "$idx")"
  mac="$(uci -q get "wireless.w$idx.macaddr" 2>/dev/null || true)"
  # Keep an existing MAC stable, but regenerate when absent or when a vendor
  # OUI is requested and the current MAC does not already start with it, so
  # changing the vendor dropdown actually takes effect on the next apply.
  if [ -z "$mac" ]; then
    mac="$(gen_mac "$mac_oui")"
  elif [ -n "$mac_oui" ]; then
    case "$(printf '%s' "$mac" | tr 'A-Z' 'a-z')" in
      "$mac_oui":*) : ;;
      *) mac="$(gen_mac "$mac_oui")" ;;
    esac
  fi

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
set dhcp.w$idx.dhcpv6=disabled
set dhcp.w$idx.ra=disabled
set dhcp.w$idx.ndp=disabled
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
set wireless.w$idx.ssid="$name_q"
set wireless.w$idx.encryption=$WIFI_ENCRYPTION
set wireless.w$idx.key="$key_q"
set wireless.w$idx.isolate=$isolate
set wireless.w$idx.macaddr=$mac
set wireless.w$idx.disabled=0
EOF

  # Block router administration ports from a guest zone when input is ACCEPT.
  if [ "$ZONE_INPUT" = "ACCEPT" ]; then
    p=$(echo "$ADMIN_PORTS" | tr ' ' ' ')
    cat <<EOF
set firewall.z${idx}adm=rule
set firewall.z${idx}adm.name=block-admin-w$idx
set firewall.z${idx}adm.src=z$idx
set firewall.z${idx}adm.proto=tcp
set firewall.z${idx}adm.target=REJECT
EOF
    for p in $ADMIN_PORTS; do
      echo "add_list firewall.z${idx}adm.dest_port=$p"
    done
  fi
}

# ---------------------------------------------------------------------------
# The generated config uses modern (1.12+) syntax. SINGBOX_COMPAT_ENV is an
# escape hatch for future ENABLE_DEPRECATED_* flags; empty means none needed.
# ---------------------------------------------------------------------------
singbox_check() {
  # shellcheck disable=SC2086  # word-splitting of the flag list is intended
  env ${SINGBOX_COMPAT_ENV:-} sing-box check -c "$1"
}

# The modern DNS config (fakeip server type, rule actions) needs sing-box 1.12+.
require_singbox_version() {
  v="$(sing-box version 2>/dev/null | head -1 | sed 's/.*version \([0-9][0-9.]*\).*/\1/')"
  [ -n "$v" ] || { warn "Không đọc được version sing-box; tiếp tục."; return 0; }
  maj="${v%%.*}"; rest="${v#*.}"; min="${rest%%.*}"
  if [ "$maj" -lt 1 ] || { [ "$maj" -eq 1 ] && [ "$min" -lt 12 ]; }; then
    die "Cần sing-box >= 1.12 (đang có $v): config dùng cú pháp DNS mới."
  fi
}

# The packaged procd init script has no env hook, so inject a
# `procd_set_param env` line after its command line. Idempotent; re-run after
# every apply because package upgrades rewrite the file. When the flag list is
# empty, remove any line injected by an older version instead.
ensure_singbox_compat_env() {
  initf="/etc/init.d/sing-box"
  if [ -z "${SINGBOX_COMPAT_ENV:-}" ]; then
    [ -f "$initf" ] && [ "${DRYRUN:-0}" != "1" ] && sed -i '/procd_set_param env ENABLE_DEPRECATED/d' "$initf"
    return 0
  fi
  [ -f "$initf" ] || { warn "Không thấy $initf; bỏ qua compat env cho service."; return 0; }
  if [ "${DRYRUN:-0}" = "1" ]; then
    printf 'DRYRUN> chèn "procd_set_param env %s" vào %s\n' "$SINGBOX_COMPAT_ENV" "$initf" >&2
    return 0
  fi
  grep -q 'procd_set_param command' "$initf" || { warn "$initf không dùng procd; tự thêm env $SINGBOX_COMPAT_ENV thủ công."; return 0; }
  sed -i '/procd_set_param env ENABLE_DEPRECATED/d' "$initf"
  sed -i "/procd_set_param command/a\\	procd_set_param env $SINGBOX_COMPAT_ENV" "$initf"
  log "Đã chèn compat env vào $initf"
}

# ---------------------------------------------------------------------------
# Sinh /etc/sing-box/config.json
# ---------------------------------------------------------------------------
build_singbox() {
  # Defaults keep older settings.sh copies (without these vars) working.
  FAKEIP_RANGE="${FAKEIP_RANGE:-198.18.0.0/15}"
  # Persist the fakeip<->hostname map across sing-box restarts (e.g. set-sock.sh)
  # so clients holding cached fake-IPs keep working without a fresh DNS query.
  SINGBOX_CACHE="${SINGBOX_CACHE:-/etc/sing-box/cache.db}"
  inbounds=""; outbounds=""; rules=""; sep=""
  _sb_row() {
    name="$1"; idx="$3"; host="$5"; port="$6"; user="$7"; pass="$8"
    tp="$(tproxy_port "$idx")"
    inbounds="$inbounds$sep{\"type\":\"tproxy\",\"tag\":\"in-w$idx\",\"listen\":\"0.0.0.0\",\"listen_port\":$tp}"
    host_json="$(jq -Rn --arg v "$host" '$v')"
    if [ -n "$user" ]; then
      user_json="$(jq -Rn --arg v "$user" '$v')"; pass_json="$(jq -Rn --arg v "$pass" '$v')"
      auth=",\"username\":$user_json,\"password\":$pass_json"
    else auth=""; fi
    outbounds="$outbounds$sep{\"type\":\"socks\",\"tag\":\"out-w$idx\",\"server\":$host_json,\"server_port\":$port,\"version\":\"5\"$auth}"
    rules="$rules$sep{\"inbound\":[\"in-w$idx\"],\"action\":\"sniff\",\"timeout\":\"1s\"}"
    sep=","
    rules="$rules$sep{\"inbound\":[\"in-w$idx\"],\"outbound\":\"out-w$idx\"}"
    sep=","
  }
  for_each_ssid _sb_row

  mkdir -p "$(dirname "$SINGBOX_CONF")"
  # DNS fake-IP: trả fake-IP cho client, map ngược về hostname khi kết nối,
  # nhờ đó outbound SOCKS luôn nhận hostname (remote resolve) thay vì IP thật.
  # - Chặn HTTPS/SVCB (type 65/64): hint IP thật trong đó cho phép trình duyệt
  #   né fake-IP và kết nối bằng IP thô -> SOCKS từ chối.
  # - Không cấp inet6_range: mạng SSID là IPv4-only, AAAA trả rỗng (NOERROR)
  #   để client không thử kết nối IPv6 giả không route được.
  cat > "$SINGBOX_CONF" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      { "type": "fakeip", "tag": "fakeip", "inet4_range": "$FAKEIP_RANGE" },
      { "type": "udp", "tag": "upstream", "server": "1.1.1.1" }
    ],
    "rules": [
      { "query_type": ["HTTPS", "SVCB"], "action": "predefined", "rcode": "NOTIMP" },
      { "query_type": ["A", "AAAA"], "action": "route", "server": "fakeip" }
    ],
    "final": "upstream",
    "reverse_mapping": true
  },
  "inbounds": [ $inbounds ],
  "outbounds": [
    $outbounds${outbounds:+,}
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [ { "action": "sniff", "timeout": "1s" }, { "protocol": "dns", "action": "hijack-dns" }, $rules ],
    "default_domain_resolver": "upstream",
    "final": "direct"
  },
  "experimental": {
    "cache_file": { "enabled": true, "path": "$SINGBOX_CACHE", "store_fakeip": true }
  }
}
EOF
  log "Đã ghi $SINGBOX_CONF"
}

desired_idx() {
  awk -F'|' '!/^#/ && (NF==10 || NF==11) { gsub(/[[:space:]]/,"",$3); if ($3 != "") print $3 }' "$CONF" | sort -n -u
}

emit_stale_uci() {
  current="$(desired_idx | tr '\n' ' ')"
  old="$(cat "${MANAGED_FILE:-/etc/sbproxy.managed}" 2>/dev/null || true)"
  for idx in $old; do
    case " $current " in *" $idx "*) continue ;; esac
    for section in "wireless.w$idx" "network.w$idx" "network.brw$idx" "dhcp.w$idx" \
                   "firewall.z$idx" "firewall.z${idx}adm"; do
      echo "delete $section"
    done
  done
}

# ---------------------------------------------------------------------------
# Generate /etc/sbproxy.nft: per-interface TPROXY and per-zone WebRTC blocking.
# ---------------------------------------------------------------------------
build_nft() {
  # Bypass SOCKS server IPs so the proxy's own connection is not intercepted.
  sock_bypass=""
  webrtc_rules=""
  tproxy_rules=""
  dns_rules=""
  _nft_row() {
    idx="$3"; host="$5"; webrtc="${10}"
    tp="$(tproxy_port "$idx")"
    # bypass sock host
    case "$host" in
      *[!0-9.]*) : ;;  # Hostname: skip the IP bypass; sing-box resolves it.
      *) sock_bypass="$sock_bypass    ip daddr $host return\n" ;;
    esac
    # Hijack DNS into sing-box before the local-net bypass so fake-IP answers
    # replace dnsmasq for proxied SSIDs (including hardcoded public resolvers).
    dns_rules="$dns_rules    iifname \"br-w$idx\" udp dport 53 tproxy ip to :$tp meta mark set $TPROXY_MARK accept\n"
    dns_rules="$dns_rules    iifname \"br-w$idx\" tcp dport 53 tproxy ip to :$tp meta mark set $TPROXY_MARK accept\n"
    tproxy_rules="$tproxy_rules    iifname \"br-w$idx\" meta l4proto tcp tproxy ip to :$tp meta mark set $TPROXY_MARK accept\n"
    tproxy_rules="$tproxy_rules    iifname \"br-w$idx\" meta l4proto udp tproxy ip to :$tp meta mark set $TPROXY_MARK accept\n"
    if [ "$webrtc" = "1" ]; then
      webrtc_rules="$webrtc_rules    iifname \"br-w$idx\" tcp dport { $STUN_TCP_PORTS } drop\n"
      webrtc_rules="$webrtc_rules    iifname \"br-w$idx\" udp dport { $STUN_UDP_PORTS } drop\n"
    fi
  }
  for_each_ssid _nft_row

  {
    echo "# GENERATED by sbproxy build_nft — DO NOT EDIT; this file is overwritten."
    echo "table inet sbproxy {"
    echo "  chain webrtc {"
    echo "    type filter hook forward priority filter; policy accept;"
    printf "%b" "$webrtc_rules"
    echo "  }"
    echo "  chain prerouting {"
    echo "    type filter hook prerouting priority mangle; policy accept;"
    echo "    # Hijack DNS from proxied SSIDs into sing-box (fake-IP), ahead of the local-net bypass."
    printf "%b" "$dns_rules"
    echo "    # Do not proxy local or multicast traffic."
    echo "    ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return"
    echo "    # Bypass SOCKS servers through the WAN."
    printf "%b" "$sock_bypass"
    echo "    # Send each Wi-Fi to its matching sing-box TPROXY port."
    printf "%b" "$tproxy_rules"
    echo "  }"
    echo "}"
  } > "$NFT_FILE"
  log "Đã ghi $NFT_FILE"
}
