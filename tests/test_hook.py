# SPDX-License-Identifier: MIT
"""unit tests for the harbar hook dispatcher (state machine + helpers).

loads src/harbar-hook.py as a module (main() is guarded), points its session
dir at a temp dir, and stubs the environment-dependent bits (pid walk, terminal
detection, git) so the transitions are deterministic on any machine / CI.
"""
import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOOK = ROOT / "src" / "harbar-hook.py"


def load_hook():
    spec = importlib.util.spec_from_file_location("harbar_hook", HOOK)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


hook = load_hook()


class HookStateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.sessions = pathlib.Path(self.tmp.name) / "sessions"
        hook.HARBAR = self.sessions
        hook.TN = None                                  # don't spawn terminal-notifier
        hook.find_agent_pid = lambda: 4242
        hook.detect_terminal = lambda: ("Terminal", "Terminal")  # never the Ghostty path
        hook.git_branch = lambda cwd: None

    def tearDown(self):
        self.tmp.cleanup()

    def run_ev(self, agent="claude", **ev):
        ev.setdefault("session_id", "s1")
        ev.setdefault("cwd", self.tmp.name)
        return hook.process(ev, agent)

    def read(self, agent="claude", sid="s1"):
        p = self.sessions / f"{agent}-{sid}.json"
        return json.loads(p.read_text()) if p.exists() else None

    def test_session_start_is_idle(self):
        rec = self.run_ev(hook_event_name="SessionStart")
        self.assertEqual(rec["status"], "idle")
        self.assertIn("started_at", rec)
        self.assertEqual(self.read()["status"], "idle")

    def test_prompt_goes_working_with_label(self):
        self.run_ev(hook_event_name="SessionStart")
        rec = self.run_ev(hook_event_name="UserPromptSubmit", prompt="fix the login bug now please")
        self.assertEqual(rec["status"], "working")
        self.assertEqual(rec["label"], "fix the login bug")

    def test_pretooluse_captures_activity(self):
        rec = self.run_ev(hook_event_name="PreToolUse", tool_name="Bash",
                          tool_input={"command": "git status -s"})
        self.assertEqual(rec["status"], "working")
        self.assertEqual(rec["activity"], "$ git")

    def test_activity_cleared_on_stop(self):
        self.run_ev(hook_event_name="PreToolUse", tool_name="Read",
                    tool_input={"file_path": "/x/y/README.md"})
        self.assertEqual(self.read()["activity"], "reading README.md")
        rec = self.run_ev(hook_event_name="Stop")
        self.assertEqual(rec["status"], "idle")
        self.assertNotIn("activity", rec)

    def test_activity_cleared_on_new_prompt(self):
        self.run_ev(hook_event_name="PreToolUse", tool_name="Bash", tool_input={"command": "ls"})
        rec = self.run_ev(hook_event_name="UserPromptSubmit", prompt="next thing")
        self.assertNotIn("activity", rec)

    def test_notification_permission_prompt(self):
        rec = self.run_ev(hook_event_name="Notification",
                          notification_type="permission_prompt", tool_name="Bash")
        self.assertEqual(rec["status"], "needs_input")
        self.assertEqual(rec["kind"], "permission_prompt")
        self.assertEqual(rec["note"], "Bash")

    def test_codex_permission_request(self):
        rec = self.run_ev(agent="codex", hook_event_name="PermissionRequest", tool_name="shell")
        self.assertEqual(rec["status"], "needs_input")
        self.assertEqual(rec["kind"], "codex_approval")
        self.assertEqual(rec["note"], "shell")

    def test_stop_failure_is_error(self):
        rec = self.run_ev(hook_event_name="StopFailure", error_type="boom")
        self.assertEqual(rec["status"], "error")
        self.assertEqual(rec["note"], "boom")

    def test_session_end_removes_file(self):
        self.run_ev(hook_event_name="SessionStart")
        self.assertIsNotNone(self.read())
        rec = self.run_ev(hook_event_name="SessionEnd")
        self.assertIsNone(rec)
        self.assertIsNone(self.read())

    def test_needs_input_then_resolved_clears_kind(self):
        self.run_ev(hook_event_name="Notification", notification_type="idle_prompt")
        rec = self.run_ev(hook_event_name="UserPromptSubmit", prompt="ok go")
        self.assertEqual(rec["status"], "working")
        self.assertNotIn("kind", rec)
        self.assertNotIn("note", rec)

    def test_atomic_write_leaves_no_temp_files(self):
        self.run_ev(hook_event_name="SessionStart")
        leftovers = [p.name for p in self.sessions.iterdir() if not p.name.endswith(".json")]
        self.assertEqual(leftovers, [])


class LoopTests(unittest.TestCase):
    """/loop detection: start, wakeups, cadence, takeover, idle-prompt muting."""
    TASK = "respond with only the word TICK and the current time, use no tools"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.sessions = pathlib.Path(self.tmp.name) / "sessions"
        hook.HARBAR = self.sessions
        hook.TN = None
        hook.find_agent_pid = lambda: 4242
        hook.detect_terminal = lambda: ("Terminal", "Terminal")
        hook.git_branch = lambda cwd: None

    def tearDown(self):
        self.tmp.cleanup()

    def run_ev(self, **ev):
        ev.setdefault("session_id", "s1")
        ev.setdefault("cwd", self.tmp.name)
        return hook.process(ev, "claude")

    def start_loop(self, prompt=None):
        return self.run_ev(hook_event_name="UserPromptSubmit",
                           prompt=prompt or f"/loop 1m {self.TASK}")

    def test_parse_loop_cmd(self):
        self.assertEqual(hook.parse_loop_cmd("/loop 5m check the deploy"),
                         (300, "check the deploy"))
        self.assertEqual(hook.parse_loop_cmd("/loop 90s ping"), (90, "ping"))
        self.assertEqual(hook.parse_loop_cmd("/loop 1h /standup 1"), (3600, "/standup 1"))
        self.assertEqual(hook.parse_loop_cmd("/loop check the deploy"),
                         (None, "check the deploy"))
        self.assertIsNone(hook.parse_loop_cmd("fix the login bug"))
        self.assertIsNone(hook.parse_loop_cmd("/looper 5m x"))

    def test_loop_start(self):
        rec = self.start_loop()
        self.assertEqual(rec["loop"]["n"], 1)
        self.assertEqual(rec["loop"]["every"], 60)
        self.assertEqual(rec["loop"]["prompt"], self.TASK)
        self.assertEqual(rec["label"], "respond with only the")   # task, not '/loop 1m …'
        self.assertEqual(rec["status"], "working")

    def test_wakeup_increments_cycles(self):
        self.start_loop()
        rec = self.run_ev(hook_event_name="UserPromptSubmit", prompt=self.TASK)
        self.assertEqual(rec["loop"]["n"], 2)
        rec = self.run_ev(hook_event_name="UserPromptSubmit", prompt=self.TASK)
        self.assertEqual(rec["loop"]["n"], 3)
        self.assertIn("avg", rec["loop"])

    def test_dynamic_wakeup_with_loop_prefix_does_not_reset(self):
        # dynamic mode re-fires the same /loop input verbatim each wakeup
        self.start_loop("/loop check the deploy")
        rec = self.run_ev(hook_event_name="UserPromptSubmit", prompt="/loop check the deploy")
        self.assertEqual(rec["loop"]["n"], 2)
        self.assertIsNone(rec["loop"]["every"])

    def test_user_takeover_clears_loop(self):
        self.start_loop()
        rec = self.run_ev(hook_event_name="UserPromptSubmit", prompt="actually stop, do X")
        self.assertNotIn("loop", rec)
        self.assertEqual(rec["label"], "actually stop, do X")

    def test_loop_survives_stop(self):
        self.start_loop()
        rec = self.run_ev(hook_event_name="Stop")
        self.assertEqual(rec["status"], "idle")
        self.assertEqual(rec["loop"]["n"], 1)

    def test_idle_prompt_muted_while_looping(self):
        self.start_loop()
        self.run_ev(hook_event_name="Stop")
        rec = self.run_ev(hook_event_name="Notification", notification_type="idle_prompt")
        self.assertEqual(rec["status"], "idle")          # not needs_input
        self.assertNotIn("kind", rec)

    def test_permission_prompt_still_loud_while_looping(self):
        self.start_loop()
        rec = self.run_ev(hook_event_name="Notification",
                          notification_type="permission_prompt", tool_name="Bash")
        self.assertEqual(rec["status"], "needs_input")
        self.assertEqual(rec["kind"], "permission_prompt")
        self.assertEqual(rec["loop"]["n"], 1)            # flag survives the block

    def test_idle_prompt_loud_when_loop_stale(self):
        rec = self.start_loop()
        # backdate the loop so 2.5 periods have passed (a ctrl-c'd loop)
        p = self.sessions / "claude-s1.json"
        rec["loop"]["last"] -= 1000
        p.write_text(json.dumps(rec))
        rec = self.run_ev(hook_event_name="Notification", notification_type="idle_prompt")
        self.assertEqual(rec["status"], "needs_input")

    def test_schedule_wakeup_sets_next_at(self):
        self.start_loop("/loop watch the deploy")
        rec = self.run_ev(hook_event_name="PreToolUse", tool_name="ScheduleWakeup",
                          tool_input={"delaySeconds": 270, "reason": "x", "prompt": "y"})
        self.assertIn("next_at", rec["loop"])
        self.assertGreater(rec["loop"]["next_at"], rec["loop"]["last"] + 200)


class ToolActivityTests(unittest.TestCase):
    def act(self, tool, ti=None):
        return hook.tool_activity({"tool_name": tool, "tool_input": ti or {}})

    def test_bash_first_word(self):
        self.assertEqual(self.act("Bash", {"command": "git push -f origin"}), "$ git")

    def test_bash_no_command(self):
        self.assertEqual(self.act("Bash", {}), "running command")

    def test_codex_shell_tool(self):
        self.assertEqual(self.act("local_shell", {"command": "ls -la"}), "$ ls")

    def test_edit_basename(self):
        self.assertEqual(self.act("Edit", {"file_path": "/a/b/focus.sh"}), "editing focus.sh")

    def test_write_basename(self):
        self.assertEqual(self.act("Write", {"file_path": "x.py"}), "editing x.py")

    def test_read_basename(self):
        self.assertEqual(self.act("Read", {"file_path": "/r/README"}), "reading README")

    def test_grep_is_searching(self):
        self.assertEqual(self.act("Grep", {"pattern": "foo"}), "searching")

    def test_task_is_subagent(self):
        self.assertEqual(self.act("Task"), "running subagent")

    def test_unknown_tool_generic(self):
        self.assertEqual(self.act("Frobnicate"), "running Frobnicate")

    def test_empty_tool_is_none(self):
        self.assertIsNone(self.act(""))

    def test_long_activity_truncated(self):
        a = self.act("Edit", {"file_path": "a-really-really-long-filename-indeed.txt"})
        self.assertLessEqual(len(a), 24)
        self.assertTrue(a.endswith("…"))


class ShortTaskTests(unittest.TestCase):
    def test_first_four_words(self):
        self.assertEqual(hook.short_task("add retry logic to the worker"), "add retry logic to")

    def test_empty(self):
        self.assertIsNone(hook.short_task(""))

    def test_none(self):
        self.assertIsNone(hook.short_task(None))

    def test_first_line_only(self):
        self.assertEqual(hook.short_task("rename it\nand more"), "rename it")

    def test_long_word_truncates_with_ellipsis(self):
        out = hook.short_task("supercalifragilisticexpialidocious extra words here")
        self.assertTrue(out.endswith("…"))


if __name__ == "__main__":
    unittest.main()
