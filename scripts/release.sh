#!/bin/sh
set -eu
PUSH=0
RUN_TESTS=1
WAIT=0
RELEASE_TYPE=patch
while [ "$#" -gt 0 ]; do
  arg=$1
  case "$arg" in
    --push) PUSH=1 ;;
    --skip-tests) RUN_TESTS=0 ;;
    --wait) WAIT=1 ;;
    --release-type=patch|--release-type=minor|--release-type=major)
      RELEASE_TYPE=${arg#*=} ;;
    --release-type)
      [ "$#" -ge 2 ] || { echo '--release-type requires patch, minor or major' >&2; exit 2; }
      RELEASE_TYPE=$2
      case "$RELEASE_TYPE" in patch|minor|major) ;; *) echo "invalid release type: $RELEASE_TYPE" >&2; exit 2;; esac
      shift ;;
    *) echo "Usage: $0 [--push] [--skip-tests] [--wait] [--release-type patch|minor|major]" >&2; exit 2 ;;
  esac
  shift
done
ROOT="$(cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SOURCE=$(tr -d ' \r\n' < VERSION)
case "$SOURCE" in *-SNAPSHOT) RELEASE=${SOURCE%-SNAPSHOT};; *) echo "VERSION must end in -SNAPSHOT: $SOURCE" >&2; exit 1;; esac
printf '%s' "$RELEASE" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo 'invalid semver' >&2; exit 1; }
IFS=. read -r MAJOR MINOR PATCH <<EOF
$RELEASE
EOF
case "$RELEASE_TYPE" in
  patch) NEXT="$MAJOR.$MINOR.$((PATCH + 1))-SNAPSHOT" ;;
  minor) NEXT="$MAJOR.$((MINOR + 1)).0-SNAPSHOT" ;;
  major) NEXT="$((MAJOR + 1)).0.0-SNAPSHOT" ;;
  *) echo "invalid release type: $RELEASE_TYPE" >&2; exit 2 ;;
esac
git diff --quiet && git diff --cached --quiet || {
  echo 'tracked working-tree changes are not committed' >&2
  exit 1
}
UNTRACKED=$(git status --porcelain | sed -n '/^?? /p')
[ -z "$UNTRACKED" ] || echo "warning: ignoring untracked files: $UNTRACKED" >&2
[ -z "$(git tag --list "$RELEASE")" ] || { echo "tag already exists: $RELEASE" >&2; exit 1; }
if [ "$RUN_TESTS" = 1 ]; then
  echo "Running the full test suite before releasing $RELEASE..."
  sh tests/run-all.sh || { echo "tests failed; release aborted" >&2; exit 1; }
  echo "Tests passed."
else
  echo "WARNING: skipping tests at the operator's request" >&2
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
  echo "Pushed $RELEASE; GitHub Actions is building the release."
  if [ "$WAIT" = 1 ]; then
    command -v gh >/dev/null 2>&1 || { echo 'gh is required for --wait' >&2; exit 1; }
    RUN_ID=""
    TAG_SHA=$(git rev-list -n 1 "$RELEASE")
    for _ in $(seq 1 30); do
      RUN_ID=$(gh run list --workflow deploy-release.yml --limit 20 \
        --json databaseId,headSha --jq ".[] | select(.headSha == \"$TAG_SHA\") | .databaseId" | head -n 1)
      [ -n "$RUN_ID" ] && break
      sleep 2
    done
    [ -n "$RUN_ID" ] || { echo "could not find the GitHub Actions run for $RELEASE" >&2; exit 1; }
    gh run watch "$RUN_ID" --exit-status
    gh release view "$RELEASE" --json tagName,isDraft,isPrerelease,assets
    echo "Release $RELEASE is published."
  fi
else
  echo "Prepared $RELEASE_TYPE release $RELEASE and next version $NEXT locally. Re-run with --push to push."
  echo "Use --release-type patch|minor|major with --push --wait to publish."
fi
