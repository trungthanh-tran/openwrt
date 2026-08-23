#!/bin/sh
set -eu
VERSION_ARG=""
PUSH=0
MILESTONE=0
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=1 ;;
    --create-milestone) MILESTONE=1 ;;
    --version=*) VERSION_ARG=${arg#--version=} ;;
    *) echo "Usage: $0 --version=X.Y.Z [--push] [--create-milestone]" >&2; exit 2 ;;
  esac
done
[ -n "$VERSION_ARG" ] || { echo '--version is required' >&2; exit 2; }
printf '%s' "$VERSION_ARG" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo 'invalid semver' >&2; exit 2; }
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"
[ "$(tr -d ' \r\n' < VERSION)" = "$VERSION_ARG" ] || { echo 'VERSION does not match release' >&2; exit 1; }
[ -z "$(git status --short)" ] || { echo 'working tree is not clean' >&2; exit 1; }
[ -z "$(git tag --list "$VERSION_ARG")" ] || { echo "tag already exists: $VERSION_ARG" >&2; exit 1; }
if [ "$MILESTONE" = 1 ]; then
  command -v gh >/dev/null 2>&1 || { echo 'gh CLI is required for --create-milestone' >&2; exit 1; }
  gh api "repos/{owner}/{repo}/milestones" -f "title=$VERSION_ARG" -f state=open
fi
git tag -a "$VERSION_ARG" -m "Release $VERSION_ARG"
if [ "$PUSH" = 1 ]; then
  git push origin main
  git push origin "$VERSION_ARG"
else
  echo 'Dry-run complete. Re-run with --push to push main and the tag.'
fi
