#!/bin/sh
# update.sh — đẩy code mới nhất của repo lên router qua SSH.
# GIỮ NGUYÊN config đã chỉnh trên router (wifi-socks.conf + settings.sh) trừ khi bảo khác.
#
# Dùng:
#   pc/update.sh                  # chỉ cập nhật code
#   pc/update.sh --apply          # cập nhật code rồi chạy apply.sh trên router (tự backup trước)
#   pc/update.sh --with-settings  # ghi đè luôn config/settings.sh bằng bản trong repo
set -e
. "$(dirname "$0")/_lib.sh"

WITH_SETTINGS=0; APPLY=0
for a in "$@"; do case "$a" in
  --with-settings) WITH_SETTINGS=1 ;;
  --apply)         APPLY=1 ;;
  *) die "Tham số lạ: $a (hỗ trợ: --with-settings, --apply)" ;;
esac; done

# 1) Đóng gói repo (không kèm pc/ — script phía máy quản trị, có thể chứa secret)
TMP_TAR="${TMPDIR:-/tmp}/sbproxy-update-$$.tar.gz"
trap 'rm -f "$TMP_TAR"' EXIT
log "Đóng gói repo..."
tar czf "$TMP_TAR" -C "$REPO_DIR" --exclude=node_modules \
  README.md agent cloud-server config docs etc scripts tools ui

# 2) Đẩy lên router + giải nén, giữ lại config đang dùng
log "Đẩy lên $TARGET:$REMOTE_DIR ..."
rssh "cat > /tmp/sbproxy-update.tar.gz" < "$TMP_TAR"
rssh "REMOTE_DIR='$REMOTE_DIR' WITH_SETTINGS=$WITH_SETTINGS sh -s" <<'EOF'
set -e
KEEP="/tmp/sbproxy-keep.$$"
mkdir -p "$REMOTE_DIR" "$KEEP"
if [ -f "$REMOTE_DIR/config/wifi-socks.conf" ]; then cp "$REMOTE_DIR/config/wifi-socks.conf" "$KEEP/"; fi
if [ "$WITH_SETTINGS" != "1" ] && [ -f "$REMOTE_DIR/config/settings.sh" ]; then cp "$REMOTE_DIR/config/settings.sh" "$KEEP/"; fi
tar xzf /tmp/sbproxy-update.tar.gz -C "$REMOTE_DIR"
if [ -f "$KEEP/wifi-socks.conf" ]; then cp "$KEEP/wifi-socks.conf" "$REMOTE_DIR/config/wifi-socks.conf"; fi
if [ -f "$KEEP/settings.sh" ];      then cp "$KEEP/settings.sh"      "$REMOTE_DIR/config/settings.sh"; fi
chmod +x "$REMOTE_DIR"/scripts/*.sh 2>/dev/null || true
rm -rf "$KEEP" /tmp/sbproxy-update.tar.gz
echo "[router] Code đã cập nhật -> $REMOTE_DIR"
EOF

# 3) Áp dụng (tuỳ chọn)
if [ "$APPLY" = "1" ]; then
  log "Chạy apply.sh trên router (tự backup trước khi áp)..."
  rssht "cd '$REMOTE_DIR' && sh scripts/apply.sh"
else
  log "Xong. Chưa áp cấu hình — khi sẵn sàng:"
  log "  pc/update.sh --apply   (hoặc SSH vào router: sh $REMOTE_DIR/scripts/apply.sh)"
fi
