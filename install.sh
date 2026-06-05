#!/usr/bin/env bash
# harbar installer (macOS). idempotent — safe to re-run.
#   HARBAR_AUTOSTART=0 ./install.sh   # skip the launch-at-login agent
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/src"
HARBAR="$HOME/.harbar"
APP="$HOME/Applications/Harbar.app"
LABEL="com.harbar.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
AUTOSTART="${HARBAR_AUTOSTART:-1}"
SKIP_CLAUDE="${HARBAR_SKIP_CLAUDE_HOOKS:-0}"   # plugin install sets this — the plugin provides the Claude hooks

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m xx\033[0m %s\n' "$1" >&2; exit 1; }

command -v swiftc  >/dev/null || die "swiftc not found — install Xcode Command Line Tools: xcode-select --install"
command -v python3 >/dev/null || die "python3 not found."

if ! command -v terminal-notifier >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    info "installing terminal-notifier (clickable notifications)"
    brew install terminal-notifier >/dev/null 2>&1 || warn "terminal-notifier install failed; notifications will be non-clickable"
  else
    warn "terminal-notifier not found and no brew — notifications will be non-clickable."
  fi
fi

info "installing scripts to $HARBAR"
mkdir -p "$HARBAR/sessions"
cp "$SRC/harbar-hook.py" "$SRC/focus.sh" "$SRC/merge-hooks.py" "$SRC/Harbar.swift" "$SRC/Harbar-Info.plist" "$HARBAR/"
chmod +x "$HARBAR/harbar-hook.py" "$HARBAR/focus.sh" "$HARBAR/merge-hooks.py"

info "building Harbar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HARBAR/Harbar-Info.plist" "$APP/Contents/Info.plist"
swiftc -O -framework AppKit "$HARBAR/Harbar.swift" -o "$APP/Contents/MacOS/Harbar"
# build the .icns app icon from assets/icon.png
if [ -f "$SCRIPT_DIR/assets/icon.png" ]; then
  set_dir="$(mktemp -d)/Harbar.iconset"; mkdir -p "$set_dir"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s"           "$SCRIPT_DIR/assets/icon.png" --out "$set_dir/icon_${s}x${s}.png"    >/dev/null 2>&1
    sips -z "$((s*2))" "$((s*2))" "$SCRIPT_DIR/assets/icon.png" --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$set_dir" -o "$APP/Contents/Resources/Harbar.icns" >/dev/null 2>&1 || true
fi
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

merge_for() {  # <agent> <config-file>
  local agent="$1" f="$2"
  [ -e "$f" ] && cp "$f" "$f.harbar-bak-$(date +%s)"
  python3 "$HARBAR/merge-hooks.py" "$f" "$agent"
}
merged=0
if [ "$SKIP_CLAUDE" = "1" ]; then
  info "skipping claude hooks (provided by the harbar plugin)"
elif command -v claude >/dev/null || [ -e "$HOME/.claude/settings.json" ]; then
  info "merging claude hooks (~/.claude/settings.json)"; merge_for claude "$HOME/.claude/settings.json"; merged=1
fi
if command -v codex >/dev/null || [ -e "$HOME/.codex/hooks.json" ]; then
  info "merging codex hooks (~/.codex/hooks.json)";       merge_for codex  "$HOME/.codex/hooks.json"; merged=1
fi
[ "$merged" = 1 ] || warn "neither claude nor codex detected — no hooks merged."

if [ "$AUTOSTART" = 1 ]; then
  info "installing launch-at-login agent"
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Harbar</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PL
  osascript -e 'quit app "Harbar"' >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
else
  info "starting Harbar (autostart skipped)"
  open "$APP" || true
fi

info "done."
echo
echo "  • restart any already-running claude/codex sessions so they load the new hooks."
echo "  • CODEX ONLY: open codex and run /hooks, then trust the harbar hooks — codex"
echo "    silently ignores untrusted user hooks until you do."
echo "  • Harbar shows in the menu bar (free up space if it's hidden behind a notch)."
echo "  • uninstall: $SCRIPT_DIR/uninstall.sh"
