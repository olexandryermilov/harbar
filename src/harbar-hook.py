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


try:
    HARBAR.mkdir(parents=True, exist_ok=True)
    ev = json.load(sys.stdin)
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
        rec.pop("note", None); rec.pop("kind", None)
        if cwd:
            rec["branch"] = git_branch(cwd)
        t = short_task(ev.get("prompt") or ev.get("user_prompt") or ev.get("message"))
        if t:
            rec["label"] = t                     # short label = first words of the prompt
    elif name == "Stop":
        rec["status"] = "idle"
        rec.pop("note", None); rec.pop("kind", None)
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
        sys.exit(0)

    fd, tmp = tempfile.mkstemp(dir=str(HARBAR))         # atomic write
    with os.fdopen(fd, "w") as out:
        json.dump(rec, out)
    os.replace(tmp, f)

    # notify once per fresh transition into a needs-input kind, with friendly text
    if NOTIFY and rec["status"] == "needs_input" and prev.get("kind") != rec.get("kind"):
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
except Exception:
    pass
sys.exit(0)
