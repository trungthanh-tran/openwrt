#!/bin/sh
# doctor.sh — one-shot, read-only health report across every subsystem.
# Complements verify.sh (pass/fail acceptance) and diagnose.sh (raw evidence):
# doctor prints a human-readable status per area and exits non-zero on any FAIL.
set -u
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"

pass=0; warn=0; failc=0
ok()  { printf '  [OK]   %s\n' "$*"; pass=$((pass + 1)); }
wn()  { printf '  [WARN] %s\n' "$*"; warn=$((warn + 1)); }
bad() { printf '  [FAIL] %s\n' "$*"; failc=$((failc + 1)); }
sec() { printf '\n== %s ==\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

sec "Nền tảng"
if have jq && have ubus; then
  model="$(ubus call system board 2>/dev/null | jq -r '.model // empty' 2>/dev/null)"
  board="$(ubus call system board 2>/dev/null | jq -r '.board_name // empty' 2>/dev/null)"
  [ -n "$model" ] && ok "Thiết bị: $model ($board)" || wn "Không đọc được model/board"
else
  wn "thiếu jq/ubus — bỏ qua nhận diện thiết bị"
fi

sec "Gói phụ thuộc"
for c in nft iw jq ubus; do
  have "$c" && ok "có $c" || bad "thiếu $c"
done
if have sing-box; then
  v="$(sing-box version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -1)"
  if [ -n "$v" ]; then
    maj="${v%%.*}"; rest="${v#*.}"; min="${rest%%.*}"
    if [ "$maj" -gt 1 ] 2>/dev/null || { [ "$maj" -eq 1 ] && [ "$min" -ge 12 ]; } 2>/dev/null; then
      ok "sing-box $v (>= 1.12, hỗ trợ cú pháp DNS mới)"
    else
      bad "sing-box $v < 1.12 — config DNS fake-IP sẽ không nạp được"
    fi
  else
    wn "có sing-box nhưng không đọc được version"
  fi
else
  bad "thiếu sing-box"
fi

sec "Cấu hình wifi-socks.conf"
if [ -f "$CONF" ]; then
  if ( validate_conf ) >/dev/null 2>&1; then ok "conf hợp lệ"; else bad "conf KHÔNG hợp lệ (xem chi tiết khi apply.sh)"; fi
  n="$(desired_idx | grep -c .)"
  ok "Số SSID quản lý: ${n:-0}"
else
  wn "Chưa có $CONF (copy từ config/wifi-socks.conf.example)"
fi

sec "sing-box"
if pgrep -f 'sing-box' >/dev/null 2>&1; then ok "tiến trình đang chạy"; else bad "KHÔNG chạy"; fi
if [ -f /etc/sing-box/config.json ]; then
  if ( singbox_check /etc/sing-box/config.json ) >/dev/null 2>&1; then ok "config hợp lệ (sing-box check)"; else bad "config lỗi (sing-box check)"; fi
  grep -q '"fakeip"' /etc/sing-box/config.json && ok "DNS fake-IP có trong config" || wn "không thấy khối fakeip trong config"
  [ -f "${SINGBOX_CACHE:-/etc/sing-box/cache.db}" ] && ok "cache fake-IP tồn tại" || wn "chưa có cache.db (tạo khi chạy)"
else
  bad "thiếu /etc/sing-box/config.json (chưa apply?)"
fi
if [ -n "${SINGBOX_COMPAT_ENV:-}" ]; then
  grep -q 'ENABLE_DEPRECATED' /etc/init.d/sing-box 2>/dev/null && ok "compat env đã chèn vào init" || wn "SINGBOX_COMPAT_ENV đặt nhưng init chưa có"
fi

sec "nftables TPROXY + DNS hijack"
if nft list table inet sbproxy >/dev/null 2>&1; then
  ok "table inet sbproxy tồn tại"
  if nft list chain inet sbproxy prerouting 2>/dev/null | grep -q 'dport 53'; then
    ok "rule hijack DNS (dport 53) đã nạp"
  else
    wn "chưa thấy rule hijack DNS cổng 53 (client có thể leak DNS)"
  fi
else
  bad "thiếu table sbproxy (init sbproxy chưa chạy?)"
fi
ip rule 2>/dev/null | grep -q '0x1' && ok "policy rule fwmark tồn tại" || bad "thiếu ip rule fwmark"
ip route show table "${TPROXY_TABLE:-100}" 2>/dev/null | grep -q . && ok "route table ${TPROXY_TABLE:-100} có entry" || bad "route table ${TPROXY_TABLE:-100} trống"

sec "Wi-Fi & quản lý thiết bị"
ifn="$(wifi_ifaces | grep -c .)"
[ "${ifn:-0}" -gt 0 ] && ok "SSID đang phát: $ifn interface" || wn "không thấy wifi-iface nào up"
h="$(ubus list 2>/dev/null | grep -c '^hostapd\.')"
[ "${h:-0}" -gt 0 ] && ok "hostapd ubus: $h instance (kick khả dụng)" || wn "không thấy hostapd ubus (kick sẽ lỗi; cần wpad/hostapd đầy đủ)"
have iw && ok "iw có (liệt kê client)" || bad "thiếu iw"
[ -f /tmp/dhcp.leases ] && ok "đọc được DHCP leases (map IP/tên máy)" || wn "chưa có /tmp/dhcp.leases"

sec "MAC bans"
bf="${BANS_FILE:-/etc/sbproxy.bans}"
if [ -f "$bf" ]; then
  nb="$(grep -c '|' "$bf" 2>/dev/null)"; ok "số MAC bị cấm: ${nb:-0}"
else
  ok "chưa có MAC nào bị cấm"
fi

sec "Agent LAN"
[ -s /etc/sbproxy/token ] && ok "token tồn tại" || wn "chưa có token (chạy agent/install-agent.sh)"
[ -x /www/cgi-bin/sbproxy ] && ok "CGI đã cài (/www/cgi-bin/sbproxy)" || wn "CGI chưa cài"
[ -f /www/sbproxy/index.html ] && ok "UI Web self-host đã cài" || wn "UI Web self-host chưa cài"
pgrep -f uhttpd >/dev/null 2>&1 && ok "uhttpd đang chạy" || wn "uhttpd không chạy"
[ -x /usr/sbin/sbproxy-healthd ] && ok "healthd đã cài" || wn "healthd chưa cài"

sec "Tổng kết"
printf '  OK=%d  WARN=%d  FAIL=%d\n' "$pass" "$warn" "$failc"
if [ "$failc" -eq 0 ]; then
  [ "$warn" -gt 0 ] && printf '\nKết luận: hệ thống cơ bản ỔN (có %d cảnh báo cần xem).\n' "$warn" \
                    || printf '\nKết luận: hệ thống ỔN.\n'
  exit 0
else
  printf '\nKết luận: có %d lỗi nghiêm trọng — xem [FAIL] ở trên, chạy scripts/diagnose.sh để lấy log.\n' "$failc"
  exit 1
fi
