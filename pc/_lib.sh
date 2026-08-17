#!/bin/sh
# _lib.sh — helpers chung cho các script pc/*.sh (Linux/macOS/Git Bash).
#
# CẤU HÌNH — lấy theo thứ tự ưu tiên (cao → thấp):
#   1. Tham số dòng lệnh  (--host, --user, --port, ...)
#   2. File config        (mặc định pc/sbproxy-pc.conf; đổi bằng --conf FILE
#                          hoặc biến môi trường SBPC_CONF)
#   3. Giá trị mặc định   (user root, port 22, /root/sbproxy, ...)
# File config KHÔNG bắt buộc nếu đã truyền --host.
#
# THAM SỐ CHUNG (mọi script update/backup/restore đều nhận):
#   --conf FILE        Đường dẫn file config
#   --host HOST        IP/hostname router                    (= ROUTER_HOST)
#   --user USER        User SSH, mặc định root               (= ROUTER_USER)
#   --port PORT        Cổng SSH, mặc định 22                 (= ROUTER_PORT)
#   --key FILE         SSH private key                       (= SSH_KEY)
#   --remote-dir DIR   Thư mục repo trên router              (= REMOTE_DIR)
#   --backup-dir DIR   Thư mục backup trên router            (= REMOTE_BACKUP_DIR)
#   --local-dir DIR    Thư mục lưu backup ở máy này          (= LOCAL_BACKUP_DIR)
#
# Cách script dùng lib này:
#   . "$(dirname "$0")/_lib.sh"
#   while [ $# -gt 0 ]; do
#     sbpc_try_common "$1" "${2:-}"
#     if [ "$SBPC_CONSUMED" -gt 0 ]; then shift "$SBPC_CONSUMED"; continue; fi
#     case "$1" in ... tham số riêng của script ... ; esac
#   done
#   sbpc_init      # nạp config + kiểm tra, PHẢI gọi sau khi parse xong

PC_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$PC_DIR/.." && pwd)"

log() { printf '\033[1;32m[pc]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[pc][CẢNH BÁO]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[pc][LỖI]\033[0m %s\n' "$*" >&2; exit 1; }

# sbpc_try_common "$1" "${2:-}" — nhận diện 1 tham số chung.
# Kết quả: SBPC_CONSUMED = số tham số đã tiêu thụ (2 nếu là tham số chung, 0 nếu không).
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

# sbpc_init — nạp file config (nếu có), áp CLI đè lên, điền mặc định, dựng lệnh SSH.
sbpc_init() {
  # 1) File config: --conf > env SBPC_CONF > pc/sbproxy-pc.conf
  CONF_FILE="${CLI_CONF:-${SBPC_CONF:-$PC_DIR/sbproxy-pc.conf}}"
  if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
  elif [ -n "$CLI_CONF" ]; then
    die "Không thấy file config: $CLI_CONF"
  fi

  # 2) CLI đè lên giá trị trong file
  if [ -n "${CLI_HOST:-}" ];              then ROUTER_HOST="$CLI_HOST"; fi
  if [ -n "${CLI_USER:-}" ];              then ROUTER_USER="$CLI_USER"; fi
  if [ -n "${CLI_PORT:-}" ];              then ROUTER_PORT="$CLI_PORT"; fi
  if [ -n "${CLI_KEY:-}" ];               then SSH_KEY="$CLI_KEY"; fi
  if [ -n "${CLI_REMOTE_DIR:-}" ];        then REMOTE_DIR="$CLI_REMOTE_DIR"; fi
  if [ -n "${CLI_REMOTE_BACKUP_DIR:-}" ]; then REMOTE_BACKUP_DIR="$CLI_REMOTE_BACKUP_DIR"; fi
  if [ -n "${CLI_LOCAL_BACKUP_DIR:-}" ];  then LOCAL_BACKUP_DIR="$CLI_LOCAL_BACKUP_DIR"; fi

  # 3) Bắt buộc + mặc định
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

# Chạy lệnh trên router. Dùng: rssh "lệnh"  hoặc  rssh "sh -s" < script
rssh()  { ssh $SSH_OPTS "$TARGET" "$@"; }
# Như rssh nhưng cấp TTY (cho lệnh có hỏi xác nhận trên router)
rssht() { ssh -t $SSH_OPTS "$TARGET" "$@"; }
