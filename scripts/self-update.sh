#!/bin/sh
# self-update.sh — cập nhật code sbproxy trên router từ một package upload.
#
# Usage: sh scripts/self-update.sh <package-file> [--force]
#
# Package là .tar.gz (khuyên dùng, tạo bằng pc/make-package.sh) hoặc .zip
# (cần package unzip trên router). Bên trong phải có tối thiểu:
#   VERSION  scripts/apply.sh  scripts/lib.sh  agent/cgi/sbproxy
#   console/web/control-panel.html
#
# An toàn:
#   - Từ chối entry có đường dẫn tuyệt đối hoặc chứa ".." (path traversal).
#   - Từ chối hạ version trừ khi --force.
#   - Backup (scripts/backup.sh pre-update) trước khi ghi đè.
#   - Giữ nguyên config/wifi-socks.conf và config/settings.sh đang dùng.
#   - Deploy lại CGI/UI/healthd rồi reload dịch vụ (bỏ qua nếu không có).
#
# Env override (phục vụ test/máy dev): SB_ROOT, CGI_DEST, UI_DEST,
#   HEALTHD_DEST, HEALTHD_INIT_DEST, SB_NO_SERVICE=1.
set -eu

die() { echo "self-update: $*" >&2; exit 1; }
log() { echo "self-update: $*"; }

PKG="${1:-}"
FORCE=0
if [ "${2:-}" = "--force" ]; then FORCE=1; fi
[ -n "$PKG" ] || die "cách dùng: self-update.sh <package-file> [--force]"
[ -f "$PKG" ] || die "không thấy file package: $PKG"

SB_ROOT="${SB_ROOT:-/root/sbproxy}"
[ -d "$SB_ROOT" ] || die "SB_ROOT không tồn tại: $SB_ROOT"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sbproxy-selfupdate.XXXXXX")" \
  || die "không tạo được thư mục staging"
trap 'rm -rf "$STAGE"' EXIT
trap 'exit 1' HUP INT TERM

# ---- nhận dạng package qua magic bytes ----
magic="$(od -An -tx1 -N4 "$PKG" 2>/dev/null | tr -d ' \n')"
KIND=""
case "$magic" in
  1f8b*)     KIND=targz ;;
  504b0304*) KIND=zip ;;
  *) die "package không phải .tar.gz hoặc .zip" ;;
esac

# ---- liệt kê entry và chặn path traversal TRƯỚC khi giải nén ----
if [ "$KIND" = targz ]; then
  tar tzf "$PKG" > "$STAGE/manifest" 2>/dev/null || die "tar.gz hỏng hoặc không đọc được"
else
  command -v unzip >/dev/null 2>&1 || die "router thiếu unzip — dùng package .tar.gz"
  unzip -l "$PKG" | awk 'NF >= 4 && $1 ~ /^[0-9]+$/ { print $NF }' > "$STAGE/manifest" \
    || die "zip hỏng hoặc không đọc được"
fi
[ -s "$STAGE/manifest" ] || die "package rỗng"
if grep -Eq '(^|/)\.\.(/|$)|^/' "$STAGE/manifest"; then
  die "package chứa đường dẫn không an toàn (tuyệt đối hoặc ..)"
fi

# ---- giải nén vào staging ----
mkdir -p "$STAGE/x"
if [ "$KIND" = targz ]; then
  tar xzf "$PKG" -C "$STAGE/x" || die "giải nén tar.gz thất bại"
else
  unzip -oq "$PKG" -d "$STAGE/x" || die "giải nén zip thất bại"
fi

# Chấp nhận cả package bọc trong một thư mục gốc duy nhất (zip cả folder repo).
NEW_ROOT="$STAGE/x"
if [ ! -f "$NEW_ROOT/VERSION" ]; then
  sub="$(find "$STAGE/x" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [ -n "$sub" ] && [ -f "$sub/VERSION" ]; then NEW_ROOT="$sub"; fi
fi

# ---- kiểm tra nội dung tối thiểu ----
for f in VERSION scripts/apply.sh scripts/lib.sh agent/cgi/sbproxy console/web/control-panel.html; do
  [ -f "$NEW_ROOT/$f" ] || die "package thiếu $f — không phải package sbproxy hợp lệ"
done

# ---- so sánh version (chặn downgrade) ----
ver_ok() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }
ver_num() { printf '%s' "$1" | awk -F. '{ printf "%d", $1 * 100000000 + $2 * 10000 + $3 }'; }
NEW_VER="$(tr -d ' \r\n' < "$NEW_ROOT/VERSION")"
CUR_VER="$(tr -d ' \r\n' < "$SB_ROOT/VERSION" 2>/dev/null || echo 0.0.0)"
ver_ok "$NEW_VER" || die "VERSION trong package không hợp lệ: '$NEW_VER'"
ver_ok "$CUR_VER" || CUR_VER=0.0.0
if [ "$(ver_num "$NEW_VER")" -lt "$(ver_num "$CUR_VER")" ] && [ "$FORCE" != 1 ]; then
  die "package $NEW_VER cũ hơn bản đang chạy $CUR_VER — dùng --force nếu muốn hạ version"
fi

# ---- backup trước khi ghi đè ----
if [ -f "$SB_ROOT/scripts/backup.sh" ]; then
  (cd "$SB_ROOT" && sh scripts/backup.sh pre-update) \
    || die "backup pre-update thất bại — không cập nhật"
else
  log "cảnh báo: không thấy scripts/backup.sh, bỏ qua backup"
fi

# ---- giữ config đang dùng ----
for keep in wifi-socks.conf settings.sh; do
  if [ -f "$SB_ROOT/config/$keep" ]; then
    mkdir -p "$NEW_ROOT/config"
    cp "$SB_ROOT/config/$keep" "$NEW_ROOT/config/$keep"
  fi
done

# ---- ghi đè SB_ROOT ----
cp -r "$NEW_ROOT"/. "$SB_ROOT"/ || die "copy vào $SB_ROOT thất bại"
chmod +x "$SB_ROOT"/scripts/*.sh "$SB_ROOT/agent/cgi/sbproxy" \
  "$SB_ROOT/agent/sbproxy-healthd" "$SB_ROOT/agent/install-agent.sh" 2>/dev/null || true

# ---- deploy lại agent/UI (bỏ qua từng phần nếu đích không tồn tại) ----
CGI_DEST="${CGI_DEST:-/www/cgi-bin/sbproxy}"
UI_DEST="${UI_DEST:-/www/sbproxy/index.html}"
HEALTHD_DEST="${HEALTHD_DEST:-/usr/sbin/sbproxy-healthd}"
HEALTHD_INIT_DEST="${HEALTHD_INIT_DEST:-/etc/init.d/sbproxy-healthd}"
deploy() { # src dest
  [ -d "$(dirname "$2")" ] || return 0
  cp "$1" "$2" && chmod +x "$2" 2>/dev/null || true
  log "deploy $2"
}
deploy "$SB_ROOT/agent/cgi/sbproxy" "$CGI_DEST"
if [ -d "$(dirname "$UI_DEST")" ]; then
  cp "$SB_ROOT/console/web/control-panel.html" "$UI_DEST"
  log "deploy $UI_DEST"
fi
deploy "$SB_ROOT/agent/sbproxy-healthd" "$HEALTHD_DEST"
deploy "$SB_ROOT/agent/init.d/sbproxy-healthd" "$HEALTHD_INIT_DEST"

if [ "${SB_NO_SERVICE:-0}" != 1 ]; then
  if [ -x "$HEALTHD_INIT_DEST" ]; then "$HEALTHD_INIT_DEST" restart >/dev/null 2>&1 || true; fi
  if [ -x /etc/init.d/uhttpd ]; then /etc/init.d/uhttpd reload >/dev/null 2>&1 || true; fi
fi

log "OK: $CUR_VER -> $NEW_VER"
log "config/wifi-socks.conf và settings.sh được giữ nguyên; backup: pre-update"
log "chưa reload WiFi — chạy apply khi bạn muốn áp thay đổi cấu hình"
