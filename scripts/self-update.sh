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
#   - Preserve the active config/wifi-socks.conf, config/proxy-pools.conf and
#     config/settings.sh files, appending only settings.sh keys this version
#     introduced that the router has never had.
#   - Redeploy CGI/UI/healthd and reload services (skip components that are absent).
#
# Environment overrides (for tests/development machines): SB_ROOT, CGI_DEST, UI_DEST,
#   HEALTHD_DEST, HEALTHD_INIT_DEST, SB_NO_SERVICE=1.
set -eu
# Files written here are executed by uhttpd, which refuses a CGI that others
# cannot execute (403 Forbidden). A `chmod +x` honours the caller's umask and,
# under the agent's own CGI process, can leave the file 0700; so the umask is
# pinned and the modes below are spelled out.
umask 022

die() { echo "self-update: $*" >&2; exit 1; }
log() { echo "self-update: $*"; }

# Append the assignments a new version ships that this router has never had,
# leaving every value it already sets exactly alone. Prints the keys it added.
#
# Keeping settings.sh across updates is right -- it holds the operator's
# choices -- but it means a key introduced later never arrives, the code silently
# runs on whatever default it hardcodes, and the file stops describing the
# router. This closes that gap without ever rewriting a line someone chose.
#
# Deliberately line-based and conservative: only plain `KEY=value` assignments,
# only when their quotes balance on that one line. A value continued across
# lines is skipped rather than half-copied, because half of one would leave an
# unterminated string and every later `. settings.sh` would fail.
merge_settings_keys() { # packaged current  -> prints added keys
  _ms_pkg="$1"; _ms_cur="$2"
  [ -f "$_ms_pkg" ] && [ -f "$_ms_cur" ] || return 0
  _ms_add="$_ms_cur.newkeys.$$"
  : > "$_ms_add"
  _ms_keys="$(awk -v out="$_ms_add" -v sq="'" '
    NR == FNR {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { k = line; sub(/=.*/, "", k); have[k] = 1 }
      next
    }
    /^[[:space:]]*#/ { blk = blk $0 "\n"; next }
    /^[[:space:]]*$/ { blk = ""; next }
    {
      if ($0 !~ /^[A-Za-z_][A-Za-z0-9_]*=/) { blk = ""; next }
      k = $0; sub(/=.*/, "", k)
      if (k in have || k in seen) { blk = ""; next }
      d = $0; nd = gsub(/"/, "", d)
      s = $0; ns = gsub(sq, "", s)
      if (nd % 2 == 1 || ns % 2 == 1) { blk = ""; next }
      seen[k] = 1
      printf "%s%s\n", blk, $0 >> out
      printf "%s ", k
      blk = ""
    }
  ' "$_ms_cur" "$_ms_pkg")"
  if [ -s "$_ms_add" ]; then
    {
      echo
      echo "# --- added by self-update: settings this version introduced ---"
      cat "$_ms_add"
    } >> "$_ms_cur"
  fi
  rm -f "$_ms_add"
  printf '%s' "$_ms_keys" | sed 's/[[:space:]]*$//'
}

# A hidden entry point so the merge can be tested on its own. It has to sit
# above the argument handling below, and it exits rather than falling through
# into an update with no package.
if [ "${1:-}" = "--merge-settings" ]; then
  merge_settings_keys "${2:-}" "${3:-}"
  exit 0
fi

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

# ---- identify the package ----
# Magic bytes first, but od is a BusyBox applet that some images leave out and
# hexdump is not guaranteed either. When neither is there the extractors are
# asked directly, so a perfectly good package is never rejected just because a
# tool used to look at it is missing.
magic="$(od -An -tx1 -N4 "$PKG" 2>/dev/null | tr -d ' \n')"
# `|| true` inside the substitution: a missing hexdump exits 127, and under
# `set -e` that status would end the script instead of falling through.
[ -n "$magic" ] || magic="$(hexdump -v -n 4 -e '/1 "%02x"' "$PKG" 2>/dev/null || true)"
KIND=""
case "$magic" in
  1f8b*)     KIND=targz ;;
  504b0304*) KIND=zip ;;
esac
if [ -z "$KIND" ]; then
  if tar tzf "$PKG" >/dev/null 2>&1; then
    KIND=targz
  elif command -v unzip >/dev/null 2>&1 && unzip -l "$PKG" >/dev/null 2>&1; then
    KIND=zip
  else
    size="$(wc -c < "$PKG" 2>/dev/null | tr -d ' ')"
    die "package is not a .tar.gz or .zip file (${size:-0} bytes, first bytes: ${magic:-unreadable})"
  fi
fi

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
ver_ok() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-SNAPSHOT)?$'; }
ver_num() { printf '%s' "$1" | sed 's/-SNAPSHOT$//' | awk -F. '{ printf "%d", $1 * 100000000 + $2 * 10000 + $3 }'; }
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
# make-package.sh ships the whole config/ directory, so a package built on a
# machine that has real config files carries them. proxy-pools.conf belongs here
# for the same reason wifi-socks.conf does, and more sharply: replacing it
# repoints every pooled SSID at the packager's proxies, and the slot numbers in
# /etc/sbproxy.assign go on pinning devices to rows that now mean something else.
PKG_SETTINGS=""
if [ -f "$NEW_ROOT/config/settings.sh" ] && [ -f "$SB_ROOT/config/settings.sh" ]; then
  PKG_SETTINGS="$STAGE/packaged-settings.sh"
  cp "$NEW_ROOT/config/settings.sh" "$PKG_SETTINGS"
fi
for keep in wifi-socks.conf proxy-pools.conf settings.sh; do
  if [ -f "$SB_ROOT/config/$keep" ]; then
    mkdir -p "$NEW_ROOT/config"
    cp "$SB_ROOT/config/$keep" "$NEW_ROOT/config/$keep"
  fi
done
if [ -n "$PKG_SETTINGS" ]; then
  new_keys="$(merge_settings_keys "$PKG_SETTINGS" "$NEW_ROOT/config/settings.sh")"
  [ -n "$new_keys" ] && log "settings.sh: added settings new in this version: $new_keys"
fi

# ---- overwrite SB_ROOT ----
cp -r "$NEW_ROOT"/. "$SB_ROOT"/ || die "failed to copy files into $SB_ROOT"
chmod 755 "$SB_ROOT"/scripts/*.sh "$SB_ROOT/agent/cgi/sbproxy" \
  "$SB_ROOT/agent/sbproxy-healthd" "$SB_ROOT/agent/install-agent.sh" 2>/dev/null || true

# ---- redeploy the agent/UI (skip components whose destinations do not exist) ----
CGI_DEST="${CGI_DEST:-/www/cgi-bin/sbproxy}"
UI_DEST="${UI_DEST:-/www/sbproxy/index.html}"
HEALTHD_DEST="${HEALTHD_DEST:-/usr/sbin/sbproxy-healthd}"
HEALTHD_INIT_DEST="${HEALTHD_INIT_DEST:-/etc/init.d/sbproxy-healthd}"
deploy() { # src dest
  [ -d "$(dirname "$2")" ] || return 0
  cp "$1" "$2" && chmod 755 "$2" 2>/dev/null || true
  log "deploy $2"
}
deploy "$SB_ROOT/agent/cgi/sbproxy" "$CGI_DEST"
if [ -d "$(dirname "$UI_DEST")" ]; then
  cp "$SB_ROOT/console/web/control-panel.html" "$UI_DEST"
  log "deploy $UI_DEST"
  # Offline Bootstrap and any other static files the UI references.
  if [ -d "$SB_ROOT/console/web/assets" ]; then
    mkdir -p "$(dirname "$UI_DEST")/assets"
    cp "$SB_ROOT/console/web/assets/"* "$(dirname "$UI_DEST")/assets/" 2>/dev/null \
      && log "deploy $(dirname "$UI_DEST")/assets" \
      || log "warning: no UI assets were deployed"
  fi
fi
WEBAUTH_DEST="${WEBAUTH_DEST:-/usr/sbin/sbproxy-webauth}"
if [ -f "$SB_ROOT/agent/sbproxy-webauth" ]; then
  deploy "$SB_ROOT/agent/sbproxy-webauth" "$WEBAUTH_DEST"
fi
deploy "$SB_ROOT/agent/sbproxy-healthd" "$HEALTHD_DEST"
deploy "$SB_ROOT/agent/init.d/sbproxy-healthd" "$HEALTHD_INIT_DEST"

# ---- migrate /etc/sbproxy/env ----
# The agent sources this file before running any script, so a value left in it
# overrides the shipped default forever. install-agent.sh used to write
# GATEWAY_EXPECTED_INTERFACE=wwan into every install, which now makes a
# wired-WAN router report a degraded gateway no matter how healthy it is.
#
# The line cannot be told apart from a deliberate choice, so it is judged by
# what the router actually does: while the uplink really is wwan the pin costs
# nothing and is kept, and it is only retired when it would otherwise keep
# calling a working uplink degraded. Retiring it comments the line out with its
# value intact, so enforcing wwan again is one edit away.
ENV_FILE="${ENV_FILE:-/etc/sbproxy/env}"
if [ -f "$ENV_FILE" ] && grep -q '^GATEWAY_EXPECTED_INTERFACE=wwan$' "$ENV_FILE"; then
  actual_uplink=""
  if [ -f "$SB_ROOT/scripts/gateway.sh" ]; then
    actual_uplink="$(GATEWAY_EXPECTED_INTERFACE='' GATEWAY_PROBE_TIMEOUT=2 \
      sh "$SB_ROOT/scripts/gateway.sh" 2>/dev/null | jq -r '.interface // ""' 2>/dev/null || true)"
  fi
  if [ "$actual_uplink" = "wwan" ]; then
    log "kept GATEWAY_EXPECTED_INTERFACE=wwan in $ENV_FILE: this router does leave through wwan"
  else
    ENV_TMP="$ENV_FILE.$$"
    if awk '
        /^GATEWAY_EXPECTED_INTERFACE=wwan$/ {
          print "# Commented out by sbproxy self-update: older installs wrote this line"
          print "# automatically, and this router does not leave through wwan, so it"
          print "# reported a healthy uplink as degraded. Uncomment to enforce it again."
          print "#" $0
          next
        }
        { print }
      ' "$ENV_FILE" > "$ENV_TMP" && cat "$ENV_TMP" > "$ENV_FILE"; then
      log "unpinned GATEWAY_EXPECTED_INTERFACE in $ENV_FILE (uplink is ${actual_uplink:-unknown}); any uplink is accepted again"
    else
      log "warning: could not migrate $ENV_FILE; the gateway check may stay pinned to wwan"
    fi
    rm -f "$ENV_TMP"
  fi
fi

if [ "${SB_NO_SERVICE:-0}" != 1 ]; then
  if [ -x "$HEALTHD_INIT_DEST" ]; then "$HEALTHD_INIT_DEST" restart >/dev/null 2>&1 || true; fi
  if [ -x /etc/init.d/uhttpd ]; then /etc/init.d/uhttpd reload >/dev/null 2>&1 || true; fi
fi

log "OK: $CUR_VER -> $NEW_VER"
log "config/wifi-socks.conf and settings.sh were preserved; backup: pre-update"
log "Wi-Fi was not reloaded — run apply when you are ready to apply configuration changes"
