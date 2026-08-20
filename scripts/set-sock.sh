#!/bin/sh
# set-sock.sh — change one Wi-Fi's SOCKS5 endpoint without reloading Wi-Fi.
# Updates wifi-socks.conf (the source of truth), then regenerates sing-box config.
#
# Usage:
#   scripts/set-sock.sh <idx> <sock_host> <sock_port> [user] [pass]
# Example:
#   scripts/set-sock.sh 2 5.6.7.8 1080 myuser mypass
#   scripts/set-sock.sh 3 9.9.9.9 1080            # no authentication
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"
require_root
require_conf

IDX="$1"; HOST="$2"; PORT="$3"; USER="${4:-}"; PASS="${5:-}"
[ -n "$IDX" ] && [ -n "$HOST" ] && [ -n "$PORT" ] || die "Usage: set-sock.sh <idx> <host> <port> [user] [pass]"
case "$IDX" in *[!0-9]*|'') die "idx must be a positive integer" ;; esac
case "$PORT" in *[!0-9]*|'') die "port must be an integer from 1 to 65535" ;; esac
[ "$IDX" -ge 1 ] && [ "$IDX" -le 200 ] || die "idx is outside the 1..200 range"
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "port is outside the 1..65535 range"
case "$HOST" in *[!A-Za-z0-9._:-]*) die "host contains invalid characters" ;; esac
case "$USER$PASS" in *'|'*) die "user/pass must not contain the | character" ;; esac

# Ensure the requested index exists.
grep -qE "^[^#][^|]*\|[^|]*\|[[:space:]]*${IDX}[[:space:]]*\|" "$CONF" || die "Wi-Fi idx=$IDX was not found in $CONF"

log "Backing up the configuration before changing SOCKS..."
"$SB_ROOT/scripts/backup.sh" pre-setsock

# Rewrite the matching row while preserving Wi-Fi and isolation fields.
TMP="/tmp/sbproxy-conf.$$"
awk -F'|' -v OFS='|' -v idx="$IDX" -v h="$HOST" -v p="$PORT" -v u="$USER" -v pw="$PASS" '
  /^#/ || NF<10 { print; next }
  { gi=$3; gsub(/ /,"",gi) }
  gi==idx { $5=h; $6=p; $7=u; $8=pw; print; next }
  { print }
' "$CONF" > "$TMP"
mv "$TMP" "$CONF"
validate_conf

log "Regenerating sing-box and nftables configuration (updating SOCKS IP bypass)..."
build_singbox
build_nft

log "Reloading sing-box and tproxy (Wi-Fi will NOT be interrupted)..."
run "/etc/init.d/sbproxy restart"
run "/etc/init.d/sing-box restart"

log "Changed SOCKS for Wi-Fi idx=$IDX -> $HOST:$PORT"
