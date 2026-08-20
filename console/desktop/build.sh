#!/bin/sh
# Build the native Tkinter controller on Linux/macOS (no HTML and no WebView).
# Output: dist/sbproxy-console (single-file executable for the build platform).
# PyInstaller does not cross-compile — build on Windows with build.ps1 for the
# .exe and on Linux with this script for the Linux binary.
set -eu

cd "$(dirname "$0")"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "Cần python3 (hoặc đặt PYTHON=...)"; exit 1; }

"$PY" -c 'import tkinter; print("Tkinter OK", tkinter.TkVersion)' \
  || { echo "Thiếu Tkinter — Debian/Ubuntu: sudo apt install python3-tk"; exit 1; }
"$PY" -c 'import PyInstaller; print("PyInstaller OK", PyInstaller.__version__)' 2>/dev/null \
  || { echo "Cài dependency build lần đầu..."; "$PY" -m pip install -r requirements.txt; }

"$PY" -m PyInstaller --noconfirm --clean --onefile --windowed \
  --name sbproxy-console \
  main.py

OUT="dist/sbproxy-console"
[ -f "$OUT" ] || { echo "Build failed: output not found at $OUT"; exit 1; }
echo "BUILD COMPLETE (native): $OUT"
echo "The app calls the Agent API directly and uses no HTML/WebView."
