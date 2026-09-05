#!/bin/sh
# Build one portable Linux deployment bundle (.tar.gz).
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(cd "$HERE/../.." && pwd)"
OUT_DIR="${1:-$REPO_DIR/dist/release}"
VERSION="$(tr -d ' \r\n' < "$REPO_DIR/VERSION")"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-SNAPSHOT)?$' \
  || { echo "Invalid VERSION: '$VERSION'" >&2; exit 1; }

case "$(uname -m)" in
  x86_64|amd64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) ARCH="$(uname -m | tr -c 'A-Za-z0-9._-' '_')" ;;
esac
BUNDLE_NAME="sbproxy-web-deploy-$VERSION-linux-$ARCH"
STAGE_ROOT="$(mktemp -d)"
BUNDLE_DIR="$STAGE_ROOT/$BUNDLE_NAME"
trap 'rm -rf "$STAGE_ROOT"' EXIT INT TERM
mkdir -p "$BUNDLE_DIR" "$OUT_DIR"

sh "$HERE/build.sh"
"$HERE/dist/sbproxy-web-deployer" --self-test
cp "$HERE/dist/sbproxy-web-deployer" "$BUNDLE_DIR/"
cp "$HERE/PACKAGE-README.md" "$BUNDLE_DIR/README.md"
cp "$REPO_DIR/docs/WEB-DEPLOY.md" "$BUNDLE_DIR/"
cp "$REPO_DIR/LICENSE" "$BUNDLE_DIR/"
sh "$REPO_DIR/pc/make-package.sh" "$BUNDLE_DIR"
(
  cd "$BUNDLE_DIR"
  sha256sum ./* > SHA256SUMS
)

ARCHIVE="$OUT_DIR/$BUNDLE_NAME.tar.gz"
tar -czf "$ARCHIVE" -C "$STAGE_ROOT" "$BUNDLE_NAME"
echo "PACKAGE COMPLETE: $ARCHIVE"
