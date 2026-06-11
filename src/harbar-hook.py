#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""harbar dispatcher — one hook script for claude code + codex.

usage: harbar-hook.py <agent> [--notify]
  <agent>   "claude" | "codex" (used to namespace + tag the session)
  --notify  fire a desktop notification + sound on a fresh transition into a
            needs-input kind (permission / approval / elicitation / idle-prompt).

reads the hook JSON on stdin, updates ~/.harbar/sessions/<agent>-<id>.json
atomically, prints NOTHING to stdout and always exits 0 (so it can never alter
a codex PermissionRequest approval decision).
"""
import sys, json, os, re, time, subprocess, tempfile, pathlib, shutil

args = sys.argv[1:]
NOTIFY = "--notify" in args
positional = [a for a in args if not a.startswith("--")]
agent = positional[0] if positional else "claude"

HARBAR = pathlib.Path.home() / ".harbar" / "sessions"
DN = subprocess.DEVNULL
# needs-input kinds that pop a desktop notification, with friendly text
NOTIFY_MSG = {
    "permission_prompt": "needs permission",
    "idle_prompt": "waiting for your input",
    "elicitation_dialog": "needs form input",
    "codex_approval": "needs approval",
}
FOCUS = str(pathlib.Path.home() / ".harbar" / "focus.sh")
# per-kind notification sounds; overridden by ~/.harbar/sounds.json (written by
# the app's Sounds menu). a name resolves against /System/Library/Sounds and
# ~/Library/Sounds (drop your own .aiff there). "off" = silent banner.
SOUND_DEFAULTS = {
    "permission_prompt": "Glass",
    "codex_approval": "Glass",
    "elicitation_dialog": "Glass",
    "idle_prompt": "Tink",
}


def kind_sound(kind):
    try:
        cfg = json.loads((HARBAR.parent / "sounds.json").read_text())
    except Exception:
        cfg = {}
    s = cfg.get(kind, SOUND_DEFAULTS.get(kind, "Glass"))
    return None if s in ("", "off") else s


def run(*cmd):
    # never leak to our stdout (codex reads stdout as an approval decision)
    subprocess.run(cmd, check=False, stdout=DN, stderr=DN, stdin=DN)


def terminal_notifier():
    p = shutil.which("terminal-notifier")
    if p:
        return p
    for c in ("/opt/homebrew/bin/terminal-notifier", "/usr/local/bin/terminal-notifier"):
        if os.path.exists(c):
            return c
    return None


TN = terminal_notifier()


def detect_terminal():
    """(display_label, focus_app) for the terminal/IDE hosting the session."""
    env = os.environ
    cf = env.get("__CFBundleIdentifier", "").lower()
    tp = env.get("TERM_PROGRAM", "")
    if env.get("TERMINAL_EMULATOR") == "JetBrains-JediTerm" or "jetbrains" in cf:
        return "JetBrains", "IntelliJ IDEA"
    if tp == "iTerm.app":
        return "iTerm", "iTerm"
    if tp == "vscode" or any(x in cf for x in ("vscode", "cursor", "todesktop", "windsurf")):
        blob = (cf + " " + " ".join(env.get(k, "") for k in (
            "VSCODE_GIT_ASKPASS_NODE", "VSCODE_GIT_ASKPASS_MAIN", "VSCODE_GIT_IPC_HANDLE"))).lower()
        if "cursor" in blob or "todesktop" in blob:
            return "Cursor", "Cursor"
        if "windsurf" in blob:
            return "Windsurf", "Windsurf"
        return "VSCode", "Visual Studio Code"
    if tp == "Apple_Terminal":
        return "Terminal", "Terminal"
    if tp == "WezTerm":
        return "WezTerm", "WezTerm"
    if tp.lower() == "ghostty":
        return "Ghostty", "Ghostty"
    return (tp or "terminal"), (tp or "")


def git_branch(cwd):
    try:
        r = subprocess.run(["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
                           capture_output=True, text=True, timeout=2)
        b = r.stdout.strip()
        return b if (r.returncode == 0 and b and b != "HEAD") else None
    except Exception:
        return None


def short_task(text):
    first = (text or "").strip().splitlines()
    first = first[0].strip() if first else ""
    if not first:
        return None
    task = " ".join(first.split()[:4])
    return (task[:27].rstrip() + "…") if len(task) > 28 else task


def tool_activity(ev):
    """a short human verb for what a working session is doing right now, from a
    PreToolUse/PostToolUse payload — e.g. '$ git', 'editing focus.sh', 'reading
    README'. tool_name + tool_input shapes are stable for claude; codex tools
    fall through to a generic 'running <tool>'."""
    tool = (ev.get("tool_name") or ev.get("tool") or "").strip()
    ti = ev.get("tool_input")
    ti = ti if isinstance(ti, dict) else {}
    base = lambda p: (os.path.basename(str(p or "").rstrip("/")) or str(p or ""))
    t = tool.lower()
    act = None
    if t == "bash" or "shell" in t or t == "exec":
        cmd = (ti.get("command") or ti.get("cmd") or "").strip()
        first = cmd.split()[0] if cmd else ""
        act = f"$ {first}" if first else "running command"
    elif t in ("edit", "multiedit", "write", "notebookedit", "update", "create", "apply_patch"):
        f = base(ti.get("file_path") or ti.get("path") or ti.get("notebook_path"))
        act = f"editing {f}" if f else "editing file"
    elif t == "read":
        f = base(ti.get("file_path") or ti.get("path"))
        act = f"reading {f}" if f else "reading file"
    elif t in ("grep", "glob", "search"):
        act = "searching"
    elif t == "task":
        act = "running subagent"
    elif t in ("webfetch", "fetch"):
        act = "fetching url"
    elif t == "websearch":
        act = "web search"
    elif tool:
        act = f"running {tool}"
    if act and len(act) > 24:
        act = act[:23].rstrip() + "…"
    return act


LOOP_RE = re.compile(r"^/loop(?:\s+(\d+)([smh]))?\s+(\S[\s\S]*)$")


def parse_loop_cmd(text):
    """(interval_seconds_or_None, task) if text is a /loop invocation, else None.
    '/loop 5m check the deploy' -> (300, 'check the deploy');
    '/loop check the deploy' (self-paced) -> (None, 'check the deploy')."""
    m = LOOP_RE.match((text or "").strip())
    if not m:
        return None
    secs = int(m.group(1)) * {"s": 1, "m": 60, "h": 3600}[m.group(2)] if m.group(1) else None
    return secs, m.group(3).strip()


def update_loop(rec, prompt, now=None):
    """track /loop state across UserPromptSubmit events. a loop starts with
    '/loop [Nm] <task>'; each wakeup re-submits the task (bare for fixed-interval
    cron mode, or the same /loop line verbatim in dynamic mode) — verified
    against claude code 2.1.x. any other prompt means the user took over."""
    now = now or time.time()
    text = (prompt or "").strip()
    lp = rec.get("loop")
    parsed = parse_loop_cmd(text)
    task = parsed[1] if parsed else text
    if lp and task == lp.get("prompt"):              # wakeup -> next cycle
        n = int(lp.get("n", 1)) + 1
        gap = now - lp.get("last", now)
        if gap > 0:
            prev_avg = lp.get("avg")
            lp["avg"] = gap if prev_avg is None else (prev_avg * (n - 2) + gap) / (n - 1)
        lp["n"] = n
        lp["last"] = now
        lp.pop("next_at", None)                      # consumed; a new one may follow
    elif parsed:                                     # fresh /loop
        rec["loop"] = {"prompt": task, "every": parsed[0], "n": 1,
                       "started": now, "last": now}
    elif lp:                                         # different prompt: user took over
        rec.pop("loop", None)


def loop_active(rec, now=None):
    """a loop with no recent cycle is dead (ctrl-c kills the pending wakeups but
    fires no hook event) — stale it out after ~2.5 missed periods. an explicit
    next_at from ScheduleWakeup extends the window for slow dynamic loops."""
    lp = rec.get("loop")
    if not lp:
        return False
    now = now or time.time()
    nxt = lp.get("next_at")
    if nxt and now < nxt + 120:
        return True
    period = lp.get("every") or lp.get("avg") or 600
    return now - lp.get("last", 0) < 2.5 * period + 60


def agent_tty(pid):
    """controlling tty device of the agent process (e.g. /dev/ttys016), or None.
    this is the one channel that uniquely identifies the hook's own surface."""
    try:
        r = subprocess.run(["ps", "-o", "tty=", "-p", str(pid)],
                           capture_output=True, text=True, timeout=2)
        t = r.stdout.strip()
        if t and t not in ("??", "-"):
            return t if t.startswith("/dev/") else "/dev/" + t
    except Exception:
        pass
    return None


def _ghostty_titles():
    """snapshot of {surface id: current title} for all Ghostty terminals."""
    s = ('tell application "Ghostty"\n set o to ""\n repeat with t in terminals\n'
         '  try\n   set o to o & (id of t) & "\t" & (name of t) & linefeed\n'
         '  end try\n end repeat\n return o\nend tell')
    out = {}
    try:
        r = subprocess.run(["osascript", "-e", s], capture_output=True, text=True, timeout=4)
        if r.returncode == 0:
            for ln in r.stdout.splitlines():
                if "\t" in ln:
                    i, n = ln.split("\t", 1)
                    out[i] = n
    except Exception:
        pass
    return out


def ghostty_surface_id(tty, sid, fallback):
    """resolve the stable id of the Ghostty surface this hook runs in.

    Ghostty exposes no per-surface env var and no tty on its AppleScript terminal
    objects, so querying the *focused* surface is racy — two sessions opened in a
    burst can capture the same id. instead: write a unique OSC-2 title marker to
    our OWN controlling tty (so it lands on OUR surface), ask Ghostty which
    terminal now carries that title, grab its stable id, then restore the prior
    title. exact + race-free even when sessions share a cwd. needs Automation
    permission. returns the id or None."""
    if not tty:
        return None
    marker = f"harbar:{sid}"
    before = _ghostty_titles()                         # for an exact restore later
    try:
        with open(tty, "w") as t:
            t.write(f"\033]2;{marker}\007"); t.flush()
    except Exception:
        return None
    found = None
    try:
        s = ('tell application "Ghostty"\n repeat with t in terminals\n  try\n'
             f'   if (name of t) is "{marker}" then return (id of t)\n  end try\n'
             ' end repeat\n return ""\nend tell')
        r = subprocess.run(["osascript", "-e", s], capture_output=True, text=True, timeout=4)
        out = r.stdout.strip()
        found = out if (r.returncode == 0 and out) else None
    except Exception:
        found = None
    # always restore (even on failure) so the tab never sticks on the marker;
    # prefer the surface's pre-marker title, else the project name.
    restore = before.get(found) if found else None
    if not restore:
        restore = fallback or ""
    try:
        with open(tty, "w") as t:
            t.write(f"\033]2;{restore}\007"); t.flush()
    except Exception:
        pass
    return found


def find_agent_pid():
    """the agent runs the hook via a transient shell, so os.getppid() is that
    shell (already dying). walk up the process tree to the real claude/codex
    process — its liveness tracks the session. one ps call, walked in memory."""
    start = os.getppid()
    try:
        out = subprocess.run(["ps", "-Ao", "pid=,ppid=,comm="],
                             capture_output=True, text=True).stdout
    except Exception:
        return start
    parent, comm = {}, {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        parent[pid] = ppid
        comm[pid] = (parts[2] if len(parts) > 2 else "").lower()
    pid, fallback = start, start
    for _ in range(20):
        c = comm.get(pid, "")
        if "claude" in c or "codex" in c:
            return pid
        fallback = pid
        nxt = parent.get(pid)
        if not nxt or nxt <= 1:
            break
        pid = nxt
    return fallback


RECENT_KEEP = 12


def retire(rec, f):
    """an ended session moves to ~/.harbar/recent/ (so the app can offer
    `claude --resume`) instead of vanishing; the newest RECENT_KEEP are kept."""
    recent = HARBAR.parent / "recent"
    recent.mkdir(parents=True, exist_ok=True)
    rec = dict(rec)
    rec["status"] = "ended"
    rec["ended_at"] = time.time()
    for k in ("kind", "note", "activity"):
        rec.pop(k, None)
    fd, tmp = tempfile.mkstemp(dir=str(recent))
    with os.fdopen(fd, "w") as out:
        json.dump(rec, out)
    os.replace(tmp, recent / f.name)
    f.unlink(missing_ok=True)
    keep = sorted(recent.glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    for p in keep[RECENT_KEEP:]:
        p.unlink(missing_ok=True)


def process(ev, agent, notify=False):
    """apply one hook event to its session state file. pure-ish: only touches
    ~/.harbar/sessions and (optionally) fires a notification. returns the written
    record, or None if the event removed the session (SessionEnd)."""
    HARBAR.mkdir(parents=True, exist_ok=True)
    sid = ev["session_id"]
    f = HARBAR / f"{agent}-{sid}.json"
    prev = json.loads(f.read_text()) if f.exists() else {}
    if ev["hook_event_name"] == "SessionStart":   # live again -> not "recent" anymore
        (HARBAR.parent / "recent" / f.name).unlink(missing_ok=True)

    name = ev["hook_event_name"]
    cwd = ev.get("cwd", prev.get("cwd", ""))
    disp_term, focus_app = detect_terminal()
    rec = dict(prev)
    rec.update(
        agent=agent, session_id=sid, cwd=cwd,
        project=os.path.basename(cwd.rstrip("/")) or cwd,
        terminal=disp_term, focus_app=focus_app,
        iterm_session_id=os.environ.get("ITERM_SESSION_ID", prev.get("iterm_session_id")),
        agent_pid=find_agent_pid(),
        last_event=name, last_activity=time.time(),
    )

    if name == "SessionStart":
        rec.setdefault("started_at", time.time())
        rec["status"] = "idle"
        if cwd:
            rec["branch"] = git_branch(cwd)
    elif name == "UserPromptSubmit":
        rec["status"] = "working"
        rec.pop("note", None); rec.pop("kind", None); rec.pop("activity", None)
        if cwd:
            rec["branch"] = git_branch(cwd)
        raw = ev.get("prompt") or ev.get("user_prompt") or ev.get("message")
        update_loop(rec, raw)
        # short label = first words of the prompt (the loop task, not '/loop 5m …')
        t = short_task((rec.get("loop") or {}).get("prompt") or raw)
        if t:
            rec["label"] = t
    elif name == "Stop":
        rec["status"] = "idle"
        rec.pop("note", None); rec.pop("kind", None); rec.pop("activity", None)
    elif name in ("PreToolUse", "PostToolUse"):     # show what a working session is doing
        rec["status"] = "working"
        rec.pop("note", None); rec.pop("kind", None)
        act = tool_activity(ev)
        if act:
            rec["activity"] = act
        elif name == "PostToolUse":
            rec.pop("activity", None)
        # dynamic /loop self-paces via ScheduleWakeup — its delaySeconds is the
        # exact time of the next cycle, so capture it for the panel's countdown.
        if rec.get("loop") and ev.get("tool_name") == "ScheduleWakeup":
            ti = ev.get("tool_input")
            d = ti.get("delaySeconds") if isinstance(ti, dict) else None
            if isinstance(d, (int, float)) and d > 0:
                rec["loop"]["next_at"] = time.time() + d
    elif name == "StopFailure":
        rec["status"] = "error"
        rec["note"] = ev.get("error_type", "error")
    elif name in ("Notification", "PermissionRequest"):   # claude | codex needs-input
        nt = ev.get("notification_type") or "notification"
        if name == "Notification" and nt == "idle_prompt" and loop_active(rec):
            pass    # a looping session wakes itself between cycles — it's not
                    # waiting on the user, so don't mark it blocked or notify.
                    # permission/elicitation prompts DO block a loop and stay loud.
        elif name == "PermissionRequest":
            rec["status"] = "needs_input"
            rec["kind"] = "codex_approval"
            rec["note"] = ev.get("tool_name") or "approval"
        else:
            rec["status"] = "needs_input"
            rec["kind"] = nt
            rec["note"] = ev.get("tool_name") or nt
    elif name == "SessionEnd":            # claude only; codex has none -> pid prune
        retire(rec, f)
        return None

    # capture the Ghostty surface id once (on start, or self-heal on next prompt
    # if Automation was only granted later) so focus.sh hits the exact tab.
    if (disp_term == "Ghostty" and not rec.get("ghostty_id")
            and name in ("SessionStart", "UserPromptSubmit")):
        gid = ghostty_surface_id(agent_tty(rec["agent_pid"]), sid, rec.get("project") or "")
        if gid:
            rec["ghostty_id"] = gid

    fd, tmp = tempfile.mkstemp(dir=str(HARBAR))         # atomic write
    with os.fdopen(fd, "w") as out:
        json.dump(rec, out)
    os.replace(tmp, f)

    # notify once per fresh transition into a needs-input kind, with friendly text.
    # a session the user muted ("*" in snoozed.json, set from the app on any
    # non-blocked row) stays silent even for this first ping; kind-scoped snoozes
    # are the app's business (it re-notifies on group change, we already did).
    def muted():
        try:
            sn = json.loads((HARBAR.parent / "snoozed.json").read_text())
            return sn.get(f"{agent}-{sid}") == "*"
        except Exception:
            return False

    if (notify and rec["status"] == "needs_input"
            and prev.get("kind") != rec.get("kind") and not muted()):
        kind = rec.get("kind", "")
        base = NOTIFY_MSG.get(kind, "needs your input")
        tool = rec.get("note")
        if kind in ("permission_prompt", "codex_approval") and tool and tool != kind:
            base = f"{base}: {tool}"
        title = f"{rec['project']} · {rec['terminal']}"
        snd = kind_sound(kind)
        if TN:  # clickable -> jumps to the session's terminal
            args = [TN, "-title", title, "-message", base,
                    "-group", f"harbar-{agent}-{sid}",
                    "-execute", f"{FOCUS} {agent} {sid}"]
            if snd:
                args += ["-sound", snd]
            run(*args)
        else:   # fallback: plain (non-clickable) notification
            m, t = base.replace('"', "'"), title.replace('"', "'")
            tail = f' sound name "{snd}"' if snd else ""
            run("osascript", "-e",
                f'display notification "{m}" with title "{t}"{tail}')
    return rec


def main():
    try:
        process(json.load(sys.stdin), agent, notify=NOTIFY)
    except Exception:
        pass
    sys.exit(0)


if __name__ == "__main__":
    main()
