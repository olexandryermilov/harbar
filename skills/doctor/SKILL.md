---
name: doctor
description: Diagnose a Harbar install — app running, hooks registered and executing, plugin up to date, Codex hooks trusted, notification permission. Run when sessions don't show up, notifications stopped appearing, or anything else seems off.
---

# Harbar doctor

Run the bundled diagnostic and help the user fix whatever it flags.

`$CLAUDE_PLUGIN_ROOT` isn't always exported into a tool shell, so resolve the plugin root with a
fallback to the install cache:

```bash
ROOT="${CLAUDE_PLUGIN_ROOT:-$(ls -d ~/.claude/plugins/cache/harbar/harbar/*/ 2>/dev/null | sort -V | tail -1)}"
bash "${ROOT%/}/src/doctor.sh" --banner
```

Each line is ✅ (fine), ⚠️ (degraded, fix inline), or ❌ (broken, fix inline).

Then:

1. **Ask the user whether the test banner appeared** (the `--banner` flag fired one). If it did
   not, the usual culprit is macOS notification permission for terminal-notifier, which **Homebrew
   updates silently reset**: System Settings → Notifications → terminal-notifier → Allow
   Notifications (style: Banners or Alerts). There is no programmatic check — asking is the test.
2. Walk through every ⚠️/❌ line with the user and apply the inline fix. Typical ones:
   - plugin outdated → `/plugin marketplace update harbar`, `/plugin install harbar@harbar`,
     then `/harbar:update` to rebuild the native side.
   - codex hooks untrusted → the user opens codex and runs `/hooks` (you cannot do this for them).
   - login agent not loaded → the user runs the printed `launchctl bootstrap` line themselves.
3. If everything is ✅ and the banner appeared, say so and remind the user that already-running
   claude/codex sessions only pick up hook changes after a restart of that session.
