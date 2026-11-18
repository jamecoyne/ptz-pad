#!/bin/zsh
# Releases the version in version.env from this Mac: builds, signs and notarizes the DMG
# with ./release.sh, tags the commit v<version>, pushes the tag and creates a GitHub
# release with the DMG and its .sha256.
#
#   scripts/publish-release.sh            # draft release, to check and publish on GitHub
#   scripts/publish-release.sh --publish  # published straight away
#
# Bump first with scripts/bump-version.sh. Needs the Developer ID certificate and the
# PTZPad-Notary profile in the keychain (README: Releasing from this Mac) and `gh`
# signed in with access to the repository.
set -euo pipefail
cd "$(dirname "$0")/.."

DRAFT=(--draft)
for arg in "$@"; do
    case "$arg" in
        --publish) DRAFT=() ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

source ./version.env
TAG="v$VERSION"
DMG="dist/PTZPad-$VERSION.dmg"
log() { print -P "%F{cyan}==>%f $*"; }

# The release must be exactly a commit that's on GitHub.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "error: commit or stash your changes first" >&2; exit 1
fi
BRANCH="$(git branch --show-current)"
git fetch -q origin "$BRANCH"
if [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$BRANCH")" ]; then
    echo "error: $BRANCH isn't the same as origin/$BRANCH; push or pull first" >&2; exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "error: GitHub already has a release $TAG; bump with scripts/bump-version.sh" >&2; exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null &&
   [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
    echo "error: tag $TAG points at another commit" >&2; exit 1
fi

log "Building, signing and notarizing $VERSION ($BUILD_NUMBER)"
./release.sh

log "Tagging $TAG"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "PTZ Pad $VERSION"
git push -q origin "$TAG"

log "Creating the GitHub release"
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
cat > "$NOTES" <<NOTES
PTZ Pad $VERSION (build $BUILD_NUMBER) for macOS 13 or later, Apple silicon and Intel.
Signed with Developer ID and notarized by Apple.

Needs [NDI Tools](https://ndi.video/tools/) installed to receive video.

SHA-256 \`$(cut -d' ' -f1 "$DMG.sha256")\`
NOTES
gh release create "$TAG" "$DMG" "$DMG.sha256" "${DRAFT[@]}" --verify-tag \
    --title "PTZ Pad $VERSION" --notes-file "$NOTES"
