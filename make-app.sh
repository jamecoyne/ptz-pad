#!/bin/zsh
# Builds PTZPad in release mode and wraps it in a double-clickable .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

# Build outside this folder: it is iCloud-synced, and the compiler hangs on module-cache
# files iCloud has evicted (same scratch path release.sh uses).
SCRATCH="${SCRATCH:-$HOME/Library/Caches/ptz-pad-build}"
swift build -c release --scratch-path "$SCRATCH"

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

APP="build/PTZPad.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$SCRATCH/release/PTZPad" "$APP/Contents/MacOS/PTZPad"
cp -R "$SYPHON" "$APP/Contents/Frameworks/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PTZ Pad</string>
    <key>CFBundleDisplayName</key><string>PTZ Pad</string>
    <key>CFBundleIdentifier</key><string>com.hackerperformance.ptzpad</string>
    <key>CFBundleExecutable</key><string>PTZPad</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>CFBundleShortVersionString</key><string>1.2</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
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

xattr -cr "$APP"          # iCloud's FinderInfo xattrs make codesign refuse the bundle
codesign --force --sign - "$APP/Contents/Frameworks/Syphon.framework" >/dev/null 2>&1 || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
echo "Run it with:  open \"$APP\""
