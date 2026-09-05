#!/bin/sh
# Build the native Tkinter controller on Linux/macOS (no HTML and no WebView).
# Output: dist/sbproxy-console (single-file executable for the build platform).
# PyInstaller does not cross-compile — build on Windows with build.ps1 for the
# .exe and on Linux with this script for the Linux binary.
set -eu

cd "$(dirname "$0")"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "python3 is required (or set PYTHON=...)"; exit 1; }

"$PY" -c 'import tkinter; print("Tkinter OK", tkinter.TkVersion)' \
  || { echo "Tkinter is missing — Debian/Ubuntu: sudo apt install python3-tk"; exit 1; }
"$PY" -c 'import PyInstaller; print("PyInstaller OK", PyInstaller.__version__)' 2>/dev/null \
  || { echo "Installing build dependencies for the first time..."; "$PY" -m pip install -r requirements.txt; }

# Embed the router-side package so the binary alone can provision a freshly
# flashed router (Post-flash setup) without a repository checkout. The package
# is built outside the repo so it never ends up inside its own payload.
REPO_DIR="$(cd ../.. && pwd)"
VERSION="$(tr -d ' \r\n' < "$REPO_DIR/VERSION")"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-SNAPSHOT)?$' \
  || { echo "Invalid VERSION: '$VERSION'"; exit 1; }
PAYLOAD_DIR="$(mktemp -d)"
trap 'rm -rf "$PAYLOAD_DIR"' EXIT INT TERM
PAYLOAD="$PAYLOAD_DIR/sbproxy-update-$VERSION.tar.gz"
tar -czf "$PAYLOAD" -C "$REPO_DIR" --exclude=node_modules --exclude=__pycache__ --exclude=dist --exclude=build \
  README.md VERSION agent config console docs etc scripts \
  || { echo "Build failed: tar could not create the router payload"; exit 1; }
echo "Router payload for Post-flash setup: $PAYLOAD"

# The POSIX bootloader does NOT expand "~" or "$HOME" in --runtime-tmpdir, so a
# per-user runtime path cannot be baked in here; the default (/tmp) is used
# unless an absolute path is supplied for a fixed deployment, e.g.
#   SBPROXY_RUNTIME_TMPDIR=/opt/sbproxy/runtime sh build.sh
# The app's own config/logs/cache are isolated regardless (see resolve_app_home).
set -- --noconfirm --clean --onefile --windowed --name sbproxy-console \
  --add-data "$PAYLOAD:payload"
if [ -n "${SBPROXY_RUNTIME_TMPDIR:-}" ]; then
  case "$SBPROXY_RUNTIME_TMPDIR" in
    /*) ;;
    *) echo "SBPROXY_RUNTIME_TMPDIR must be an absolute path"; exit 1 ;;
  esac
  set -- "$@" --runtime-tmpdir "$SBPROXY_RUNTIME_TMPDIR"
  echo "The runtime will be extracted to: $SBPROXY_RUNTIME_TMPDIR"
fi
"$PY" -m PyInstaller "$@" main.py

OUT="dist/sbproxy-console"
[ -f "$OUT" ] || { echo "Build failed: output not found at $OUT"; exit 1; }
echo "BUILD COMPLETE (native): $OUT"
echo "The app calls the Agent API directly and uses no HTML/WebView."
echo "Post-flash setup provisions a router from the embedded v$VERSION package."
