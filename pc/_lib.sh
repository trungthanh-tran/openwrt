#!/bin/sh
# _lib.sh — helpers chung cho các script pc/*.sh (Linux/macOS/Git Bash).
# Nạp cấu hình từ pc/sbproxy-pc.conf và cung cấp rssh/log/die.

PC_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$PC_DIR/.." && pwd)"

CONF_FILE="${SBPC_CONF:-$PC_DIR/sbproxy-pc.conf}"
[ -f "$CONF_FILE" ] || {
  echo "LỖI: chưa có $CONF_FILE" >&2
  echo "  -> copy pc/sbproxy-pc.conf.example thành pc/sbproxy-pc.conf rồi sửa." >&2
  exit 1
}
. "$CONF_FILE"

ROUTER_HOST="${ROUTER_HOST:?thiếu ROUTER_HOST trong sbproxy-pc.conf}"
ROUTER_USER="${ROUTER_USER:-root}"
ROUTER_PORT="${ROUTER_PORT:-22}"
REMOTE_DIR="${REMOTE_DIR:-/root/sbproxy}"
REMOTE_BACKUP_DIR="${REMOTE_BACKUP_DIR:-/root/sbproxy-backups}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$PC_DIR/backups}"
SSH_KEY="${SSH_KEY:-}"

TARGET="$ROUTER_USER@$ROUTER_HOST"
SSH_OPTS="-p $ROUTER_PORT -o ConnectTimeout=10"
[ -n "$SSH_KEY" ] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"

# Chạy lệnh trên router. Dùng: rssh "lệnh"  hoặc  rssh "sh -s" < script
rssh()  { ssh $SSH_OPTS "$TARGET" "$@"; }
# Như rssh nhưng cấp TTY (cho lệnh có hỏi xác nhận trên router)
rssht() { ssh -t $SSH_OPTS "$TARGET" "$@"; }

log() { printf '\033[1;32m[pc]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[pc][CẢNH BÁO]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[pc][LỖI]\033[0m %s\n' "$*" >&2; exit 1; }
