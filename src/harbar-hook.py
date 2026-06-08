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
import sys, json, os, time, subprocess, tempfile, pathlib, shutil

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


def process(ev, agent, notify=False):
    """apply one hook event to its session state file. pure-ish: only touches
    ~/.harbar/sessions and (optionally) fires a notification. returns the written
    record, or None if the event removed the session (SessionEnd)."""
    HARBAR.mkdir(parents=True, exist_ok=True)
    sid = ev["session_id"]
    f = HARBAR / f"{agent}-{sid}.json"
    prev = json.loads(f.read_text()) if f.exists() else {}

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
        t = short_task(ev.get("prompt") or ev.get("user_prompt") or ev.get("message"))
        if t:
            rec["label"] = t                     # short label = first words of the prompt
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
    elif name == "StopFailure":
        rec["status"] = "error"
        rec["note"] = ev.get("error_type", "error")
    elif name in ("Notification", "PermissionRequest"):   # claude | codex needs-input
        rec["status"] = "needs_input"
        if name == "PermissionRequest":
            rec["kind"] = "codex_approval"
            rec["note"] = ev.get("tool_name") or "approval"
        else:
            nt = ev.get("notification_type") or "notification"
            rec["kind"] = nt
            rec["note"] = ev.get("tool_name") or nt
    elif name == "SessionEnd":            # claude only; codex has none -> pid prune
        f.unlink(missing_ok=True)
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

    # notify once per fresh transition into a needs-input kind, with friendly text
    if notify and rec["status"] == "needs_input" and prev.get("kind") != rec.get("kind"):
        kind = rec.get("kind", "")
        base = NOTIFY_MSG.get(kind, "needs your input")
        tool = rec.get("note")
        if kind in ("permission_prompt", "codex_approval") and tool and tool != kind:
            base = f"{base}: {tool}"
        title = f"{rec['project']} · {rec['terminal']}"
        if TN:  # clickable -> jumps to the session's terminal
            run(TN, "-title", title, "-message", base, "-sound", "Glass",
                "-group", f"harbar-{agent}-{sid}",
                "-execute", f"{FOCUS} {agent} {sid}")
        else:   # fallback: plain (non-clickable) notification
            m, t = base.replace('"', "'"), title.replace('"', "'")
            run("osascript", "-e",
                f'display notification "{m}" with title "{t}" sound name "Glass"')
    return rec


def main():
    try:
        process(json.load(sys.stdin), agent, notify=NOTIFY)
    except Exception:
        pass
    sys.exit(0)


if __name__ == "__main__":
    main()
