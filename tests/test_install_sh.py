"""install.sh port classification, driven with stub binaries.

The port probe must not trust ``lsof``'s exit status alone: lsof exits 1 both
for "no matching file" and for several errors, so a discarded stderr silently
turns a broken probe into "port is free". These tests put a stubbed ``lsof``
(and a stubbed ``launchctl``) first on PATH, so the real launchd is never
touched and the outcome is observable.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
INSTALL = REPO_ROOT / "scripts" / "install.sh"
LABEL = "com.tokenboard.test.probee"

LAUNCHCTL_STUB = """#!/bin/bash
echo "$@" >> "$LAUNCHCTL_LOG"
if [ "$1" = "print" ]; then exit 113; fi   # emulate "service not loaded"
exit 0
"""


class InstallPortProbeTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.stub_dir = root / "bin"
        self.stub_dir.mkdir()
        self.home = root / "home"
        (self.home / "Library" / "LaunchAgents").mkdir(parents=True)
        self.launchctl_log = self.home / "launchctl.log"
        self._stub("launchctl", LAUNCHCTL_STUB)

    # -- helpers -----------------------------------------------------------
    def _stub(self, name: str, body: str) -> Path:
        path = self.stub_dir / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)
        return path

    def _run(self) -> subprocess.CompletedProcess:
        env = {
            key: value
            for key, value in os.environ.items()
            if key not in {"TB_PYTHON", "TB_LABEL", "TB_PORT", "TOKENBOARD_DB"}
        }
        env.update(
            {
                "HOME": str(self.home),
                "PATH": f"{self.stub_dir}:{os.environ['PATH']}",
                "LAUNCHCTL_LOG": str(self.launchctl_log),
                "TB_LABEL": LABEL,
                "TB_PORT": "8798",
                "TOKENBOARD_DB": str(self.home / "usage.db"),
            }
        )
        return subprocess.run(
            ["bash", str(INSTALL)],
            capture_output=True,
            text=True,
            timeout=180,
            env=env,
        )

    def _launchctl_calls(self) -> list[str]:
        if not self.launchctl_log.exists():
            return []
        return [line for line in self.launchctl_log.read_text().splitlines() if line]

    def _plists(self) -> list[Path]:
        return sorted((self.home / "Library" / "LaunchAgents").iterdir())

    # -- cases -------------------------------------------------------------
    def test_lsof_rc1_with_stderr_aborts_before_any_launchctl_call(self):
        self._stub(
            "lsof",
            "#!/bin/bash\n"
            "echo \"lsof: WARNING: can't stat() fuse.gvfsd-fuse file system\" >&2\n"
            "exit 1\n",
        )
        result = self._run()

        self.assertEqual(result.returncode, 1, result.stderr)
        combined = result.stdout + result.stderr
        self.assertIn("cannot tell whether port 8798 is free", combined)
        self.assertIn("can't stat() fuse.gvfsd-fuse", combined)  # diagnostic kept
        self.assertEqual(
            self._launchctl_calls(), [], "launchctl must not be called at all"
        )
        self.assertEqual(self._plists(), [], "no plist may be written")

    def test_lsof_success_with_stderr_aborts(self):
        # rc=0 *and* a pid, but a warning on stderr: a partial listing may have
        # omitted our own job, so the ownership check must not trust it.
        self._stub(
            "lsof",
            "#!/bin/bash\n"
            "echo 4242\n"
            "echo \"lsof: WARNING: can't stat() fuse.gvfsd-fuse file system\" >&2\n"
            "exit 0\n",
        )
        result = self._run()

        self.assertEqual(result.returncode, 1, result.stderr)
        combined = result.stdout + result.stderr
        self.assertIn("cannot tell whether port 8798 is free", combined)
        self.assertIn("lsof printed diagnostics (exit 0)", combined)
        self.assertIn("partial pids: 4242", combined)
        self.assertIn("can't stat() fuse.gvfsd-fuse", combined)
        self.assertEqual(
            self._launchctl_calls(), [], "launchctl must not be called at all"
        )
        self.assertEqual(self._plists(), [], "no plist may be written")

    def test_lsof_rc1_silent_is_treated_as_free(self):
        self._stub("lsof", "#!/bin/bash\nexit 1\n")
        self._stub("curl", "#!/bin/bash\nexit 1\n")   # health check fails fast
        self._stub("sleep", "#!/bin/bash\nexit 0\n")  # no real waiting

        result = self._run()

        combined = result.stdout + result.stderr
        self.assertNotIn("cannot tell whether port", combined)
        self.assertNotIn("already used by another listener", combined)
        calls = self._launchctl_calls()
        self.assertTrue(
            any(call.startswith("bootstrap ") for call in calls),
            f"install should have proceeded to bootstrap, got {calls}",
        )
        self.assertFalse(
            any(call.startswith("bootout ") for call in calls),
            "nothing was loaded, so nothing should be stopped",
        )
        self.assertEqual([p.name for p in self._plists()], [f"{LABEL}.plist"])

    def test_listener_is_reported_as_busy(self):
        self._stub("lsof", "#!/bin/bash\necho 4242\nexit 0\n")
        result = self._run()

        self.assertEqual(result.returncode, 1)
        combined = result.stdout + result.stderr
        self.assertIn("port 8798 is already used by another listener (pid 4242)", combined)
        self.assertEqual(
            [c for c in self._launchctl_calls() if not c.startswith("print ")],
            [],
            "a foreign listener must be refused before any mutation",
        )
        self.assertEqual(self._plists(), [])

    def test_lsof_other_error_is_not_treated_as_free(self):
        self._stub("lsof", "#!/bin/bash\necho 'lsof: status error' >&2\nexit 4\n")
        result = self._run()

        self.assertEqual(result.returncode, 1)
        combined = result.stdout + result.stderr
        self.assertIn("cannot tell whether port 8798 is free", combined)
        self.assertIn("lsof printed diagnostics (exit 4)", combined)
        self.assertEqual(self._launchctl_calls(), [])

    @unittest.skipUnless(shutil.which("launchctl"), "macOS launchctl only")
    def test_script_is_present_and_parses(self):
        # Cheap guard: a syntax error would make every case above meaningless.
        result = subprocess.run(
            ["bash", "-n", str(INSTALL)], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    sys.exit(unittest.main())
