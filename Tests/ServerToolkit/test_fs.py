import base64
import os
import shutil
import tempfile
import time
import unittest
from pathlib import Path

import support  # noqa: F401
from tmc import fs


class FileAccessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="tmc-fs-"))

    def tearDown(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def test_tree_skips_the_same_folders_as_the_local_navigator(self) -> None:
        for path in ["src/app.py", "node_modules/x/index.js", ".git/HEAD", "build/out.o", "README.md", ".DS_Store"]:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("x")
        tree = fs.tree(str(self.root))
        self.assertEqual(
            sorted(tuple(entry) for entry in tree["entries"]),
            [("README.md", False), ("src", True), ("src/app.py", False)],
        )
        self.assertFalse(tree["truncated"])

    def test_writes_only_succeed_against_the_expected_version(self) -> None:
        path = str(self.root / "notes.txt")
        created = fs.write(path, fs.ABSENT, b"first\n")
        self.assertTrue(created["written"])
        current = fs.read(path)
        self.assertEqual(base64.b64decode(current["content"]), b"first\n")
        self.assertEqual(current["digest"], created["digest"])

        stale = fs.write(path, fs.ABSENT, b"other\n")
        self.assertTrue(stale["conflict"])
        self.assertEqual(base64.b64decode(stale["current"]["content"]), b"first\n")

        os.chmod(path, 0o640)
        updated = fs.write(path, current["digest"], b"second\n")
        self.assertTrue(updated["written"])
        self.assertEqual((self.root / "notes.txt").read_bytes(), b"second\n")
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o640)
        self.assertEqual(fs.digests([path, str(self.root / "missing")]), {path: updated["digest"], str(self.root / "missing"): None})

    def test_large_files_report_their_size_without_content(self) -> None:
        big = self.root / "big.bin"
        big.write_bytes(b"x" * (fs.MAXIMUM_TEXT_SIZE + 1))
        result = fs.read(str(big))
        self.assertNotIn("content", result)
        self.assertEqual(result["size"], fs.MAXIMUM_TEXT_SIZE + 1)
        self.assertEqual(fs.read(str(self.root / "nope")), {"exists": False})

    def test_newest_pdf_since_a_time(self) -> None:
        old = self.root / "old.pdf"
        old.write_bytes(b"%PDF")
        os.utime(old, (time.time() - 100, time.time() - 100))
        start = time.time() - 50
        (self.root / "out").mkdir()
        new = self.root / "out" / "Lesson.PDF"
        new.write_bytes(b"%PDF")
        self.assertEqual(fs.recent_pdf(str(self.root), start)["path"], str(new))
        self.assertIsNone(fs.recent_pdf(str(self.root), time.time() + 10)["path"])


if __name__ == "__main__":
    unittest.main()
