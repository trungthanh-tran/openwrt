#!/bin/sh
# set-sock.sh — đổi SOCKS5 của MỘT WiFi mà KHÔNG rớt WiFi (chỉ reload sing-box).
# Cập nhật wifi-socks.conf (single source of truth) rồi sinh lại config sing-box.
#
# Dùng:
#   scripts/set-sock.sh <idx> <sock_host> <sock_port> [user] [pass]
# VD:
#   scripts/set-sock.sh 2 5.6.7.8 1080 myuser mypass
#   scripts/set-sock.sh 3 9.9.9.9 1080            # không auth
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root
require_conf

IDX="$1"; HOST="$2"; PORT="$3"; USER="${4:-}"; PASS="${5:-}"
[ -n "$IDX" ] && [ -n "$HOST" ] && [ -n "$PORT" ] || die "Cú pháp: set-sock.sh <idx> <host> <port> [user] [pass]"
case "$IDX" in *[!0-9]*|'') die "idx phải là số nguyên dương" ;; esac
case "$PORT" in *[!0-9]*|'') die "port phải là số từ 1 đến 65535" ;; esac
[ "$IDX" -ge 1 ] && [ "$IDX" -le 200 ] || die "idx ngoài phạm vi 1..200"
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "port ngoài phạm vi 1..65535"
case "$HOST" in *[!A-Za-z0-9._:-]*) die "host chứa ký tự không hợp lệ" ;; esac
case "$USER$PASS" in *'|'*) die "user/pass không được chứa ký tự |" ;; esac

# Kiểm tra idx tồn tại trong conf
grep -qE "^[^#][^|]*\|[^|]*\|[[:space:]]*$IDX[[:space:]]*\|" "$CONF" || die "Không tìm thấy WiFi idx=$IDX trong $CONF"

log "Backup config trước khi đổi SOCKS..."
"$SB_ROOT/scripts/backup.sh" pre-setsock

# Ghi lại dòng có idx tương ứng: giữ name|band|idx|key, thay 4 cột sock, giữ isolate|webrtc
TMP="/tmp/sbproxy-conf.$$"
awk -F'|' -v OFS='|' -v idx="$IDX" -v h="$HOST" -v p="$PORT" -v u="$USER" -v pw="$PASS" '
  /^#/ || NF<10 { print; next }
  { gi=$3; gsub(/ /,"",gi) }
  gi==idx { $5=h; $6=p; $7=u; $8=pw; print; next }
  { print }
' "$CONF" > "$TMP"
mv "$TMP" "$CONF"
validate_conf

log "Sinh lại sing-box + nftables (cập nhật bypass sock IP)..."
build_singbox
build_nft

log "Reload sing-box + tproxy (WiFi KHÔNG bị ngắt)..."
run "/etc/init.d/sbproxy restart"
run "/etc/init.d/sing-box restart"

log "Đã đổi SOCKS cho WiFi idx=$IDX -> $HOST:$PORT"
