#!/bin/sh
# Run the native Tkinter console from source on Linux/macOS.
set -eu
cd "$(dirname "$0")"
PY="${PYTHON:-python3}"
"$PY" -c 'import tkinter; print("Tkinter OK", tkinter.TkVersion)' \
  || { echo "Tkinter is missing — Debian/Ubuntu: sudo apt install python3-tk"; exit 1; }
exec "$PY" main.py
