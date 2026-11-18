#!/bin/zsh
# Builds, signs, notarizes and packages PTZ Pad for distribution outside the App Store.
#
#   ./release.sh              # full pipeline → dist/PTZPad-<version>.dmg (notarized + stapled)
#   ./release.sh --skip-notarize   # everything except notarize/staple
#   ./release.sh --ad-hoc          # ad-hoc signed, not notarized: a test build with no certificate
#
# Version and build number come from version.env. Environment overrides (the release
# workflow sets these):
#   SIGN_IDENTITY          codesign identity, default the Developer ID below
#   NOTARY_PROFILE         notarytool keychain profile, default PTZPad-Notary
#   SYPHON_FRAMEWORK_DIR   folder holding Syphon.framework, searched before the installed apps
#
# One-time setup for notarization (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#       --apple-id "<your Apple ID email>" --team-id "$TEAM_ID" --password "<app-specific password>"
#   (Create the app-specific password at https://account.apple.com → Sign-In and Security.)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PTZ Pad"
EXEC_NAME="PTZPad"
BUNDLE_ID="com.hackerperformance.ptzpad"
source ./version.env
TEAM_ID="CM9NHRF538"
SIGN_ID="${SIGN_IDENTITY:-Developer ID Application: JAMES MICHAEL COYNE ($TEAM_ID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-PTZPad-Notary}"

SKIP_NOTARIZE=0
AD_HOC=0
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        --ad-hoc) AD_HOC=1; SKIP_NOTARIZE=1; SIGN_ID="-" ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# All build/sign work happens in $SCRATCH (outside iCloud); only the final DMG is
# copied into ./dist. iCloud adds com.apple.FinderInfo xattrs to files under
# ~/Documents, which codesign rejects as "detritus".
SCRATCH="${SCRATCH:-$HOME/Library/Caches/ptz-pad-build}"
WORK="$SCRATCH/dist"
DIST="dist"
APP="$WORK/$EXEC_NAME.app"
# Ad-hoc test builds get their own name so they never replace a real release's DMG.
SUFFIX=""
if (( AD_HOC )); then SUFFIX="-adhoc"; fi
DMG="$WORK/$EXEC_NAME-$VERSION$SUFFIX.dmg"
ENTITLEMENTS="$WORK/$EXEC_NAME.entitlements"
STAGING="$WORK/dmg-staging"

log() { print -P "%F{cyan}==>%f $*"; }

# Copies the DMG into ./dist next to a .sha256 for the release notes.
finish() {
    mkdir -p "$DIST"
    cp -f "$DMG" "$DIST/"
    (cd "$DIST" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
}

# Syphon isn't part of macOS; bundle the copy Package.swift linked against (TouchDesigner's
# or OBS's universal build, same search order).
SYPHON=""
for candidate in \
    ${SYPHON_FRAMEWORK_DIR:+"$SYPHON_FRAMEWORK_DIR/Syphon.framework"} \
    /Applications/TouchDesigner.app/Contents/Frameworks/Syphon.framework \
    /Applications/OBS.app/Contents/Frameworks/Syphon.framework \
    /Library/Frameworks/Syphon.framework; do
    [ -d "$candidate" ] && SYPHON="$candidate" && break
done
if [ -z "$SYPHON" ]; then
    echo "error: Syphon.framework not found (install TouchDesigner or OBS, put it in /Library/Frameworks," >&2
    echo "       or build it with scripts/build-syphon.sh and set SYPHON_FRAMEWORK_DIR)" >&2
    exit 1
fi

# ---------------------------------------------------------------- build
# `swift build --arch a --arch b` needs full Xcode (xcbuild); with Command Line Tools
# only, build each slice separately and merge them with lipo.
# Build outside ~/Documents: that folder is iCloud-synced, and the compiler hangs
# forever mmap'ing module-cache files that iCloud has evicted to the cloud.
log "Building $APP_NAME $VERSION ($BUILD_NUMBER), universal, Syphon from $SYPHON"
export SYPHON_FRAMEWORK_DIR="${SYPHON:h}"   # Package.swift compiles against the same copy
MIN_OS="13.0"
swift build -c release --scratch-path "$SCRATCH" --triple "arm64-apple-macosx$MIN_OS"
swift build -c release --scratch-path "$SCRATCH" --triple "x86_64-apple-macosx$MIN_OS"
rm -rf "$WORK"; mkdir -p "$WORK"
BIN="$WORK/$EXEC_NAME-universal"
lipo -create -output "$BIN" \
    "$SCRATCH/arm64-apple-macosx/release/$EXEC_NAME" \
    "$SCRATCH/x86_64-apple-macosx/release/$EXEC_NAME"
lipo -info "$BIN"

# ---------------------------------------------------------------- bundle
log "Assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
mv "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
cp -R "$SYPHON" "$APP/Contents/Frameworks/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © $(date +%Y) James Coyne. All rights reserved.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>GCSupportsControllerUserInteraction</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>PTZ Pad sends VISCA commands to your PTZ camera and receives its NDI video over the local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_ndi._tcp</string></array>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------- sign
# Hardened runtime is required for notarization. No sandbox. The one entitlement turns off
# library validation: libndi.dylib is dlopen'd from the NDI runtime install and is signed
# by NDI's team, which the hardened runtime would otherwise refuse to load.
cat > "$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
ENT

log "Signing with: $SIGN_ID"
xattr -cr "$APP"
# Ad-hoc signatures can't carry a secure timestamp.
if (( AD_HOC )); then TIMESTAMP=(); else TIMESTAMP=(--timestamp); fi
# Inside out: the bundled framework first, re-signed with our identity.
codesign --force "${TIMESTAMP[@]}" --options runtime --sign "$SIGN_ID" \
    "$APP/Contents/Frameworks/Syphon.framework"
codesign --force "${TIMESTAMP[@]}" --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_ID" \
    "$APP"

codesign --verify --strict --verbose=2 "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E 'Identifier|Authority=Developer|TeamIdentifier|flags' || true

# ---------------------------------------------------------------- dmg
log "Creating $DMG"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGING"

codesign --force "${TIMESTAMP[@]}" --sign "$SIGN_ID" "$DMG"
codesign --verify --verbose=2 "$DMG"

# ---------------------------------------------------------------- notarize + staple
if (( SKIP_NOTARIZE )); then
    log "Skipping notarization"
    finish
    echo "Unnotarized: $DIST/$(basename "$DMG")"
    exit 0
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<MSG

No notarization credentials stored under keychain profile "$NOTARY_PROFILE".
Create an app-specific password at https://account.apple.com (Sign-In and Security),
then run once:

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id "<your Apple ID email>" --team-id "$TEAM_ID" --password "<app-specific password>"

and re-run ./release.sh. The signed but unnotarized DMG is at: $DIST/$(basename "$DMG")
MSG
    finish
    exit 3
fi

log "Submitting $DMG for notarization (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

log "Stapling"
xcrun stapler staple "$DMG"
# The app inside the DMG can't be stapled in place; staple the loose copy too so
# a bare .app zip would also pass offline.
xcrun stapler staple "$APP"

# ---------------------------------------------------------------- verify like Gatekeeper
log "Gatekeeper assessment"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP"

finish
echo
echo "Done: $DIST/$(basename "$DMG")"
