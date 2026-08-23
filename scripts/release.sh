#!/bin/sh
set -eu
PUSH=0
MILESTONE=0
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=1 ;;
    --create-milestone) MILESTONE=1 ;;
    *) echo "Usage: $0 [--push] [--create-milestone]" >&2; exit 2 ;;
  esac
done
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"
SOURCE=$(tr -d ' \r\n' < VERSION)
case "$SOURCE" in *-SNAPSHOT) RELEASE=${SOURCE%-SNAPSHOT};; *) echo "VERSION must end in -SNAPSHOT: $SOURCE" >&2; exit 1;; esac
printf '%s' "$RELEASE" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo 'invalid semver' >&2; exit 1; }
IFS=. read -r MAJOR MINOR PATCH <<EOF
$RELEASE
EOF
NEXT="$MAJOR.$MINOR.$((PATCH + 1))-SNAPSHOT"
[ -z "$(git status --short)" ] || { echo 'working tree is not clean' >&2; exit 1; }
[ -z "$(git tag --list "$RELEASE")" ] || { echo "tag already exists: $RELEASE" >&2; exit 1; }
if [ "$MILESTONE" = 1 ]; then
  command -v gh >/dev/null 2>&1 || { echo 'gh CLI is required for --create-milestone' >&2; exit 1; }
  gh api "repos/{owner}/{repo}/milestones" -f "title=$RELEASE" -f state=open
  gh api "repos/{owner}/{repo}/milestones" -f "title=$NEXT" -f state=open
fi
for file in VERSION console/desktop/main.py console/web/control-panel.html; do sed -i "s/$SOURCE/$RELEASE/g" "$file"; done
git add VERSION console/desktop/main.py console/web/control-panel.html
git commit -m "release: $RELEASE"
git tag -a "$RELEASE" -m "Release $RELEASE"
for file in VERSION console/desktop/main.py console/web/control-panel.html; do sed -i "s/$RELEASE/$NEXT/g" "$file"; done
git add VERSION console/desktop/main.py console/web/control-panel.html
git commit -m "chore: start $NEXT development"
if [ "$PUSH" = 1 ]; then
  git push origin main
  git push origin "$RELEASE"
else
  echo "Prepared release $RELEASE and next version $NEXT locally. Re-run with --push to push."
fi
