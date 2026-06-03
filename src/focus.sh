#!/bin/bash
# SPDX-License-Identifier: MIT
# focus.sh <agent> <session_id> — bring a session's terminal to the front.
# iTerm: selects the exact session via AppleScript.
# IntelliJ: raises the matching PROJECT WINDOW by title (a specific JediTerm tab
#   is not scriptable). needs a one-time Accessibility grant for the caller.
# Other: raises Terminal.app.
agent="$1"; sid="$2"
f="$HOME/.harbar/sessions/$agent-$sid.json"
[ -f "$f" ] || exit 0

field() { /usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],'') or '')" "$f" "$1"; }
term=$(field terminal)
iterm=$(field iterm_session_id)
proj=$(field project)
uuid="${iterm##*:}"   # strip the w0t1p0: prefix -> the UUID iTerm's AppleScript 'id' exposes

case "$term" in
  iTerm)
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
    ;;
  IntelliJ)
    /usr/bin/open -a "IntelliJ IDEA" 2>/dev/null
    # raise the project window whose title contains the project name
    /usr/bin/osascript <<EOF 2>/dev/null
tell application "System Events"
  repeat with p in (every process whose name contains "idea" or name contains "IntelliJ" or name contains "JetBrains")
    set frontmost of p to true
    repeat with w in windows of p
      try
        if name of w contains "$proj" then
          perform action "AXRaise" of w
          return
        end if
      end try
    end repeat
  end repeat
end tell
EOF
    ;;
  *)
    /usr/bin/open -a "Terminal" 2>/dev/null ;;
esac
