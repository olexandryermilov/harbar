# SPDX-License-Identifier: MIT
"""unit tests for merge-hooks.py — the idempotent hook-config merge / removal.

runs the script as a subprocess against a temp target file and inspects the
resulting JSON. covers: the claude/codex event sets, idempotency, preserving
foreign hooks (incl. in a shared event), stripping legacy fleet-hook.py, and
clean removal.
"""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MERGE = ROOT / "src" / "merge-hooks.py"


def cmds_under(obj, event):
    out = []
    for g in obj.get("hooks", {}).get(event, []):
        for h in g.get("hooks", []):
            out.append(h.get("command", ""))
    return out


def all_cmds(obj):
    out = []
    for groups in obj.get("hooks", {}).values():
        for g in groups:
            for h in g.get("hooks", []):
                out.append(h.get("command", ""))
    return out


class MergeHooksTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.target = pathlib.Path(self.tmp.name) / "hooks.json"

    def tearDown(self):
        self.tmp.cleanup()

    def merge(self, mode):
        r = subprocess.run([sys.executable, str(MERGE), str(self.target), mode],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def write(self, obj):
        self.target.write_text(json.dumps(obj))

    def load(self):
        return json.loads(self.target.read_text())

    def is_harbar(self, cmd):
        return "harbar-hook.py" in cmd

    def test_claude_event_set(self):
        self.merge("claude")
        hooks = self.load()["hooks"]
        for ev in ["SessionStart", "UserPromptSubmit", "PreToolUse", "Stop",
                   "StopFailure", "SessionEnd", "Notification"]:
            self.assertIn(ev, hooks, f"missing {ev}")
        self.assertTrue(all("claude" in c for c in cmds_under(self.load(), "PreToolUse")))
        # the needs-input matcher is on Notification
        self.assertEqual(hooks["Notification"][0].get("matcher"),
                         "permission_prompt|idle_prompt|elicitation_dialog")

    def test_codex_event_subset(self):
        self.merge("codex")
        hooks = self.load()["hooks"]
        for ev in ["SessionStart", "UserPromptSubmit", "PreToolUse", "Stop", "PermissionRequest"]:
            self.assertIn(ev, hooks)
        for absent in ["StopFailure", "SessionEnd", "Notification"]:
            self.assertNotIn(absent, hooks, f"codex should not register {absent}")

    def test_idempotent(self):
        self.merge("claude")
        first = self.load()
        self.merge("claude")
        self.assertEqual(self.load(), first, "second merge changed the file")

    def test_preserves_foreign_hooks(self):
        self.write({"hooks": {
            "SessionStart": [{"hooks": [{"type": "command", "command": "echo keepme"}]}],
            "PreCompact": [{"hooks": [{"type": "command", "command": "echo other"}]}],
        }})
        self.merge("claude")
        obj = self.load()
        self.assertIn("echo keepme", cmds_under(obj, "SessionStart"))
        self.assertTrue(any(self.is_harbar(c) for c in cmds_under(obj, "SessionStart")))
        self.assertEqual(cmds_under(obj, "PreCompact"), ["echo other"])

    def test_strips_legacy_fleet(self):
        self.write({"hooks": {
            "SessionStart": [{"hooks": [{"type": "command", "command": "python3 ~/.fleet/fleet-hook.py claude"}]}],
        }})
        self.merge("claude")
        cmds = all_cmds(self.load())
        self.assertFalse(any("fleet-hook.py" in c for c in cmds), "legacy fleet hook not stripped")
        self.assertTrue(any(self.is_harbar(c) for c in cmds))

    def test_remove_strips_harbar_keeps_foreign(self):
        self.write({"hooks": {
            "SessionStart": [{"hooks": [{"type": "command", "command": "echo keepme"}]}],
        }})
        self.merge("claude")
        self.merge("remove")
        obj = self.load()
        cmds = all_cmds(obj)
        self.assertFalse(any(self.is_harbar(c) for c in cmds), "harbar hooks survived removal")
        self.assertIn("echo keepme", cmds, "foreign hook lost during removal")

    def test_remove_drops_emptied_events(self):
        self.merge("claude")
        self.merge("remove")
        # nothing foreign was present, so hooks should be empty/absent
        self.assertEqual(self.load().get("hooks", {}), {})


if __name__ == "__main__":
    unittest.main()
