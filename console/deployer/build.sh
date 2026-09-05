#!/bin/sh
# Build the focused sbproxy Web installer/updater for Linux.
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(cd "$HERE/../.." && pwd)"
DESKTOP_DIR="$REPO_DIR/console/desktop"
PY="${PYTHON:-python3}"

cd "$HERE"
command -v "$PY" >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
"$PY" -c 'import tkinter; import PyInstaller; print("Build dependencies OK")' 2>/dev/null || {
  echo "Installing build dependencies..."
  "$PY" -m pip install -r requirements.txt
}

VERSION="$(tr -d ' \r\n' < "$REPO_DIR/VERSION")"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-SNAPSHOT)?$' \
  || { echo "Invalid VERSION: '$VERSION'" >&2; exit 1; }

PAYLOAD_DIR="$(mktemp -d)"
trap 'rm -rf "$PAYLOAD_DIR"' EXIT INT TERM
PAYLOAD="$PAYLOAD_DIR/sbproxy-update-$VERSION.tar.gz"
tar -czf "$PAYLOAD" -C "$REPO_DIR" \
  --exclude=node_modules --exclude=__pycache__ --exclude=dist --exclude=build \
  README.md VERSION agent config console docs etc scripts

"$PY" -m PyInstaller --noconfirm --clean --onefile --windowed \
  --name sbproxy-web-deployer \
  --specpath "$PAYLOAD_DIR" \
  --paths "$DESKTOP_DIR" \
  --add-data "$PAYLOAD:payload" \
  web_deployer.py

OUT="$HERE/dist/sbproxy-web-deployer"
[ -f "$OUT" ] || { echo "Output not found: $OUT" >&2; exit 1; }
chmod 755 "$OUT"
echo "BUILD COMPLETE: $OUT"
