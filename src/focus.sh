#!/bin/bash
# SPDX-License-Identifier: MIT
# focus.sh <agent> <session_id> — bring a session's terminal/IDE to the front.
# iTerm + Ghostty: select the EXACT tab via the terminal's AppleScript dictionary
#   (iTerm by session id, Ghostty by working directory). first use asks to allow
#   controlling that app (Automation).
# everything else (VSCode, Cursor, JetBrains, Terminal, …): raise the app and,
#   best-effort, the window whose title matches the project — integrated-terminal
#   tabs aren't scriptable, so this lands on the project window. needs Accessibility.
agent="$1"; sid="$2"
f="$HOME/.harbar/sessions/$agent-$sid.json"
[ -f "$f" ] || exit 0

field() { /usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],'') or '')" "$f" "$1"; }
term=$(field terminal)
app=$(field focus_app)
proj=$(field project)
cwd=$(field cwd)
gid=$(field ghostty_id)
iterm=$(field iterm_session_id)
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
  Ghostty)
    # Ghostty ships a real AppleScript dictionary. focus the surface by its stable
    # id (captured at session start — exact even when sessions share a cwd); fall
    # back to matching the working directory, then to just activating the app.
    /usr/bin/osascript <<EOF 2>/dev/null
tell application "Ghostty"
  if "$gid" is not "" then
    repeat with t in terminals
      try
        if (id of t) is "$gid" then
          focus t
          return
        end if
      end try
    end repeat
  end if
  repeat with t in terminals
    try
      if (working directory of t) is "$cwd" then
        focus t
        return
      end if
    end try
  end repeat
  activate
end tell
EOF
    ;;
  *)
    if [ -n "$app" ]; then /usr/bin/open -a "$app" 2>/dev/null; else /usr/bin/open -a "Terminal" 2>/dev/null; fi
    if [ -n "$proj" ]; then
      sleep 0.3
      /usr/bin/osascript <<EOF 2>/dev/null
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
    fi
    ;;
esac
