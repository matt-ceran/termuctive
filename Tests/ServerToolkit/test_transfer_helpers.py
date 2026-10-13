import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import support  # noqa: F401
from tmc import checklist, claudecfg, finalize, hydrate, ports, validate


class TemporaryHome(unittest.TestCase):
    def setUp(self) -> None:
        super().setUp()
        self.home = Path(tempfile.mkdtemp(prefix="tmc-home-"))
        self.previous_home = os.environ.get("HOME")
        os.environ["HOME"] = str(self.home)

    def tearDown(self) -> None:
        if self.previous_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = self.previous_home
        shutil.rmtree(self.home, ignore_errors=True)
        super().tearDown()


@unittest.skipUnless(shutil.which("git"), "git is not installed")
class FinalizeTests(TemporaryHome):
    def make_repository(self) -> Path:
        root = self.home / "Documents" / "project"
        root.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        for key, value in [
            ("core.ignorecase", "true"),
            ("core.fsmonitor", "true"),
            ("credential.helper", "osxkeychain"),
        ]:
            subprocess.run(["git", "-C", str(root), "config", key, value], check=True)
        return root

    def test_mac_only_repository_settings_are_fixed(self) -> None:
        root = self.make_repository()
        (root / ".env").write_text("SECRET=1\n")
        (root / ".env.example").write_text("SECRET=\n")
        nested = root / ".worktrees" / "task"
        nested.mkdir(parents=True)
        (nested / ".env").write_text("SECRET=2\n")
        (root / "node_modules" / "pkg").mkdir(parents=True)
        (root / "node_modules" / "pkg" / ".env").write_text("ignored\n")

        report = finalize.finalize(str(root))

        self.assertEqual(finalize.git_value(str(root), "core.ignorecase"), ["false"])
        self.assertEqual(finalize.git_value(str(root), "core.fsmonitor"), [])
        self.assertEqual(finalize.git_value(str(root), "credential.helper"), [])
        self.assertEqual(len(report["git"]), 3)
        self.assertEqual(
            sorted(report["environmentFiles"]),
            sorted([str(root / ".env"), str(nested / ".env")]),
        )
        self.assertEqual(stat.S_IMODE((root / ".env").stat().st_mode), 0o600)
        self.assertNotEqual(stat.S_IMODE((root / ".env.example").stat().st_mode), 0o600)

    def test_worktrees_left_on_the_mac_are_locked_against_pruning(self) -> None:
        root = self.make_repository()
        subprocess.run(["git", "-C", str(root), "config", "user.email", "t@example.com"], check=True)
        subprocess.run(["git", "-C", str(root), "config", "user.name", "T"], check=True)
        subprocess.run(
            ["git", "-C", str(root), "commit", "-q", "--allow-empty", "-m", "start"], check=True
        )
        kept = root / ".worktrees" / "kept"
        missing = root / ".worktrees" / "left-on-mac"
        for path in (kept, missing):
            subprocess.run(
                ["git", "-C", str(root), "worktree", "add", "-q", "--detach", str(path)],
                check=True,
            )
        shutil.rmtree(missing)

        locked = finalize.lock_missing_worktrees(str(root))
        subprocess.run(["git", "-C", str(root), "worktree", "prune"], check=True)

        self.assertEqual(locked, [str(missing)])
        listing = subprocess.run(
            ["git", "-C", str(root), "worktree", "list", "--porcelain"],
            stdout=subprocess.PIPE,
            text=True,
        ).stdout
        self.assertIn(f"worktree {missing}", listing)
        self.assertIn(f"worktree {kept}", listing)

    def test_gitconfig_import_drops_mac_only_settings(self) -> None:
        source = (
            "[user]\n\tname = Matt\n\temail = matt@example.com\n"
            "[credential]\n\thelper = osxkeychain\n"
            "[core]\n\teditor = /Applications/Visual Studio Code.app/bin/code --wait\n"
            "[alias]\n\tst = status\n"
        )

        report = finalize.sanitize_gitconfig(source)

        imported = (self.home / ".gitconfig.mac").read_text()
        self.assertIn("matt@example.com", imported)
        self.assertIn("st = status", imported)
        self.assertNotIn("osxkeychain", imported)
        self.assertNotIn("/Applications/", imported)
        self.assertIn("credential.helper", report["removed"])
        name = subprocess.run(
            ["git", "config", "--includes", "--global", "user.name"], stdout=subprocess.PIPE, text=True
        ).stdout.strip()
        self.assertEqual(name, "Matt")

    def test_directories_must_stay_inside_home(self) -> None:
        created = finalize.make_directories([str(self.home / "a" / "b c")])
        self.assertTrue(Path(created[0]).is_dir())
        with self.assertRaises(validate.ValidationError):
            finalize.make_directories(["/etc/termuctive"])


class ClaudeSettingsTests(TemporaryHome):
    def test_mac_only_hooks_and_status_line_are_disabled(self) -> None:
        settings = {
            "model": "opus",
            "hooks": {
                "Stop": [
                    {"hooks": [{"type": "command", "command": "afplay /System/Sounds/Glass.aiff"}]},
                    {"hooks": [{"type": "command", "command": "echo done"}]},
                ],
                "Notification": [
                    {"hooks": [{"type": "command", "command": "osascript -e 'beep'"}]}
                ],
            },
            "statusLine": {"type": "command", "command": "/opt/homebrew/bin/starship prompt"},
        }

        report = claudecfg.import_settings(settings)

        written = json.loads((self.home / ".claude" / "settings.json").read_text())
        self.assertEqual(written["model"], "opus")
        self.assertEqual(list(written["hooks"]), ["Stop"])
        self.assertEqual(written["hooks"]["Stop"][0]["hooks"][0]["command"], "echo done")
        self.assertNotIn("statusLine", written)
        self.assertEqual(len(report["disabled"]), 3)

    def test_global_config_merges_projects_and_usable_mcp_servers(self) -> None:
        (self.home / ".claude.json").write_text(
            json.dumps({"projects": {"/Users/m/p": {"allowedTools": ["Bash"]}}, "numStartups": 3})
        )
        report = claudecfg.import_global_config(
            {
                "projects": {"/Users/m/p": {"hasTrustDialogAccepted": True}, "relative": {}},
                "mcpServers": {
                    "echo": {"command": "echo", "args": ["hi"]},
                    "mac": {"command": "/Applications/Thing.app/Contents/MacOS/thing"},
                },
            }
        )

        config = json.loads((self.home / ".claude.json").read_text())
        self.assertEqual(config["numStartups"], 3)
        self.assertEqual(
            config["projects"]["/Users/m/p"],
            {"allowedTools": ["Bash"], "hasTrustDialogAccepted": True},
        )
        self.assertNotIn("relative", config["projects"])
        self.assertEqual(list(config["mcpServers"]), ["echo"])
        self.assertEqual(report["skipped"], ["mac"])


class HydrateTests(TemporaryHome):
    def test_finds_node_projects_by_lockfile_without_descending_into_dependencies(self) -> None:
        root = self.home / "project"
        (root / "frontend" / "node_modules" / "pkg").mkdir(parents=True)
        (root / "frontend" / "package.json").write_text("{}")
        (root / "frontend" / "package-lock.json").write_text("{}")
        (root / "frontend" / "node_modules" / "pkg" / "package.json").write_text("{}")
        (root / "mobile").mkdir()
        (root / "mobile" / "package.json").write_text("{}")
        (root / "requirements.lock").write_text("")

        projects = {
            str(path.relative_to(root)): command for path, command in hydrate.node_projects(root)
        }

        self.assertEqual(projects, {"frontend": ["npm", "ci"], "mobile": ["npm", "install"]})
        self.assertEqual(hydrate.python_requirements(root), root / "requirements.lock")


@unittest.skipUnless(Path("/proc/net/tcp").exists(), "needs Linux /proc")
class PortTests(unittest.TestCase):
    def test_reports_ports_this_user_listens_on(self) -> None:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        port = listener.getsockname()[1]
        try:
            found = {entry["port"]: entry for entry in ports.own_listening_ports()}
        finally:
            listener.close()
        self.assertIn(port, found)
        self.assertEqual(found[port]["pid"], os.getpid())


class ChecklistTests(TemporaryHome):
    def test_reports_missing_sign_ins_with_actions(self) -> None:
        items = checklist.collect(None)
        claude = next(entry for entry in items if entry["name"] == "Claude Code")
        self.assertFalse(claude["ok"])
        self.assertIn("Termuctive cloud checklist", checklist.render(items))


if __name__ == "__main__":
    unittest.main()
