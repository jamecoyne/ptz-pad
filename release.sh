#!/bin/zsh
# Builds, signs, notarizes and packages PTZ Pad for distribution outside the App Store.
#
#   ./release.sh              # full pipeline → dist/PTZPad-<version>.dmg (notarized + stapled)
#   ./release.sh --skip-notarize   # everything except notarize/staple
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
VERSION="1.2"
BUILD_NUMBER="3"
TEAM_ID="CM9NHRF538"
SIGN_ID="Developer ID Application: JAMES MICHAEL COYNE ($TEAM_ID)"
NOTARY_PROFILE="${NOTARY_PROFILE:-PTZPad-Notary}"

SKIP_NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
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
DMG="$WORK/$EXEC_NAME-$VERSION.dmg"
ENTITLEMENTS="$WORK/$EXEC_NAME.entitlements"
STAGING="$WORK/dmg-staging"

log() { print -P "%F{cyan}==>%f $*"; }

# Syphon isn't part of macOS; bundle the copy Package.swift linked against (TouchDesigner's
# or OBS's universal build, same search order).
SYPHON=""
for candidate in \
    /Applications/TouchDesigner.app/Contents/Frameworks/Syphon.framework \
    /Applications/OBS.app/Contents/Frameworks/Syphon.framework \
    /Library/Frameworks/Syphon.framework; do
    [ -d "$candidate" ] && SYPHON="$candidate" && break
done
if [ -z "$SYPHON" ]; then
    echo "error: Syphon.framework not found (install TouchDesigner or OBS, or put it in /Library/Frameworks)" >&2
    exit 1
fi

# ---------------------------------------------------------------- build
# `swift build --arch a --arch b` needs full Xcode (xcbuild); with Command Line Tools
# only, build each slice separately and merge them with lipo.
# Build outside ~/Documents: that folder is iCloud-synced, and the compiler hangs
# forever mmap'ing module-cache files that iCloud has evicted to the cloud.
log "Building universal release binary"
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
# Inside out: the bundled framework first, re-signed with our identity.
codesign --force --timestamp --options runtime --sign "$SIGN_ID" \
    "$APP/Contents/Frameworks/Syphon.framework"
codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_ID" \
    "$APP"

codesign --verify --strict --verbose=2 "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E 'Identifier|Authority=Developer|TeamIdentifier|flags'

# ---------------------------------------------------------------- dmg
log "Creating $DMG"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGING"

codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
codesign --verify --verbose=2 "$DMG"

# ---------------------------------------------------------------- notarize + staple
if (( SKIP_NOTARIZE )); then
    log "Skipping notarization (--skip-notarize)"
    mkdir -p "$DIST"; cp -f "$DMG" "$DIST/"
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
    mkdir -p "$DIST"; cp -f "$DMG" "$DIST/"
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

mkdir -p "$DIST"; cp -f "$DMG" "$DIST/"
echo
echo "Done: $DIST/$(basename "$DMG")"
