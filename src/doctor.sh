#!/bin/bash
# doctor.sh — diagnose a harbar install. every check prints one ✅/⚠️/❌ line
# with the fix inline; always exits 0 (it's a report, not a gate).
# --banner additionally fires a test notification (the caller asks the user
# whether it actually appeared — that's the only reliable permission check).

ok()   { printf '✅ %s\n' "$1"; }
warn() { printf '⚠️  %s\n' "$1"; }
fail() { printf '❌ %s\n' "$1"; }

APP="$HOME/Applications/Harbar.app"
H="$HOME/.harbar"

# --- the native app ---------------------------------------------------------
[ -x "$APP/Contents/MacOS/Harbar" ] \
  && ok "Harbar.app installed" \
  || fail "Harbar.app missing — run /harbar:install-app (plugin) or ./install.sh (manual)"
pgrep -xq Harbar \
  && ok "Harbar.app running" \
  || fail "Harbar.app not running — open ~/Applications/Harbar.app"
if [ -f "$HOME/Library/LaunchAgents/com.harbar.app.plist" ]; then
  launchctl print "gui/$(id -u)/com.harbar.app" >/dev/null 2>&1 \
    && ok "launch-at-login agent loaded" \
    || warn "login agent present but not loaded — launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.harbar.app.plist"
else
  warn "no launch-at-login agent — harbar won't start at login (installed with HARBAR_AUTOSTART=0?)"
fi

# --- the hook dispatcher ----------------------------------------------------
HOOK=""
for c in "$HOME/.claude/plugins/cache/harbar/harbar"/*/src/harbar-hook.py "$H/harbar-hook.py"; do
  [ -f "$c" ] && HOOK="$c"
done
if [ -n "$HOOK" ]; then
  ok "hook dispatcher present ($HOOK)"
  if echo '{"hook_event_name":"SessionStart","session_id":"doctor-smoke","cwd":"'"$HOME"'"}' \
       | python3 "$HOOK" claude >/dev/null 2>&1 \
     && [ -f "$H/sessions/claude-doctor-smoke.json" ]; then
    ok "hook executes and writes session state"
  else
    fail "hook failed to write a session file — check python3 and permissions on ~/.harbar"
  fi
  rm -f "$H/sessions/claude-doctor-smoke.json" "$H/recent/claude-doctor-smoke.json"
else
  fail "no hook dispatcher found — reinstall (plugin: /plugin install harbar@harbar; manual: ./install.sh)"
fi

# --- claude side ------------------------------------------------------------
if ls -d "$HOME/.claude/plugins/cache/harbar/harbar"/*/ >/dev/null 2>&1; then
  cache=$(ls -d "$HOME/.claude/plugins/cache/harbar/harbar"/*/ 2>/dev/null | sed 's:/$::;s:.*/::' | sort -V | tail -1)
  ok "claude: harbar plugin installed (cache $cache)"
  mkt=$(python3 -c "import json;print(json.load(open('$HOME/.claude/plugins/marketplaces/harbar/.claude-plugin/marketplace.json'))['plugins'][0]['version'])" 2>/dev/null)
  if [ -n "$mkt" ] && [ "$mkt" != "$cache" ]; then
    warn "plugin is $cache but the marketplace has $mkt — run: /plugin marketplace update harbar, /plugin install harbar@harbar, /harbar:update"
  elif [ -n "$mkt" ]; then
    ok "claude: plugin up to date ($mkt)"
  fi
elif grep -q harbar-hook "$HOME/.claude/settings.json" 2>/dev/null; then
  ok "claude: manual hooks present in ~/.claude/settings.json"
else
  fail "claude: no harbar hooks — /plugin install harbar@harbar (plugin) or ./install.sh (manual)"
fi

# --- codex side (optional) --------------------------------------------------
if command -v codex >/dev/null 2>&1; then
  if grep -q harbar-hook "$HOME/.codex/hooks.json" 2>/dev/null; then
    ok "codex: harbar hooks present in ~/.codex/hooks.json"
    if grep -q 'hooks\.state' "$HOME/.codex/config.toml" 2>/dev/null; then
      ok "codex: hook trust state present (if sessions are missing, re-run /hooks in codex)"
    else
      warn "codex: hooks look UNTRUSTED — codex silently ignores them; open codex and run /hooks to trust the harbar entries"
    fi
  else
    warn "codex installed but no harbar hooks — run ./install.sh (or /harbar:install-app) to wire them"
  fi
fi

# --- notifications ----------------------------------------------------------
TN=""
for c in "$(command -v terminal-notifier 2>/dev/null)" /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier; do
  [ -n "$c" ] && [ -x "$c" ] && TN="$c" && break
done
if [ -n "$TN" ]; then
  ok "terminal-notifier installed ($TN)"
  if [ "$1" = "--banner" ]; then
    "$TN" -title "harbar doctor" -message "if you can read this, notifications work" \
          -group harbar-doctor >/dev/null 2>&1
    warn "test banner sent — if it did NOT appear: System Settings → Notifications → terminal-notifier → Allow (brew updates reset this)"
  fi
else
  warn "terminal-notifier missing — banners fall back to non-clickable osascript; brew install terminal-notifier"
fi

# --- state dirs -------------------------------------------------------------
n=$(ls "$H/sessions"/*.json 2>/dev/null | wc -l | tr -d ' ')
ok "$n live session file(s) in ~/.harbar/sessions"
exit 0
