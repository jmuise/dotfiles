#!/usr/bin/env python3
"""Regression test for install.py's AI-profile gate tri-state.

Guards against the security-review finding on PR #64 (issue #39's linker
slim-down): an invalid profile file used to collapse to the SAME behaviour
as an explicit `bare` at every gated call site (apply_gated_links() and the
direct unlink_gated() call guarding ~/.copilot/settings.json), because
AI_ENABLED was a plain bool (False for both "explicitly off" and "error,
unknown"). With pre-existing AI symlinks already on disk, writing an invalid
value (e.g. "full") to the profile file and re-running install.py for real
UNLINKED all of them -- including ~/.claude/hooks and ~/.copilot/hooks, the
devcontainer guard hooks -- while printing a message that claimed the
opposite ("leaving whatever is currently there untouched"). The fix makes
resolve_ai_gate() return a genuine tri-state (True/False/None) so an invalid
profile is a real no-op: no link, no unlink, at every gated destination.

This runs install.py for real (never --dry-run: the bug is a real-run-only
divergence between what --dry-run previews and what a real run leaves on
disk) against a throwaway, freshly `git init`-ed COPY of this checkout's
tracked working-tree content -- never this worktree or the canonical
checkout, since install.py's git-hooks step writes core.hooksPath into the
repo's own .git/config (see hooks/_dispatch.sh, issue #54, and #64's own PR
description for why this matters).

legacy/provision_legacy.py -- real machine-state provisioning (package/CLI
installs) with no bearing on the AI gate under test here -- is stubbed to a
no-op inside that scratch copy only, so this test stays hermetic and does
not depend on network access. git/ensure-gcm.sh is short-circuited the same
way profile/README.md's own contract expects any already-configured
credential.helper to be: by pre-seeding a [credential] block in the sandbox
$HOME's ~/.gitconfig.local before the first run, never by touching the
script itself.

Run directly: ``python3 tests/test_install_ai_gate.py``
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def _tracked_files() -> list[Path]:
    out = subprocess.run(
        ["git", "-C", str(REPO), "ls-files"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [REPO / p for p in out.splitlines() if p]


class InvalidProfileLeavesAiLinksAloneTest(unittest.TestCase):
    """Case 2 of PR #64's security-fix verification protocol."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.dotfiles = root / "dotfiles"
        self.home = root / "home"
        self.home.mkdir()

        # Copy this checkout's TRACKED files -- working-tree content, so this
        # exercises whatever is about to be committed, not just the last
        # commit -- into a fresh scratch copy. Never the worktree itself.
        for src in _tracked_files():
            if not src.is_file():
                continue
            rel = src.relative_to(REPO)
            dst = self.dotfiles / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)

        # install.py writes core.hooksPath into THIS copy's own .git config
        # -- never the canonical checkout's or a worktree's shared one.
        subprocess.run(["git", "init", "-q"], cwd=self.dotfiles, check=True)

        # Stub the legacy-provisioning subprocess call to a no-op: it is
        # unrelated machine-state provisioning, and running it for real
        # would make this test depend on network access.
        legacy = self.dotfiles / "legacy" / "provision_legacy.py"
        legacy.write_text(
            "#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n", encoding="utf-8"
        )

        # Pre-seed a [credential] block so git/ensure-gcm.sh's own
        # already-configured check short-circuits before it would otherwise
        # try to download a git-credential-manager release.
        (self.home / ".gitconfig.local").write_text(
            "[credential]\n\thelper = cache\n", encoding="utf-8"
        )

    def _run_install(self):
        env = {"HOME": str(self.home), "PATH": os.environ.get("PATH", "")}
        return subprocess.run(
            [sys.executable, "install.py"],
            cwd=self.dotfiles, env=env,
            capture_output=True, text=True, timeout=120,
        )

    def _ai_symlinks(self):
        out = subprocess.run(
            ["find", str(self.home), "-type", "l"],
            capture_output=True, text=True, check=True,
        ).stdout
        gated = ("/.claude/", "/.config/kilo/", "/.copilot/")
        return sorted(line for line in out.splitlines() if any(g in line for g in gated))

    def test_invalid_profile_leaves_existing_ai_links_untouched(self):
        # 1. Real agentic install (no profile file) -- establishes a baseline
        # of existing AI symlinks, the precondition the bug needed to bite.
        baseline = self._run_install()
        self.assertEqual(baseline.returncode, 0, baseline.stderr)
        before = self._ai_symlinks()
        self.assertTrue(before, "expected AI symlinks to exist after an agentic install")

        # 2. Write an invalid profile value, then re-run for real.
        profile_path = self.home / ".config" / "dotfiles" / "profile"
        profile_path.parent.mkdir(parents=True, exist_ok=True)
        profile_path.write_text("full", encoding="utf-8")

        result = self._run_install()

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Invalid dotfiles profile", result.stderr)
        self.assertIn("Refusing to link OR unlink any AI configuration", result.stderr)

        after = self._ai_symlinks()
        self.assertEqual(
            before, after,
            "an invalid profile must leave every pre-existing AI symlink exactly as it "
            "was -- no link, no unlink",
        )


if __name__ == "__main__":
    unittest.main()
