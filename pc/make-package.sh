#!/bin/sh
# make-package.sh — build an update package for upload through the console UI
# (POST ?action=update) or for archiving a release.
#
# Usage: pc/make-package.sh [output-dir]
#
# Output: <output-dir|dist>/sbproxy-update-<version>.tar.gz
# The package carries the same file list as pc/update.sh and always includes
# VERSION so scripts/self-update.sh can enforce its downgrade guard.
set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$REPO_DIR/dist}"
VER="$(tr -d ' \r\n' < "$REPO_DIR/VERSION")"
printf '%s' "$VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-SNAPSHOT)?$' \
  || { echo "Invalid VERSION: '$VER'" >&2; exit 1; }

mkdir -p "$OUT_DIR"
PKG="$OUT_DIR/sbproxy-update-$VER.tar.gz"
tar czf "$PKG" -C "$REPO_DIR" --exclude=node_modules --exclude=dist --exclude=build --exclude=__pycache__ \
  README.md VERSION agent config console docs etc scripts

echo "Created: $PKG"
echo "Upload through the UI: Connect router -> Update -> select this file."
