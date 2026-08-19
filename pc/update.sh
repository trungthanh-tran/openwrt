#!/bin/sh
# update.sh — upload the current repository to the router over SSH.
# Preserve router-side wifi-socks.conf and settings.sh unless explicitly requested.
#
# Usage: pc/update.sh [options]
#
# Script options:
#   --apply           Run apply.sh after upload.
#   --with-settings   Replace router-side settings.sh.
#   -h, --help        Show help.
#
# Shared options (see _lib.sh): --conf FILE, --host HOST, --user USER, --port PORT,
#   --key FILE, --remote-dir DIR, --backup-dir DIR, --local-dir DIR
# Precedence: CLI arguments, config file, defaults. A config file is optional with --host.
#
# Examples:
#   pc/update.sh                          # read pc/sbproxy-pc.conf
#   pc/update.sh --apply                  # upload and apply
#   pc/update.sh --host 192.168.8.1       # no config file required
#   pc/update.sh --conf ~/router2.conf --apply
set -e
. "$(dirname "$0")/_lib.sh"

usage() { awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; }

WITH_SETTINGS=0; APPLY=0
while [ $# -gt 0 ]; do
  sbpc_try_common "$1" "${2:-}"
  if [ "$SBPC_CONSUMED" -gt 0 ]; then shift "$SBPC_CONSUMED"; continue; fi
  case "$1" in
    --with-settings) WITH_SETTINGS=1; shift ;;
    --apply)         APPLY=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) die "Tham số lạ: $1 — xem: pc/update.sh --help" ;;
  esac
done
sbpc_init

# 1) Package router-side files; pc/ may contain local secrets and is excluded.
TMP_TAR="${TMPDIR:-/tmp}/sbproxy-update-$$.tar.gz"
trap 'rm -f "$TMP_TAR"' EXIT
log "Đóng gói repo..."
tar czf "$TMP_TAR" -C "$REPO_DIR" --exclude=node_modules \
  README.md agent config console docs etc scripts tools

# 2) Upload and extract while preserving active configuration.
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

# 3) Apply when requested.
if [ "$APPLY" = "1" ]; then
  log "Chạy apply.sh trên router (tự backup trước khi áp)..."
  rssht "cd '$REMOTE_DIR' && sh scripts/apply.sh"
else
  log "Xong. Chưa áp cấu hình — khi sẵn sàng:"
  log "  pc/update.sh --apply   (hoặc SSH vào router: sh $REMOTE_DIR/scripts/apply.sh)"
fi
