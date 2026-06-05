---
name: update
description: Update Harbar after a new release — rebuilds the native app, Codex hooks, and login agent from the current plugin version. The Claude hooks update automatically when the plugin is reinstalled.
---

# Update Harbar

The Claude Code hooks update automatically when you reinstall the plugin. This step refreshes the
native side (Harbar.app, Codex hooks, login agent) from the current plugin version.

If you haven't already, update the plugin first (run these yourself — they're slash commands):

```
/plugin marketplace update harbar
/plugin install harbar@harbar
```

Then rebuild the native side (this skips the Claude hooks — the plugin provides them).
`$CLAUDE_PLUGIN_ROOT` isn't always exported into a tool shell, so resolve it with a cache fallback:

```bash
ROOT="${CLAUDE_PLUGIN_ROOT:-$(ls -d ~/.claude/plugins/cache/harbar/harbar/*/ 2>/dev/null | sort -V | tail -1)}"
HARBAR_SKIP_CLAUDE_HOOKS=1 bash "${ROOT%/}/install.sh"
```

After it finishes, tell the user:
1. restart any running claude/codex sessions so they load the updated hooks.
2. **codex only:** if the hook commands changed, run `/hooks` in codex and re-trust the harbar hooks.
