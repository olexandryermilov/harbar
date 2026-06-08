#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""merge (or remove) harbar hooks in a claude/codex hooks JSON file.

usage: merge-hooks.py <target.json> <claude|codex|remove>

idempotent: strips any existing harbar hook commands first, then (unless
'remove') adds the current harbar hooks. preserves every non-harbar hook, even
ones that share a group with a harbar hook. also strips legacy "fleet-hook.py"
entries so upgrades from the old name are clean.

codex note: codex requires each user hook to be TRUSTED before it runs — after
install, open codex and run `/hooks` to trust the harbar hooks (writes
hooks.state.<key>.trusted_hash in ~/.codex/config.toml). until trusted they
silently don't fire. see README.
"""
import sys, json, pathlib

if len(sys.argv) < 3:
    sys.exit("usage: merge-hooks.py <target.json> <claude|codex|remove>")

target = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
hook = str(pathlib.Path.home() / ".harbar" / "harbar-hook.py")
MARKERS = ("harbar-hook.py", "fleet-hook.py")   # current + legacy

SPECS = {
    "claude": [
        ("SessionStart", None, f"{hook} claude --notify"),
        ("UserPromptSubmit", None, f"{hook} claude --notify"),
        ("PreToolUse", None, f"{hook} claude"),
        ("Stop", None, f"{hook} claude --notify"),
        ("StopFailure", None, f"{hook} claude --notify"),
        ("SessionEnd", None, f"{hook} claude --notify"),
        ("Notification", "permission_prompt|idle_prompt|elicitation_dialog", f"{hook} claude --notify"),
    ],
    "codex": [
        ("SessionStart", None, f"{hook} codex --notify"),
        ("UserPromptSubmit", None, f"{hook} codex --notify"),
        ("PreToolUse", None, f"{hook} codex"),
        ("Stop", None, f"{hook} codex --notify"),
        ("PermissionRequest", None, f"{hook} codex --notify"),
    ],
}


def is_ours(h):
    cmd = h.get("command", "")
    return any(m in cmd for m in MARKERS)


obj = {}
if target.exists() and target.read_text().strip():
    obj = json.loads(target.read_text())
hooks = obj.setdefault("hooks", {})

# strip existing harbar/fleet commands (idempotent / clean upgrade), keep the rest
for ev in list(hooks.keys()):
    groups = []
    for g in hooks[ev]:
        g["hooks"] = [h for h in g.get("hooks", []) if not is_ours(h)]
        if g["hooks"]:
            groups.append(g)
    if groups:
        hooks[ev] = groups
    else:
        del hooks[ev]

if mode != "remove":
    if mode not in SPECS:
        sys.exit(f"unknown mode: {mode}")
    for ev, matcher, cmd in SPECS[mode]:
        group = {"hooks": [{"type": "command", "command": cmd}]}
        if matcher:
            group = {"matcher": matcher, **group}
        hooks.setdefault(ev, []).append(group)

if not hooks:
    obj.pop("hooks", None)

target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(obj, indent=2) + "\n")
print(f"{'removed harbar hooks from' if mode == 'remove' else 'merged ' + mode + ' hooks into'} {target}")
