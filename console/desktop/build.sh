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

# The POSIX bootloader does NOT expand "~" or "$HOME" in --runtime-tmpdir, so a
# per-user runtime path cannot be baked in here; the default (/tmp) is used
# unless an absolute path is supplied for a fixed deployment, e.g.
#   SBPROXY_RUNTIME_TMPDIR=/opt/sbproxy/runtime sh build.sh
# The app's own config/logs/cache are isolated regardless (see resolve_app_home).
set -- --noconfirm --clean --onefile --windowed --name sbproxy-console
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
