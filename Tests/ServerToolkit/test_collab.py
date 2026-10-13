import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import support  # noqa: F401
from tmc import collab, memory, validate


class MemoryMergeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="tmc-memory-"))
        self.mine = self.directory / "shared"
        self.theirs = self.directory / "sam"
        for folder in (self.mine, self.theirs):
            folder.mkdir()

    def tearDown(self) -> None:
        shutil.rmtree(self.directory, ignore_errors=True)

    def test_union_keeps_both_versions_of_conflicting_memories(self) -> None:
        (self.mine / "MEMORY.md").write_text("- [Search](search.md) — never shifts\n")
        (self.mine / "search.md").write_text("Matt's version\n")
        (self.mine / "same.md").write_text("identical\n")
        (self.theirs / "MEMORY.md").write_text(
            "- [Search](search.md) — never shifts\n- [Billing](billing.md) — credits\n"
        )
        (self.theirs / "search.md").write_text("Sam's version\n")
        (self.theirs / "same.md").write_text("identical\n")
        (self.theirs / "billing.md").write_text("credits\n")
        (self.theirs / "nested").mkdir()
        (self.theirs / "nested" / "deep.md").write_text("deep\n")

        report = memory.merge(self.theirs, self.mine, member="sam")

        self.assertEqual(sorted(report["added"]), ["billing.md", "nested/deep.md"])
        self.assertEqual(report["identical"], ["same.md"])
        self.assertEqual(report["conflicts"], ["search.md"])
        self.assertEqual((self.mine / "search.md").read_text(), "Matt's version\n")
        self.assertEqual((self.mine / "search.sam.md").read_text(), "Sam's version\n")
        self.assertIn("search.md", (self.mine / "MERGE-REVIEW.md").read_text())
        self.assertEqual(
            (self.mine / "MEMORY.md").read_text().splitlines(),
            ["- [Search](search.md) — never shifts", "- [Billing](billing.md) — credits"],
        )

    def test_oversized_index_produces_a_warning(self) -> None:
        (self.theirs / "MEMORY.md").write_text("".join(f"- line {n}\n" for n in range(250)))
        report = memory.merge(self.theirs, self.mine, member="sam")
        self.assertEqual(len(report["warnings"]), 1)

    def test_project_keys_match_claude_code(self) -> None:
        self.assertEqual(
            memory.project_key("/Users/mattceran/Documents/bluekite"),
            "-Users-mattceran-Documents-bluekite",
        )

    def test_linking_merges_existing_memories_then_replaces_the_folder(self) -> None:
        home = self.directory / "home"
        root = "/Users/m/project"
        existing = memory.member_memory_link(str(home), root)
        existing.mkdir(parents=True)
        (existing / "note.md").write_text("mine\n")

        memory.link_member(str(home), root, self.mine, os.getuid(), os.getgid())

        self.assertTrue(existing.is_symlink())
        self.assertEqual(os.readlink(existing), str(self.mine))
        self.assertEqual((self.mine / "note.md").read_text(), "mine\n")


@unittest.skipUnless(shutil.which("git"), "git is not installed")
class ImportRefsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="tmc-refs-"))
        self.root = self.directory / "repo"
        self.git("init", "-q", "-b", "main", str(self.root), cwd=self.directory)
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "T")
        self.commit("start")

    def tearDown(self) -> None:
        shutil.rmtree(self.directory, ignore_errors=True)

    def git(self, *arguments: str, cwd: Path = None) -> str:
        return subprocess.run(
            ["git", *arguments],
            cwd=str(cwd or self.root),
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout.strip()

    def commit(self, message: str) -> str:
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def test_branches_are_adopted_without_overwriting_or_moving_checked_out_work(self) -> None:
        base = self.git("rev-parse", "HEAD")
        self.git("branch", "shared-feature")
        self.git("branch", "matt-only")
        self.git("checkout", "-q", "matt-only")
        self.commit("matt's work")
        self.git("checkout", "-q", "main")
        self.git("worktree", "add", "-q", str(self.directory / "wt"), "shared-feature")

        self.git("checkout", "-q", "-b", "temp", base)
        sam_new = self.commit("sam new branch")
        self.git("update-ref", "refs/termuctive/import/sam/sam-feature", sam_new)
        self.git("update-ref", "refs/termuctive/import/sam/matt-only", sam_new)
        self.git("update-ref", "refs/termuctive/import/sam/shared-feature", sam_new)
        self.git("checkout", "-q", "main")
        self.git("branch", "-D", "temp")

        mapping = collab.import_refs(str(self.root), "sam")

        self.assertEqual(
            mapping,
            {
                "matt-only": "sam/matt-only",
                "sam-feature": "sam-feature",
                "shared-feature": "sam/shared-feature",
            },
        )
        self.assertEqual(self.git("rev-parse", "shared-feature"), base)
        self.assertEqual(self.git("rev-parse", "sam-feature"), sam_new)
        self.assertEqual(self.git("for-each-ref", "refs/termuctive/import/"), "")


class JoinFinishTests(unittest.TestCase):
    def setUp(self) -> None:
        self.home = Path(tempfile.mkdtemp(prefix="tmc-join-"))
        self.previous = os.environ.get("HOME")
        os.environ["HOME"] = str(self.home)
        (self.home / ".ssh").mkdir()
        self.authorized = self.home / ".ssh" / "authorized_keys"
        self.authorized.write_text(
            'restrict,command="/opt/termuctive/bin/tmc join-finish abc123" '
            "ssh-ed25519 AAAAINVITE tmc-invite-abc123\n"
        )

    def tearDown(self) -> None:
        os.environ["HOME"] = self.previous or ""
        shutil.rmtree(self.home, ignore_errors=True)

    def test_an_invite_installs_the_real_key_exactly_once(self) -> None:
        collab.join_finish("abc123", "ssh-ed25519 AAAAREALKEY sam@mac\n")

        lines = self.authorized.read_text().splitlines()
        self.assertEqual(lines, ["ssh-ed25519 AAAAREALKEY sam@mac"])
        with self.assertRaises(validate.ValidationError):
            collab.join_finish("abc123", "ssh-ed25519 AAAAOTHER x")


if __name__ == "__main__":
    unittest.main()
