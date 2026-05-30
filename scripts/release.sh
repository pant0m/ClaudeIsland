#!/bin/bash
# Build a distributable, ad-hoc-signed ClaudeIsland.app and zip it into dist/.
# (Ad-hoc so it's reproducible without any developer certificate; downloaders
# still need to clear quarantine — see the release notes.)
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}"
cd "$(dirname "$0")/.."

APP="dist/ClaudeIsland.app"
ZIP="dist/ClaudeIsland-macos.zip"

echo "▸ building release…"
swift build -c release

echo "▸ assembling ${APP}…"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeIsland "$APP/Contents/MacOS/ClaudeIsland"
cp hooks/claude-island.py "$APP/Contents/Resources/claude-island.py"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.claudeisland.app</string>
  <key>CFBundleName</key><string>ClaudeIsland</string>
  <key>CFBundleExecutable</key><string>ClaudeIsland</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

echo "▸ rendering icon…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
.build/release/ClaudeIsland --icon "$ICONSET" 2>/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "▸ ad-hoc signing…"
codesign --force -s - "$APP"
codesign --verify --strict "$APP" && echo "  signature valid"

echo "▸ zipping…"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✅ ${ZIP}"
