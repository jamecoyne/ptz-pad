#!/bin/zsh
# Builds PTZPad in release mode and wraps it in a double-clickable .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/PTZPad.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/PTZPad" "$APP/Contents/MacOS/PTZPad"

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
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>GCSupportsControllerUserInteraction</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
echo "Run it with:  open \"$APP\""
