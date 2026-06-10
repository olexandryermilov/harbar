# changelog

all notable changes, newest first. versions match `.claude-plugin/plugin.json`.

## 1.8.0 — 2026-06-10

- **↻ RECENT + resume**: ended sessions are kept (12 newest, ≤1 week) in a folded section at the
  bottom of the panel. click one to reopen it in a new terminal tab and resume the conversation
  (`claude --resume` / `codex resume`). resuming or restarting the session drops it off the list.
- **`/harbar:doctor`**: one-shot diagnostic — app + login agent, hook executes, plugin version vs
  marketplace, codex hook trust, terminal-notifier + a test banner for the notification permission
  that brew updates keep resetting. every finding comes with its fix inline.

## 1.7.0 — 2026-06-10

- **foldable groups**: click any group header (▼/▶) to collapse/expand it — the menu stays open,
  state persists per section. handy for a tall ✓ IDLE pile.
- **project pins**: ⇧-click any row to pin its project (📌). pinned sessions sort first and stay
  visible inside folded groups. stored in `~/.harbar/pinned.json`.
- **snooze everywhere**: ⌥-click now snoozes any row, not just blocked ones. blocked rows keep the
  kind-scoped snooze (auto-clears + re-notifies on group change); working/idle rows get a full
  mute — no first ping when the session later blocks, no reminders — until manually resumed.

## 1.6.0 — 2026-06-10

- **⌃⌥J keyboard triage**: global hotkey jumps to the longest-blocked session's terminal; pressing
  again cycles the whole blocked queue (snoozed last). no Accessibility grant needed. remap via
  `defaults write com.harbar.app hotkeyKeyCode/hotkeyModifiers`.
- blocked rows show how long they've been **waiting on you** (`⏳ 4m`) and sort longest-waiting
  first.

## 1.5.1 — 2026-06-10

- the loop marker is an **icon on the row**, not a separate group: a looping session stays in its
  natural section (working / idle / blocked) with an inline 🔁.

## 1.5.0 — 2026-06-10

- **`/loop` tracking**: sessions driven by claude code's `/loop` show 🔁 with the cycle count
  (`×6`), cadence (`every 5m` parsed from the command, `avg ~6m` measured for self-paced loops),
  and the current tool or a `⏲ next ~2m` countdown between cycles.
- a blocked loop shows in its kind section tagged 🔁 with normal reminders; between-cycle
  idle-prompts are muted (the loop wakes itself). cancelled loops fade out after ~2.5 missed
  cycles. only loops started after this version are tracked.

## 1.4.0 — 2026-06-08

- **snooze**: ⌥-click a blocked row to mute its reminders while it stays in that kind; the snooze
  clears (and you're re-notified) when the session changes group. snoozed rows are marked 😴.

## 1.3.0 — 2026-06-08

- reminder intervals are configurable **per kind** (menu ▸ Reminders): off / 1 / 2 / 5 / 10 / 15 /
  30 min. defaults: permission / approval / form = 5 min, idle prompt = 15 min.
- "re-nag" renamed to **reminders** everywhere.

## 1.2.0 — 2026-06-08

- **reminders**: a still-blocked session re-pings on an interval (was: single notification, easy
  to miss).
- **working activity**: working rows show the current tool (`editing focus.sh`, `$ git`,
  `searching`, …) via a new `PreToolUse` hook.
- test suite (python stdlib unittest) + GitHub Actions CI (tests + lint on linux, app build on
  macos).

## 1.1.1 — 2026-06-07

- **Ghostty**: the surface id is captured via a one-shot title marker written to the session's own
  tty — exact tab focus even when two sessions share a folder (the previous focused-terminal query
  was racy).

## 1.1.0 — 2026-06-06

- **Ghostty**: click-to-focus selects the exact tab via Ghostty's AppleScript dictionary.
- `/harbar:update` skill + documented update flow.

## 1.0.0 — 2026-06-05

- initial release: menu bar app + hooks for claude code & codex, grouped status panel
  (🔐 permission / 🛑 approval / 📝 form / 💤 idle-prompt / ▸ working / ✓ idle / ⚠ error),
  desktop notifications, click-to-focus (exact tab in iTerm), install as claude code plugin or
  via `./install.sh`.
