#!/bin/bash
# Remove the LaunchAgent and stop the app. Leaves the .app bundle in place
# (delete it manually if you want it gone too). Does not touch the hooks.
set -uo pipefail

LABEL="com.claudeisland"
PLIST="$HOME/Library/LaunchAgents/com.claudeisland.plist"
APP="$HOME/Applications/ClaudeIsland.app"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
pkill -f 'Applications/ClaudeIsland.app' 2>/dev/null || true

echo "✅ autostart removed and app stopped."
echo "   app bundle left at: $APP  (rm -rf to fully remove)"
echo "   to also stop the monitoring hooks, delete the \"hooks\" block in ~/.claude/settings.json"
