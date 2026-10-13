import json
import os
import pty
import select
import subprocess
import sys
import time
import unittest
import uuid

import support
from tmc import paths, proc, tmuxctl

TMC = str(support.TOOLKIT / "bin" / "tmc")


def run_attached(arguments, environment, actions, timeout=10.0):
    """Runs `tmc attach` on a pseudo-terminal and feeds it scripted input.

    `actions` is a list of (marker, callback) pairs: when `marker` appears in the
    output the callback runs (it may write to the terminal or act externally).
    Returns (exit code, output).
    """
    pid, descriptor = pty.fork()
    if pid == 0:
        os.execve(sys.executable, [sys.executable, "-I", TMC, *arguments], environment)
    output = b""
    pending = list(actions)
    deadline = time.time() + timeout
    status = None
    while time.time() < deadline:
        ready, _, _ = select.select([descriptor], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(descriptor, 4096)
            except OSError:
                chunk = b""
            output += chunk
        while pending and pending[0][0].encode() in output:
            _, callback = pending.pop(0)
            callback(descriptor)
        finished, status = os.waitpid(pid, os.WNOHANG)
        if finished:
            break
    else:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        raise AssertionError(f"tmc attach did not finish; output: {output!r}")
    os.close(descriptor)
    return os.waitstatus_to_exitcode(status), output.decode(errors="replace")


@support.requires_tmux
class TmuxSessionTests(support.TemporaryServerRoot):
    def setUp(self) -> None:
        super().setUp()
        self.slug = "demo"
        self.user = proc.caller()
        paths.run_dir(self.slug).mkdir(parents=True)
        self.workdir = self.directory / "work dir"
        self.workdir.mkdir()
        self.pane = str(uuid.uuid4())
        self.environment = dict(
            os.environ,
            TERM="xterm-256color",
            SHELL="/bin/sh",
            ENV="",
        )

    def tearDown(self) -> None:
        subprocess.run(
            tmuxctl.tmux_command(self.slug, self.user, "kill-server"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        super().tearDown()

    def attach_arguments(self, protocol="1"):
        return [
            "attach",
            "--slug",
            self.slug,
            "--pane",
            self.pane,
            "--cwd",
            str(self.workdir),
            "--protocol",
            protocol,
        ]

    def test_exiting_the_shell_ends_the_session(self) -> None:
        code, output = run_attached(
            self.attach_arguments(),
            self.environment,
            [("$", lambda fd: os.write(fd, b"printf 'PWD:%s|PANE:%s\\n' \"$PWD\" \"$TMC_PANE_ID\"; exit\r"))],
        )
        self.assertEqual(code, tmuxctl.EXIT_SHELL_ENDED, output)
        self.assertIn(f"PWD:{self.workdir}|PANE:{self.pane}", output)
        self.assertFalse(tmuxctl.has_session(self.slug, self.user, self.pane))

    def test_detaching_keeps_the_session_and_reattaches(self) -> None:
        def detach(_descriptor):
            subprocess.run(
                tmuxctl.tmux_command(self.slug, self.user, "detach-client", "-s", "tmc-" + self.pane),
                check=True,
            )

        def mark_and_detach(descriptor):
            os.write(descriptor, b"echo REMEMBER-ME\r")
            time.sleep(0.3)
            detach(descriptor)

        code, _ = run_attached(self.attach_arguments(), self.environment, [("$", mark_and_detach)])
        self.assertEqual(code, tmuxctl.EXIT_DETACHED)
        self.assertTrue(tmuxctl.has_session(self.slug, self.user, self.pane))

        sessions = tmuxctl.list_sessions(self.slug, self.user)
        self.assertEqual([session["pane"] for session in sessions], [self.pane])
        self.assertEqual(sessions[0]["cwd"], str(self.workdir))

        code, output = run_attached(
            self.attach_arguments(),
            self.environment,
            [("REMEMBER-ME", lambda fd: os.write(fd, b"exit\r"))],
        )
        self.assertEqual(code, tmuxctl.EXIT_SHELL_ENDED)
        self.assertIn("REMEMBER-ME", output)

    def test_a_first_command_runs_only_when_the_session_is_created(self) -> None:
        marker = self.directory / "runs.txt"
        arguments = self.attach_arguments() + [
            "--command",
            f"echo ran >> '{marker}'; echo FIRST-DONE",
        ]

        def detach(_descriptor):
            subprocess.run(
                tmuxctl.tmux_command(self.slug, self.user, "detach-client", "-s", "tmc-" + self.pane),
                check=True,
            )

        code, _ = run_attached(arguments, self.environment, [("FIRST-DONE", detach)])
        self.assertEqual(code, tmuxctl.EXIT_DETACHED)

        code, _ = run_attached(
            arguments,
            self.environment,
            [("FIRST-DONE", lambda fd: os.write(fd, b"exit\r"))],
        )
        self.assertEqual(code, tmuxctl.EXIT_SHELL_ENDED)
        self.assertEqual(marker.read_text().splitlines(), ["ran"])

    def test_kill_ends_a_detached_session(self) -> None:
        subprocess.run(
            tmuxctl.tmux_command(
                self.slug, self.user, "new-session", "-d", "-s", "tmc-" + self.pane, "sh"
            ),
            check=True,
        )
        result = subprocess.run(
            [sys.executable, "-I", TMC, "kill", "--slug", self.slug, "--pane", self.pane],
            env=self.environment,
        )
        self.assertEqual(result.returncode, 0)
        self.assertFalse(tmuxctl.has_session(self.slug, self.user, self.pane))

    def test_protocol_mismatch_reports_an_incompatible_server(self) -> None:
        code, output = run_attached(self.attach_arguments(protocol="99"), self.environment, [])
        self.assertEqual(code, tmuxctl.EXIT_INCOMPATIBLE)
        self.assertIn("protocol", output)

    def test_missing_project_membership_fails_clearly(self) -> None:
        arguments = self.attach_arguments()
        arguments[2] = "other"
        code, output = run_attached(arguments, self.environment, [])
        self.assertEqual(code, tmuxctl.EXIT_FAILED)
        self.assertIn("not a member", output)


class SessionNameTests(unittest.TestCase):
    def test_session_names_round_trip_pane_identifiers(self) -> None:
        pane = str(uuid.uuid4())
        self.assertEqual(tmuxctl.pane_from_session(tmuxctl.session_name(pane)), pane)
        self.assertIsNone(tmuxctl.pane_from_session("tmc-not-a-uuid"))
        self.assertIsNone(tmuxctl.pane_from_session("other"))


class VersionTests(unittest.TestCase):
    def test_version_is_json(self) -> None:
        result = subprocess.run(
            [sys.executable, "-I", TMC, "version"], stdout=subprocess.PIPE, text=True, check=True
        )
        payload = json.loads(result.stdout)
        self.assertEqual(payload["protocol"], 1)
        self.assertRegex(payload["version"], r"^\d+\.\d+\.\d+$")


if __name__ == "__main__":
    unittest.main()
