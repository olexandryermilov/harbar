#!/usr/bin/env bash
# remove harbar. leaves config backups (*.harbar-bak-*) in place.
set -euo pipefail
HARBAR="$HOME/.harbar"
APP="$HOME/Applications/Harbar.app"
LABEL="com.harbar.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> stopping Harbar"
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
osascript -e 'quit app "Harbar"' >/dev/null 2>&1 || true
rm -f "$PLIST"
rm -rf "$APP"

echo "==> removing harbar hooks from configs (your other hooks are kept)"
for f in "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json"; do
  [ -e "$f" ] && python3 "$HARBAR/merge-hooks.py" "$f" remove || true
done

echo "==> removing $HARBAR"
rm -rf "$HARBAR"
echo "done."
