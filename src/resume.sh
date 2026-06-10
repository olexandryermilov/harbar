#!/bin/bash
# resume.sh <agent> <session_id> [cwd] — reopen an ended session in a new
# terminal tab and resume the conversation (claude --resume / codex resume).
# iTerm gets a proper new tab; anything else falls back to Terminal.app.
agent="$1"; sid="$2"; cwd="${3:-$HOME}"
[ -n "$agent" ] && [ -n "$sid" ] || exit 0

# it's being resumed — drop it from the recent list (a SessionEnd re-adds it)
rm -f "$HOME/.harbar/recent/$agent-$sid.json"

if [ "$agent" = "codex" ]; then cmd="codex resume $sid"; else cmd="claude --resume $sid"; fi
full="cd '$cwd' && $cmd"

if [ -d "/Applications/iTerm.app" ] || [ -d "$HOME/Applications/iTerm.app" ]; then
  osascript >/dev/null 2>&1 <<EOF
tell application "iTerm"
  activate
  if (count of windows) = 0 then
    create window with default profile
  else
    tell current window to create tab with default profile
  end if
  tell current session of current window to write text "$full"
end tell
EOF
else
  osascript >/dev/null 2>&1 \
    -e 'tell application "Terminal" to activate' \
    -e "tell application \"Terminal\" to do script \"${full//\"/\\\"}\""
fi
