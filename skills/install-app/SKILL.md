---
name: install-app
description: Build and install the Harbar menu bar app (native macOS app + login agent), set up clickable notifications, and wire Codex hooks. Run this after installing the harbar plugin — the Claude hooks are already active via the plugin, this finishes the native side.
---

# Install the Harbar app

The harbar **plugin** already registered the Claude Code hooks (they're active for every
session). This step finishes the parts a plugin can't do: the native menu bar app, login
persistence, clickable notifications, and Codex (which isn't a Claude Code plugin).

Run the bundled installer. It builds `Harbar.app`, loads the launch-at-login agent, installs
`terminal-notifier`, copies the helper scripts to `~/.harbar`, and merges the Codex hooks — and it
**skips** the Claude hooks (the plugin already provides them, so there are no duplicates):

```bash
HARBAR_SKIP_CLAUDE_HOOKS=1 bash "$CLAUDE_PLUGIN_ROOT/install.sh"
```

After it finishes, tell the user:

1. **Codex only:** open codex, run `/hooks`, and trust the harbar hooks — Codex silently ignores
   untrusted user hooks, so Codex sessions won't appear until you do. (Claude needs no trust step.)
2. The Harbar icon is now in the menu bar (`◆` = claude, `☁` = codex). If it's hidden behind a
   notch, free up menu bar space or use a manager like Ice.
3. Restart any already-running Codex sessions so they pick up the new hooks.

To remove everything later: `bash "$CLAUDE_PLUGIN_ROOT/uninstall.sh"` (then `/plugin uninstall harbar@harbar` for the Claude hooks).
