#!/bin/bash
# Builds ClaudeStats.app. `./build.sh install` also installs it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ClaudeStats.app"
VERSION="1.0"

swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/ClaudeStats "$APP/Contents/MacOS/ClaudeStats"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ClaudeStats</string>
    <key>CFBundleDisplayName</key><string>Claude Stats</string>
    <key>CFBundleIdentifier</key><string>com.urion.claudestats</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>ClaudeStats</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# A stable signature is what lets macOS remember Always Allow for the keychain.
IDENTITY="ClaudeStats Self-Signed"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "No signing certificate. Run ./scripts/make-signing-cert.sh first."
    echo "Falling back to ad-hoc signing: macOS will ask for keychain access every launch."
    codesign --force --sign - "$APP"
fi
echo "Built: $APP"

if [ "${1:-}" = "install" ]; then
    pkill -x ClaudeStats 2>/dev/null || true
    rm -rf /Applications/ClaudeStats.app
    cp -R "$APP" /Applications/ClaudeStats.app
    open /Applications/ClaudeStats.app
    echo "Installed to /Applications and launched."
fi
