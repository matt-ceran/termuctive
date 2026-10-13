"""Shared helpers for the server toolkit tests."""

import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[2]
TOOLKIT = REPOSITORY / "Resources" / "termuctive-server"
sys.path.insert(0, str(TOOLKIT / "lib"))
sys.dont_write_bytecode = True

requires_tmux = unittest.skipUnless(shutil.which("tmux"), "tmux is not installed")


class TemporaryServerRoot(unittest.TestCase):
    """Points the toolkit at temporary /srv and /opt roots."""

    def setUp(self) -> None:
        super().setUp()
        self.directory = Path(tempfile.mkdtemp(prefix="tmc-test-"))
        self.srv = self.directory / "srv"
        self.opt = self.directory / "opt"
        self.srv.mkdir()
        self.opt.mkdir()
        self.previous = {key: os.environ.get(key) for key in ("TMC_SRV_ROOT", "TMC_OPT_ROOT")}
        os.environ["TMC_SRV_ROOT"] = str(self.srv)
        os.environ["TMC_OPT_ROOT"] = str(self.opt)

    def tearDown(self) -> None:
        for key, value in self.previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        shutil.rmtree(self.directory, ignore_errors=True)
        super().tearDown()
