#!/bin/bash
# SPDX-License-Identifier: MIT
# focus.sh <agent> <session_id> — bring a session's terminal/IDE to the front.
# iTerm: selects the exact tab (only terminal that exposes tabs to AppleScript).
# everything else (VSCode, Cursor, JetBrains, Terminal, …): raises the app and,
#   best-effort, the window whose title matches the project. integrated-terminal
#   TABS aren't scriptable on macOS, so this lands on the project window, not the
#   exact split. needs a one-time Accessibility grant for the caller.
agent="$1"; sid="$2"
f="$HOME/.harbar/sessions/$agent-$sid.json"
[ -f "$f" ] || exit 0

field() { /usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],'') or '')" "$f" "$1"; }
term=$(field terminal)
app=$(field focus_app)
proj=$(field project)
iterm=$(field iterm_session_id)
uuid="${iterm##*:}"   # strip the w0t1p0: prefix -> the UUID iTerm's AppleScript 'id' exposes

if [ "$term" = "iTerm" ]; then
  /usr/bin/osascript <<EOF
tell application "iTerm2"
  activate
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) is equal to "$uuid" then
          select w
          select t
          select s
          return
        end if
      end repeat
    end repeat
  end repeat
end tell
EOF
  exit 0
fi

# raise the editor/terminal app, then best-effort raise its project window
[ -n "$app" ] && /usr/bin/open -a "$app" 2>/dev/null || /usr/bin/open -a "Terminal" 2>/dev/null
[ -n "$proj" ] && { sleep 0.3; /usr/bin/osascript <<EOF 2>/dev/null ; }
tell application "System Events"
  set fp to first process whose frontmost is true
  repeat with w in windows of fp
    try
      if name of w contains "$proj" then
        perform action "AXRaise" of w
        return
      end if
    end try
  end repeat
end tell
EOF
