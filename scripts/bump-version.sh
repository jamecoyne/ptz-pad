#!/bin/zsh
# Sets a new version in version.env, bumps the build number, commits and tags it.
#
#   scripts/bump-version.sh 1.3      # → "Bump version to 1.3 (build 4)", tag v1.3
#
# Nothing is pushed. To release:  git push origin main && scripts/publish-release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NEW="${1:?usage: scripts/bump-version.sh <version, e.g. 1.3>}"
NEW="${NEW#v}"
[[ "$NEW" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || { echo "error: '$NEW' is not a version like 1.3 or 1.3.1" >&2; exit 2; }

if [ -n "$(git status --porcelain)" ]; then
    echo "error: commit or stash your changes first" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/v$NEW" >/dev/null; then
    echo "error: tag v$NEW already exists" >&2
    exit 1
fi

source ./version.env
BUILD=$(( BUILD_NUMBER + 1 ))
sed -i '' -e "s/^VERSION=.*/VERSION=\"$NEW\"/" -e "s/^BUILD_NUMBER=.*/BUILD_NUMBER=\"$BUILD\"/" version.env

git add version.env
git commit -q -m "Bump version to $NEW (build $BUILD)"
git tag -a "v$NEW" -m "PTZ Pad $NEW"
echo "Committed and tagged v$NEW (build $BUILD). Release it with:"
echo "  git push origin $(git branch --show-current) && scripts/publish-release.sh"
