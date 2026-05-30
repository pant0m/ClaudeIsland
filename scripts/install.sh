#!/bin/bash
# Build a release .app, drop it in ~/Applications, and install a LaunchAgent so
# Cody starts on every login. Idempotent — safe to re-run after code changes.
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}"   # avoid multibyte mis-parsing under C locale
cd "$(dirname "$0")/.."   # repo root

APP="$HOME/Applications/ClaudeIsland.app"
PLIST="$HOME/Library/LaunchAgents/com.claudeisland.plist"
LABEL="com.claudeisland"
UID_NUM="$(id -u)"

echo "▸ building release…"
swift build -c release

echo "▸ assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$HOME/Applications"
cp .build/release/ClaudeIsland "$APP/Contents/MacOS/ClaudeIsland"
cp hooks/claude-island.py "$APP/Contents/Resources/claude-island.py"   # bundled for first-run setup

echo "▸ rendering icon (Cody)…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
.build/release/ClaudeIsland --icon "$ICONSET" 2>/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.claudeisland.app</string>
  <key>CFBundleName</key><string>ClaudeIsland</string>
  <key>CFBundleExecutable</key><string>ClaudeIsland</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLISTEOF

echo "▸ signing…"
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk '/[0-9A-F]{40}/ {print $2; exit}')"
if [ -n "${SIGN_ID:-}" ]; then
    # A real cert can pop a keychain prompt on first use; cap it so install never
    # hangs. Click “Always Allow” on that dialog once to make this non-interactive.
    codesign --force --timestamp=none --sign "$SIGN_ID" "$APP" & cs=$!
    ( sleep 20; kill -9 $cs 2>/dev/null ) & watch=$!
    if wait $cs 2>/dev/null; then
        kill $watch 2>/dev/null || true
        echo "  signed: $SIGN_ID"
    else
        echo "  ⚠ codesign stalled on the keychain — approve it with “Always Allow”; using ad-hoc for now"
        rm -rf "$APP/Contents/_CodeSignature"
        codesign --force -s - "$APP" && echo "  signed: ad-hoc"
    fi
else
    codesign --force -s - "$APP" && echo "  signed: ad-hoc (no Developer cert found)"
fi
codesign --verify --strict "$APP" && echo "  signature valid"

echo "▸ stopping any running instance…"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
pkill -f 'ClaudeIsland/.build' 2>/dev/null || true
pkill -f 'Applications/ClaudeIsland.app' 2>/dev/null || true
sleep 1

echo "▸ installing LaunchAgent ${PLIST}…"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<AGENTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/ClaudeIsland</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
AGENTEOF

launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl kickstart -k "gui/$UID_NUM/$LABEL"

echo "✅ installed — Cody now launches on every login."
echo "   uninstall anytime: scripts/uninstall.sh"
