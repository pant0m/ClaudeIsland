#!/bin/bash
# One-command setup for a fresh clone: install the hook producer, wire it into
# Claude Code's settings.json, then build + install the menu-bar app + autostart.
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}"
cd "$(dirname "$0")/.."

echo "▸ installing hook producer to ~/.claude/island/ …"
mkdir -p "$HOME/.claude/island"
cp hooks/claude-island.py "$HOME/.claude/island/claude-island.py"
chmod +x "$HOME/.claude/island/claude-island.py"

echo "▸ wiring hooks into ~/.claude/settings.json …"
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {}
hooks = d.setdefault("hooks", {})
cmd = "$HOME/.claude/island/claude-island.py"
events = ["SessionStart", "UserPromptSubmit", "PreToolUse",
          "PostToolUse", "Notification", "Stop", "SessionEnd"]
for e in events:
    arr = hooks.setdefault(e, [])
    # idempotent: skip if our hook is already wired for this event
    if any("claude-island.py" in (h.get("command", ""))
           for g in arr for h in g.get("hooks", [])):
        continue
    arr.append({"hooks": [{"type": "command", "command": f"{cmd} {e}"}]})
os.makedirs(os.path.dirname(p), exist_ok=True)
with open(p, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print("  ok")
PY

echo "▸ building + installing the app (icon · sign · autostart) …"
scripts/install.sh

echo ""
echo "✅ done — Cody is in the notch and launches on login."
echo "   customise the pet: copy config.example.json to ~/.claude/island/config.json"
echo "   uninstall: scripts/uninstall.sh   (hooks stay; remove the block in ~/.claude/settings.json)"
