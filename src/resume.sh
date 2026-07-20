#!/bin/bash
# resume.sh <agent> <session_id> [cwd] — reopen an ended session in a new
# terminal tab and resume the conversation (claude --resume / codex resume).
# iTerm gets a proper new tab; anything else falls back to Terminal.app.
agent="$1"; sid="$2"; cwd="${3:-$HOME}"
[ -n "$agent" ] && [ -n "$sid" ] || exit 0

# it's being resumed — drop it from the recent list (a SessionEnd re-adds it)
rm -f "$HOME/.harbar/recent/$agent-$sid.json"

# claude keys a session under the dir it was LAUNCHED in (`~/.claude/projects/
# <encoded-launch-dir>/<sid>.jsonl`), and `claude --resume <sid>` only finds it
# when run from that exact dir. the cwd captured by the hook can drift to a
# subdir the session cd'd into, which then fails to resume. so for claude,
# ignore the passed cwd and read the authoritative launch dir straight from the
# transcript (its first `cwd` line) — falling back to the passed cwd if not found.
if [ "$agent" = "claude" ]; then
  tx=$(find "$HOME/.claude/projects" -name "$sid.jsonl" -type f 2>/dev/null | head -1)
  if [ -n "$tx" ]; then
    real=$(python3 -c "
import json,sys
for line in open(sys.argv[1]):
    try:
        c=json.loads(line).get('cwd')
        if c: print(c); break
    except Exception: pass
" "$tx" 2>/dev/null)
    [ -n "$real" ] && cwd="$real"
  fi
fi

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
