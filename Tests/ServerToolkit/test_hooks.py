import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

import support
from tmc import hooks, paths, proc, sessionstate, tmuxctl

TMC = str(support.TOOLKIT / "bin" / "tmc")


class HookTests(support.TemporaryServerRoot):
    def setUp(self) -> None:
        super().setUp()
        self.slug = "demo"
        self.user = proc.caller()
        self.pane = str(uuid.uuid4())
        paths.member_dir(self.slug, self.user).mkdir(parents=True)
        self.home = self.directory / "home"
        self.home.mkdir()

    def run_hook(self, event: str, payload: dict, inside_pane: bool = True) -> None:
        environment = dict(os.environ, HOME=str(self.home))
        if inside_pane:
            environment.update(TMC_PANE_ID=self.pane, TMC_PROJECT=self.slug)
        else:
            environment.pop("TMC_PANE_ID", None)
            environment.pop("TMC_PROJECT", None)
        result = subprocess.run(
            [sys.executable, "-I", TMC, "hook", event],
            input=json.dumps(payload),
            text=True,
            env=environment,
        )
        self.assertEqual(result.returncode, 0)

    def state(self) -> dict:
        return sessionstate.load(self.slug, self.user, self.pane) or {}

    def test_hooks_track_the_agent_through_a_turn(self) -> None:
        self.run_hook("session-start", {"session_id": "abc-123", "cwd": "/srv/x", "source": "startup"})
        self.assertEqual(self.state()["claude"]["state"], "idle")
        self.assertEqual(self.state()["cwd"], "/srv/x")

        self.run_hook("prompt", {"session_id": "abc-123", "prompt": "Fix   the\nlogin bug"})
        self.assertEqual(self.state()["claude"]["state"], "working")
        self.assertEqual(self.state()["claude"]["lastPrompt"], "Fix the login bug")

        self.run_hook(
            "notification",
            {"notification_type": "permission_prompt", "message": "Claude needs permission"},
        )
        self.assertEqual(self.state()["claude"]["state"], "waiting")

        self.run_hook("stop", {"session_id": "abc-123", "stop_hook_active": False})
        self.assertEqual(self.state()["claude"]["state"], "idle")
        self.assertEqual(sessionstate.resume_command(self.state()), "claude --resume abc-123")

        self.run_hook("session-end", {"session_id": "abc-123", "reason": "prompt_input_exit"})
        self.assertTrue(self.state()["claude"]["ended"])
        self.assertIsNone(sessionstate.resume_command(self.state()))

    def test_hooks_ignore_sessions_outside_termuctive_panes(self) -> None:
        self.run_hook("prompt", {"prompt": "hello"}, inside_pane=False)
        self.assertEqual(sessionstate.all_states(self.slug, self.user), {})

    def test_installing_hooks_keeps_the_users_own_and_never_duplicates(self) -> None:
        settings = self.home / ".claude" / "settings.json"
        settings.parent.mkdir()
        settings.write_text(
            json.dumps(
                {"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}]}}
            )
        )
        previous_home = os.environ.get("HOME")
        os.environ["HOME"] = str(self.home)
        try:
            hooks.install()
            hooks.install()
        finally:
            os.environ["HOME"] = previous_home or ""
        written = json.loads(settings.read_text())
        self.assertEqual(written["model"], "opus")
        stop_commands = [
            entry["command"] for group in written["hooks"]["Stop"] for entry in group["hooks"]
        ]
        self.assertEqual(stop_commands[0], "echo mine")
        self.assertEqual(len(stop_commands), 2)
        self.assertTrue(stop_commands[1].endswith("tmc hook stop"))
        self.assertEqual(set(written["hooks"]), set(hooks.EVENTS.values()))

    def test_resume_commands_reject_unsafe_session_identifiers(self) -> None:
        unsafe = {"claude": {"sessionId": "x; rm -rf ~", "ended": False}}
        self.assertIsNone(sessionstate.resume_command(unsafe))


@support.requires_tmux
class ResurrectionTests(support.TemporaryServerRoot):
    def setUp(self) -> None:
        super().setUp()
        self.slug = "demo"
        self.user = proc.caller()
        paths.run_dir(self.slug).mkdir(parents=True)
        self.pane = str(uuid.uuid4())
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        fake_claude = self.bin / "claude"
        fake_claude.write_text('#!/bin/sh\necho "RESUMED $2 in $PWD"\n')
        fake_claude.chmod(0o755)
        self.workdir = self.directory / "last place"
        self.workdir.mkdir()
        self.environment = dict(
            os.environ,
            TERM="xterm-256color",
            SHELL="/bin/sh",
            ENV="",
            PATH=f"{self.bin}:{os.environ.get('PATH', '')}",
        )

    def tearDown(self) -> None:
        subprocess.run(
            tmuxctl.tmux_command(self.slug, self.user, "kill-server"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        super().tearDown()

    def test_a_pane_lost_to_a_restart_resumes_its_claude_conversation(self) -> None:
        from test_tmuxctl import run_attached

        sessionstate.update(
            self.slug,
            self.user,
            self.pane,
            {"cwd": str(self.workdir), "claude": {"sessionId": "abc-123", "state": "working"}},
        )

        code, output = run_attached(
            ["attach", "--slug", self.slug, "--pane", self.pane, "--cwd", "/", "--protocol", "1"],
            self.environment,
            [("RESUMED", lambda fd: os.write(fd, b"exit\r"))],
        )

        self.assertIn(f"RESUMED abc-123 in {self.workdir}", output)
        self.assertEqual(code, tmuxctl.EXIT_SHELL_ENDED)
        self.assertIsNone(sessionstate.load(self.slug, self.user, self.pane))

    def test_session_reports_include_agent_state_and_processes(self) -> None:
        subprocess.run(
            tmuxctl.tmux_command(
                self.slug, self.user, "new-session", "-d", "-s", "tmc-" + self.pane, "sleep 30"
            ),
            check=True,
            env=self.environment,
        )
        sessionstate.update(
            self.slug, self.user, self.pane, {"claude": {"state": "working", "sessionId": "s"}}
        )

        report = tmuxctl.report(self.slug, self.user)

        self.assertEqual(len(report), 1)
        self.assertEqual(report[0]["claude"]["state"], "working")
        self.assertIsInstance(report[0]["processes"], list)
