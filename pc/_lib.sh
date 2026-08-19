#!/bin/sh
# shellcheck disable=SC2034,SC1090  # Shared variables/config are consumed by callers.
# _lib.sh — shared helpers for pc/*.sh on Linux, macOS, and Git Bash.
#
# Configuration precedence: CLI arguments, config file, then defaults.
# The config file defaults to pc/sbproxy-pc.conf and is optional with --host.
#
# Shared arguments accepted by update, backup, and restore:
#   --conf FILE        Configuration file path
#   --host HOST        IP/hostname router                    (= ROUTER_HOST)
#   --user USER        SSH user, default root                 (= ROUTER_USER)
#   --port PORT        SSH port, default 22                   (= ROUTER_PORT)
#   --key FILE         SSH private key                       (= SSH_KEY)
#   --remote-dir DIR   Repository directory on the router    (= REMOTE_DIR)
#   --backup-dir DIR   Backup directory on the router        (= REMOTE_BACKUP_DIR)
#   --local-dir DIR    Local backup directory                (= LOCAL_BACKUP_DIR)
#
# Typical caller pattern:
#   . "$(dirname "$0")/_lib.sh"
#   while [ $# -gt 0 ]; do
#     sbpc_try_common "$1" "${2:-}"
#     if [ "$SBPC_CONSUMED" -gt 0 ]; then shift "$SBPC_CONSUMED"; continue; fi
#     case "$1" in ... script-specific options ... ; esac
#   done
#   sbpc_init      # load and validate config after argument parsing

PC_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$PC_DIR/.." && pwd)"

log() { printf '\033[1;32m[pc]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[pc][CẢNH BÁO]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[pc][LỖI]\033[0m %s\n' "$*" >&2; exit 1; }

# Recognize one shared option and set SBPC_CONSUMED to 2 or 0.
sbpc_try_common() {
  SBPC_CONSUMED=2
  case "$1" in
    --conf)       CLI_CONF="$2" ;;
    --host)       CLI_HOST="$2" ;;
    --user)       CLI_USER="$2" ;;
    --port)       CLI_PORT="$2" ;;
    --key)        CLI_KEY="$2" ;;
    --remote-dir) CLI_REMOTE_DIR="$2" ;;
    --backup-dir) CLI_REMOTE_BACKUP_DIR="$2" ;;
    --local-dir)  CLI_LOCAL_BACKUP_DIR="$2" ;;
    *) SBPC_CONSUMED=0; return 0 ;;
  esac
  [ -n "$2" ] || die "Thiếu giá trị cho $1"
}

# Load optional config, apply CLI overrides and defaults, then build SSH options.
sbpc_init() {
  # 1) File config: --conf > env SBPC_CONF > pc/sbproxy-pc.conf
  CONF_FILE="${CLI_CONF:-${SBPC_CONF:-$PC_DIR/sbproxy-pc.conf}}"
  if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
  elif [ -n "$CLI_CONF" ]; then
    die "Không thấy file config: $CLI_CONF"
  fi

  # CLI values override file values.
  if [ -n "${CLI_HOST:-}" ];              then ROUTER_HOST="$CLI_HOST"; fi
  if [ -n "${CLI_USER:-}" ];              then ROUTER_USER="$CLI_USER"; fi
  if [ -n "${CLI_PORT:-}" ];              then ROUTER_PORT="$CLI_PORT"; fi
  if [ -n "${CLI_KEY:-}" ];               then SSH_KEY="$CLI_KEY"; fi
  if [ -n "${CLI_REMOTE_DIR:-}" ];        then REMOTE_DIR="$CLI_REMOTE_DIR"; fi
  if [ -n "${CLI_REMOTE_BACKUP_DIR:-}" ]; then REMOTE_BACKUP_DIR="$CLI_REMOTE_BACKUP_DIR"; fi
  if [ -n "${CLI_LOCAL_BACKUP_DIR:-}" ];  then LOCAL_BACKUP_DIR="$CLI_LOCAL_BACKUP_DIR"; fi

  # Required values and defaults.
  [ -n "${ROUTER_HOST:-}" ] || die "Chưa biết địa chỉ router. Truyền --host <IP> hoặc tạo $PC_DIR/sbproxy-pc.conf (copy từ sbproxy-pc.conf.example)."
  ROUTER_USER="${ROUTER_USER:-root}"
  ROUTER_PORT="${ROUTER_PORT:-22}"
  REMOTE_DIR="${REMOTE_DIR:-/root/sbproxy}"
  REMOTE_BACKUP_DIR="${REMOTE_BACKUP_DIR:-/root/sbproxy-backups}"
  LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$PC_DIR/backups}"
  SSH_KEY="${SSH_KEY:-}"

  TARGET="$ROUTER_USER@$ROUTER_HOST"
  SSH_OPTS="-p $ROUTER_PORT -o ConnectTimeout=10"
  if [ -n "$SSH_KEY" ]; then
    [ -f "$SSH_KEY" ] || die "Không thấy SSH key: $SSH_KEY"
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
  fi
}

# Run a command on the router.
rssh()  { ssh $SSH_OPTS "$TARGET" "$@"; }
# Run with a TTY for interactive router commands.
rssht() { ssh -t $SSH_OPTS "$TARGET" "$@"; }
