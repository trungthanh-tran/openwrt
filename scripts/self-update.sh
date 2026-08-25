#!/bin/sh
# self-update.sh — update sbproxy code on the router from an uploaded package.
#
# Usage: sh scripts/self-update.sh <package-file> [--force]
#
# The package may be a .tar.gz (recommended, created with pc/make-package.sh) or .zip
# (requires the unzip package on the router). It must contain at least:
#   VERSION  scripts/apply.sh  scripts/lib.sh  agent/cgi/sbproxy
#   console/web/control-panel.html
#
# Safety:
#   - Reject entries with absolute paths or ".." components (path traversal).
#   - Reject version downgrades unless --force is specified.
#   - Create a backup (scripts/backup.sh pre-update) before overwriting files.
#   - Preserve the active config/wifi-socks.conf and config/settings.sh files.
#   - Redeploy CGI/UI/healthd and reload services (skip components that are absent).
#
# Environment overrides (for tests/development machines): SB_ROOT, CGI_DEST, UI_DEST,
#   HEALTHD_DEST, HEALTHD_INIT_DEST, SB_NO_SERVICE=1.
set -eu

die() { echo "self-update: $*" >&2; exit 1; }
log() { echo "self-update: $*"; }

PKG="${1:-}"
FORCE=0
if [ "${2:-}" = "--force" ]; then FORCE=1; fi
[ -n "$PKG" ] || die "usage: self-update.sh <package-file> [--force]"
[ -f "$PKG" ] || die "package file not found: $PKG"

SB_ROOT="${SB_ROOT:-/root/sbproxy}"
[ -d "$SB_ROOT" ] || die "SB_ROOT does not exist: $SB_ROOT"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sbproxy-selfupdate.XXXXXX")" \
  || die "failed to create the staging directory"
trap 'rm -rf "$STAGE"' EXIT
trap 'exit 1' HUP INT TERM

# ---- identify the package using magic bytes ----
magic="$(od -An -tx1 -N4 "$PKG" 2>/dev/null | tr -d ' \n')"
KIND=""
case "$magic" in
  1f8b*)     KIND=targz ;;
  504b0304*) KIND=zip ;;
  *) die "package is not a .tar.gz or .zip file" ;;
esac

# ---- list entries and block path traversal BEFORE extraction ----
if [ "$KIND" = targz ]; then
  tar tzf "$PKG" > "$STAGE/manifest" 2>/dev/null || die "tar.gz is corrupt or unreadable"
else
  command -v unzip >/dev/null 2>&1 || die "unzip is missing on the router — use a .tar.gz package"
  unzip -l "$PKG" | awk 'NF >= 4 && $1 ~ /^[0-9]+$/ { print $NF }' > "$STAGE/manifest" \
    || die "zip is corrupt or unreadable"
fi
[ -s "$STAGE/manifest" ] || die "package is empty"
if grep -Eq '(^|/)\.\.(/|$)|^/' "$STAGE/manifest"; then
  die "package contains an unsafe path (absolute or containing ..)"
fi

# ---- extract into staging ----
mkdir -p "$STAGE/x"
if [ "$KIND" = targz ]; then
  tar xzf "$PKG" -C "$STAGE/x" || die "failed to extract tar.gz"
else
  unzip -oq "$PKG" -d "$STAGE/x" || die "failed to extract zip"
fi

# Also accept a package wrapped in a single root directory (a zipped repository folder).
NEW_ROOT="$STAGE/x"
if [ ! -f "$NEW_ROOT/VERSION" ]; then
  sub="$(find "$STAGE/x" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [ -n "$sub" ] && [ -f "$sub/VERSION" ]; then NEW_ROOT="$sub"; fi
fi

# ---- validate the minimum required contents ----
for f in VERSION scripts/apply.sh scripts/lib.sh agent/cgi/sbproxy console/web/control-panel.html; do
  [ -f "$NEW_ROOT/$f" ] || die "package is missing $f — this is not a valid sbproxy package"
done

# ---- compare versions (block downgrades) ----
ver_ok() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }
ver_num() { printf '%s' "$1" | awk -F. '{ printf "%d", $1 * 100000000 + $2 * 10000 + $3 }'; }
NEW_VER="$(tr -d ' \r\n' < "$NEW_ROOT/VERSION")"
CUR_VER="$(tr -d ' \r\n' < "$SB_ROOT/VERSION" 2>/dev/null || echo 0.0.0)"
ver_ok "$NEW_VER" || die "invalid VERSION in package: '$NEW_VER'"
ver_ok "$CUR_VER" || CUR_VER=0.0.0
if [ "$(ver_num "$NEW_VER")" -lt "$(ver_num "$CUR_VER")" ] && [ "$FORCE" != 1 ]; then
  die "package $NEW_VER is older than the running version $CUR_VER — use --force to downgrade"
fi

# ---- back up before overwriting ----
if [ -f "$SB_ROOT/scripts/backup.sh" ]; then
  (cd "$SB_ROOT" && sh scripts/backup.sh pre-update) \
    || die "pre-update backup failed — update aborted"
else
  log "warning: scripts/backup.sh was not found; skipping backup"
fi

# ---- preserve the active configuration ----
for keep in wifi-socks.conf settings.sh; do
  if [ -f "$SB_ROOT/config/$keep" ]; then
    mkdir -p "$NEW_ROOT/config"
    cp "$SB_ROOT/config/$keep" "$NEW_ROOT/config/$keep"
  fi
done

# ---- overwrite SB_ROOT ----
cp -r "$NEW_ROOT"/. "$SB_ROOT"/ || die "failed to copy files into $SB_ROOT"
chmod +x "$SB_ROOT"/scripts/*.sh "$SB_ROOT/agent/cgi/sbproxy" \
  "$SB_ROOT/agent/sbproxy-healthd" "$SB_ROOT/agent/install-agent.sh" 2>/dev/null || true

# ---- redeploy the agent/UI (skip components whose destinations do not exist) ----
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

# ---- migrate /etc/sbproxy/env ----
# The agent sources this file before running any script, so a value left in it
# overrides the shipped default forever. install-agent.sh used to pin the
# uplink with GATEWAY_EXPECTED_INTERFACE=wwan, which now makes every wired-WAN
# router report a degraded gateway; retire exactly that line so an in-place
# update fixes the router instead of only the scripts. A different value is an
# operator's own choice and is left alone.
ENV_FILE="${ENV_FILE:-/etc/sbproxy/env}"
if [ -f "$ENV_FILE" ] && grep -q '^GATEWAY_EXPECTED_INTERFACE=wwan$' "$ENV_FILE"; then
  ENV_TMP="$ENV_FILE.$$"
  if sed 's/^GATEWAY_EXPECTED_INTERFACE=wwan$/#GATEWAY_EXPECTED_INTERFACE=/' "$ENV_FILE" > "$ENV_TMP" \
     && cat "$ENV_TMP" > "$ENV_FILE"; then
    log "migrated $ENV_FILE: any uplink is accepted again"
  else
    log "warning: could not migrate $ENV_FILE; the gateway check may stay pinned to wwan"
  fi
  rm -f "$ENV_TMP"
fi

if [ "${SB_NO_SERVICE:-0}" != 1 ]; then
  if [ -x "$HEALTHD_INIT_DEST" ]; then "$HEALTHD_INIT_DEST" restart >/dev/null 2>&1 || true; fi
  if [ -x /etc/init.d/uhttpd ]; then /etc/init.d/uhttpd reload >/dev/null 2>&1 || true; fi
fi

log "OK: $CUR_VER -> $NEW_VER"
log "config/wifi-socks.conf and settings.sh were preserved; backup: pre-update"
log "Wi-Fi was not reloaded — run apply when you are ready to apply configuration changes"
