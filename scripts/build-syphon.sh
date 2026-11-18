#!/bin/zsh
# Builds a universal (arm64 + x86_64) Syphon.framework from source, for machines without
# TouchDesigner or OBS to borrow it from — the release workflow's runners. Syphon's own
# SDK download (SDK 5, 2019) is Intel-only and predates SyphonServerBase, which
# SyphonPublisher uses, so it can't stand in.
#
#   scripts/build-syphon.sh [OUT_DIR]     # → OUT_DIR/Syphon.framework (default build/syphon)
#
# Then point the builds at it:  SYPHON_FRAMEWORK_DIR=OUT_DIR ./release.sh
# Needs full Xcode (xcodebuild), not just the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

# Pinned so a release builds against the Syphon it was tested with: the last commit
# before 39e3138 renamed -copySurfaceForWidth:… (which SyphonPublisher calls, and which
# TouchDesigner's and OBS's copies still have) to -newSurfaceForWidth:…. Moving past it
# means switching SyphonPublisher to newSurface(forWidth:height:options:).
SYPHON_REPO="https://github.com/Syphon/Syphon-Framework.git"
SYPHON_COMMIT="07b9f10b1ccc53a06fd3b17d6492f80640f4084f"
MIN_OS="13.0"

OUT="${1:-build/syphon}"
OUT="${OUT:A}"
WORK="${TMPDIR:-/tmp}/ptz-pad-syphon-$SYPHON_COMMIT"

# The marker sits beside the framework, not in it: codesign rejects stray files in a
# framework's root.
MARKER="$OUT/Syphon.commit"
if [ -d "$OUT/Syphon.framework" ] && [ -f "$MARKER" ] && [ "$(<"$MARKER")" = "$SYPHON_COMMIT" ]; then
    echo "Syphon $SYPHON_COMMIT already built: $OUT/Syphon.framework"
    exit 0
fi

rm -rf "$WORK"
mkdir -p "$WORK"
git -C "$WORK" init -q src
git -C "$WORK/src" fetch -q --depth 1 "$SYPHON_REPO" "$SYPHON_COMMIT"
git -C "$WORK/src" checkout -q FETCH_HEAD

# The framework's install name is @rpath/Syphon.framework/…, which the app's
# @executable_path/../Frameworks rpath resolves to the bundled copy.
xcodebuild -quiet \
    -project "$WORK/src/Syphon.xcodeproj" \
    -scheme Syphon \
    -configuration Release \
    -derivedDataPath "$WORK/derived" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET="$MIN_OS" \
    CODE_SIGNING_ALLOWED=NO \
    CONFIGURATION_BUILD_DIR="$WORK/out" \
    build

mkdir -p "$OUT"
rm -rf "$OUT/Syphon.framework"
ditto "$WORK/out/Syphon.framework" "$OUT/Syphon.framework"
print -r -- "$SYPHON_COMMIT" > "$MARKER"
rm -rf "$WORK"

lipo -info "$OUT/Syphon.framework/Syphon"
echo "Built $OUT/Syphon.framework"
