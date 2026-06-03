# Harbar

<img src="assets/icon.svg" width="116" align="right" alt="Harbar icon">

**a harbour for your fleet of agent sessions.**

you run a whole fleet of coding agents at once — **Claude Code** and **Codex** sessions scattered
across iTerm tabs and IntelliJ terminals. Harbar is the harbour they all report into: one macOS
menu bar panel showing every session at a glance — which are working, which need your input, which
are idle — so you stop alt-tabbing through terminals hunting for the one blocked on a prompt. click
any session to sail straight to its terminal.

```
🔐2 💤3 ▸1 ✓5      ← menu bar badge
─────────────────
🔐 PERMISSION (claude) (2)
   ◆ api@fix-login · refactor session    · iTerm     · 12s
   ◆ webapp@feat-search · add filters    · IntelliJ  · 1m
💤 IDLE PROMPT (waiting on you) (3)
   ◆ ...
🛑 APPROVAL (codex) (0)
▸ WORKING (1)
   ✦ worker@main · add retry logic       · iTerm     · 4s
✓ IDLE (5)
```

◆ = claude, ✦ = codex. each session shows `project@branch · task`.

## how it works

every Claude Code / Codex session fires hooks from your user-level config. a single dispatcher
(`harbar-hook.py`) writes a tiny JSON state file per session to `~/.harbar/sessions/`. a native menu
bar app (`Harbar.app`) reads those files, groups by status, and shows the panel. no server, no
polling of the agents — the hooks push state, the app reads it (every 2s, pruning dead sessions by
pid).

states: `working` (prompt submitted) · **needs input** split into 🔐 permission · 🛑 codex approval ·
📝 elicitation/form · 💤 idle-prompt · `idle` (turn done) · `error`. the label is `project@branch`
plus the first few words of the latest prompt.

## requirements

- macOS (uses AppKit, `osascript`, `launchctl`)
- Xcode Command Line Tools (`swiftc`) — `xcode-select --install`
- `python3`
- Claude Code and/or Codex CLI with hooks enabled
- `terminal-notifier` (optional, for clickable notifications) — `brew install terminal-notifier`;
  the installer adds it automatically if Homebrew is present

## install

```sh
git clone <this-repo> && cd harbar
./install.sh
```

it copies scripts to `~/.harbar`, builds `~/Applications/Harbar.app`, merges the harbar hooks into
`~/.claude/settings.json` and/or `~/.codex/hooks.json` (your existing hooks are preserved, with a
timestamped backup), and adds a launch-at-login agent. skip the login item: `HARBAR_AUTOSTART=0 ./install.sh`.

then:

1. **restart any running claude/codex sessions** so they pick up the new hooks.
2. **codex only — trust the hooks.** codex silently ignores untrusted user hooks, so codex sessions
   won't show up until you trust them: open codex, run **`/hooks`**, and trust the harbar entries
   (this writes `hooks.state.<key>.trusted_hash` to `~/.codex/config.toml`). re-run `/hooks` to
   re-trust if you ever change the hook commands. claude needs no trust step.

## usage

- the badge shows counts per kind (zeros omitted). click it for the grouped list.
- click a session row to focus its terminal:
  - **iTerm** — selects the exact tab.
  - **IntelliJ** — raises the matching project window (a specific JediTerm tab isn't scriptable).
    first use prompts for an Accessibility grant.
- a session entering needs-input pops a desktop notification (idle / permission / approval / form).
  with `terminal-notifier` installed, **clicking the notification focuses that terminal**; otherwise
  it's a plain banner.
- ⌘R refresh, ⌘Q quit.

## caveats

- **codex hooks need a one-time trust step** (see install step 2) — until trusted, codex sessions
  won't appear. claude needs none.
- only **CLI** agents are tracked. the Claude *desktop app* and claude.ai in a browser have no hooks
  and can't be seen.
- on a notched Mac with a full menu bar, macOS may hide the icon behind the notch — free up menu bar
  space or use a manager like Ice.

## uninstall

```sh
./uninstall.sh
```

removes the app, the login agent, `~/.harbar`, and the harbar hooks from your configs (other hooks
kept). config backups (`*.harbar-bak-*`) are left in place.

## layout

```
src/harbar-hook.py       hook dispatcher (writes session state)
src/focus.sh             click-to-focus terminal
src/merge-hooks.py       idempotent hook-config merge / removal
src/Harbar.swift         the menu bar app (AppKit, single file)
src/Harbar-Info.plist    app bundle metadata
assets/icon.svg          the anchor logo
install.sh / uninstall.sh
```

## license

MIT
