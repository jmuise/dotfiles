#!/usr/bin/env python3
"""Regression test for issue #70: install.py must never write core.hooksPath
into the wrong repository's config.

`install.py` runs `git -C <DOTFILES> config core.hooksPath <abs path>`. Before
the fix under test, that write went wherever git's normal repo discovery
resolved <DOTFILES> to -- which is NOT necessarily <DOTFILES> itself:

  * <DOTFILES> can be a plain copy of the tree nested inside ANOTHER git
    repo (no .git of its own): discovery walks up and finds the outer repo.
  * GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE (etc.), if inherited from the
    calling process -- for example when install.py runs from inside a git
    hook -- override discovery outright and point it at a third repo.
  * <DOTFILES> can be a linked git worktree, whose --show-toplevel is itself
    but whose core.hooksPath lives in the PRIMARY checkout's *shared*
    .git/config -- every worktree of that repo shares one hooksPath.

This is exactly how it happened for real: the canonical checkout's
core.hooksPath got silently repointed at a deleted /tmp scratch directory
during a sandboxed test run, and git then silently skipped every hook
(including the never-merge pre-commit guard) with no error at all.

Four scenarios against THIS branch's (fixed) install.py:
  (a) nested inside another repo, no .git of its own -> outer repo's config
      unchanged, a warning is printed, the rest of the install still runs.
  (b) GIT_DIR (+ GIT_WORK_TREE) leaked in via the environment, pointing at a
      third repo -> that repo's config unchanged, a warning is printed.
  (c) the normal case -- <DOTFILES> is its own repo root -> hooksPath IS set.
  (d) a linked git worktree -> refused; the shared primary .git/config is
      unchanged, a warning is printed.

Two more scenarios prove the bug is real, not merely asserted: (a) and (b)
are repeated against install.py as it exists on `main` (fetched with `git
archive main | tar -x`, never a checkout -- this worktree's own HEAD and
working tree are never touched), and are asserted to actually corrupt the
outer/leaked repo's config, which is exactly the defect this PR fixes.

Every scenario runs install.py for real (never --dry-run) against a
throwaway `git init`-ed (or `git worktree add`-ed) COPY, with a sandboxed
$HOME, never this worktree or the canonical checkout -- same pattern as
tests/test_install_ai_gate.py and tests/test_dotfiles_cli.py; see those
files' docstrings for why. legacy/provision_legacy.py is stubbed to a no-op
in every sandbox copy (unrelated machine-state provisioning, would otherwise
need network access). git/ensure-gcm.sh is short-circuited by pre-seeding a
[credential] block in the sandbox $HOME's ~/.gitconfig.local, same as those
files.

Run directly: ``python3 tests/test_hookspath_repo_guard.py``
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

# GIT_* vars stripped from the env every real subprocess call in this test
# makes to REPO's own git, so nothing here can ever be influenced by (or
# leak into) whatever repo happens to be running this test suite.
_ISOLATE_GIT_ENV = {
    k: v for k, v in os.environ.items()
    if not (
        k.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_"))
        or k in (
            "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
            "GIT_OBJECT_DIRECTORY", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS",
            "GIT_CONFIG_COUNT",
        )
    )
}


def _tracked_files() -> list[Path]:
    out = subprocess.run(
        ["git", "-C", str(REPO), "ls-files"],
        capture_output=True, text=True, check=True, env=_ISOLATE_GIT_ENV,
    ).stdout
    return [REPO / p for p in out.splitlines() if p]


def _copy_tracked_tree(dest: Path) -> None:
    """Copy this branch's tracked working-tree content (uncommitted edits to
    already-tracked files included) into `dest`, which must not yet exist."""
    for src in _tracked_files():
        if not src.is_file():
            continue
        rel = src.relative_to(REPO)
        dst = dest / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def _ensure_local_main_ref() -> None:
    """Make sure this worktree's shared repo has a local `main` ref to archive.

    CI checks out a PR's merge/head ref, not `main` by name, and may not have
    fetched it at all. `git archive main` below needs a resolvable `main`, so
    this brings one in via `git fetch` if it's missing. This only ever
    updates a ref (`refs/heads/main`) -- it never touches HEAD, the index, or
    any working tree, so it cannot check anything out.
    """
    probe = subprocess.run(
        ["git", "-C", str(REPO), "rev-parse", "--verify", "-q", "main"],
        capture_output=True, text=True, env=_ISOLATE_GIT_ENV,
    )
    if probe.returncode == 0:
        return
    subprocess.run(
        ["git", "-C", str(REPO), "fetch", "--quiet", "origin", "main:refs/heads/main"],
        check=True, env=_ISOLATE_GIT_ENV,
    )


def _archive_main_tree(dest: Path) -> None:
    """Extract `main`'s full tree into `dest` (which must already exist) via
    `git archive main | tar -x` -- never `git checkout`/`git switch`, so this
    worktree's own HEAD and working tree are never touched."""
    _ensure_local_main_ref()
    archive = subprocess.run(
        ["git", "-C", str(REPO), "archive", "main"],
        capture_output=True, env=_ISOLATE_GIT_ENV, check=True,
    )
    subprocess.run(
        ["tar", "-x", "-C", str(dest)],
        input=archive.stdout, check=True,
    )


def _stub_legacy_provisioner(dotfiles: Path) -> None:
    legacy = dotfiles / "legacy" / "provision_legacy.py"
    legacy.parent.mkdir(parents=True, exist_ok=True)
    legacy.write_text("#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n", encoding="utf-8")


def _seed_home(home: Path) -> None:
    """Sandbox $HOME with a pre-seeded credential.helper so git/ensure-gcm.sh
    short-circuits instead of trying to download a GCM release."""
    home.mkdir(parents=True, exist_ok=True)
    (home / ".gitconfig.local").write_text(
        "[credential]\n\thelper = cache\n", encoding="utf-8"
    )


def _run_install(dotfiles: Path, home: Path, env_extra: dict[str, str] | None = None):
    env = {"HOME": str(home), "PATH": os.environ.get("PATH", "")}
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        [sys.executable, "install.py"],
        cwd=dotfiles, env=env,
        capture_output=True, text=True, timeout=120,
    )


def _git(*args, cwd=None, check=True):
    return subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=True,
        check=check, env=_ISOLATE_GIT_ENV,
    )


def _hooks_path_of(repo_dir: Path) -> str:
    r = _git("-C", str(repo_dir), "config", "--get", "core.hooksPath", check=False)
    return r.stdout.strip()


class TempDirMixin:
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)


class NestedInsideAnotherRepoTest(TempDirMixin, unittest.TestCase):
    """(a) <DOTFILES> is a plain copy nested inside another repo."""

    def setUp(self):
        super().setUp()
        self.outer = self.root / "outer"
        self.outer.mkdir()
        _git("init", "-q", cwd=self.outer)
        self.dotfiles = self.outer / "nested" / "dotfiles"
        self.dotfiles.mkdir(parents=True)
        _copy_tracked_tree(self.dotfiles)
        _stub_legacy_provisioner(self.dotfiles)
        self.home = self.root / "home"
        _seed_home(self.home)

    def test_fixed_installer_refuses_and_leaves_outer_config_untouched(self):
        before = _hooks_path_of(self.outer)
        self.assertEqual(before, "", "precondition: outer repo starts with no hooksPath")

        result = _run_install(self.dotfiles, self.home)

        self.assertEqual(_hooks_path_of(self.outer), "",
                          "outer repo's core.hooksPath must remain unset")
        self.assertIn("issue #70", result.stdout)
        self.assertIn("Refusing to write core.hooksPath", result.stdout)

    def test_bug_reproduces_on_main_install_py(self):
        """Same scenario, but with install.py exactly as it is on `main`
        (fetched via `git archive`, never a checkout) -- proves the bug this
        PR fixes is real, not just a hypothetical the new checks guard
        against a strawman."""
        outer = self.root / "outer-main"
        outer.mkdir()
        _git("init", "-q", cwd=outer)
        dotfiles = outer / "nested" / "dotfiles"
        dotfiles.mkdir(parents=True)
        _archive_main_tree(dotfiles)
        _stub_legacy_provisioner(dotfiles)
        home = self.root / "home-main"
        _seed_home(home)

        self.assertEqual(_hooks_path_of(outer), "")

        _run_install(dotfiles, home)

        corrupted = _hooks_path_of(outer)
        self.assertEqual(
            corrupted, str(dotfiles / "hooks"),
            "main's install.py is expected to (wrongly) repoint the OUTER "
            "repo's core.hooksPath at the nested copy's hooks/ dir -- if this "
            "assertion fails, main's install.py is no longer vulnerable and "
            "this demonstration (not the fix itself) needs updating",
        )


class GitDirEnvLeakTest(TempDirMixin, unittest.TestCase):
    """(b) GIT_DIR/GIT_WORK_TREE leaked in via the environment."""

    def setUp(self):
        super().setUp()
        self.other = self.root / "other"
        self.other.mkdir()
        _git("init", "-q", cwd=self.other)
        self.dotfiles = self.root / "dotfiles"
        self.dotfiles.mkdir()
        _copy_tracked_tree(self.dotfiles)
        _stub_legacy_provisioner(self.dotfiles)
        self.home = self.root / "home"
        _seed_home(self.home)
        self.leak_env = {
            "GIT_DIR": str(self.other / ".git"),
            "GIT_WORK_TREE": str(self.other),
        }

    def test_fixed_installer_refuses_and_leaves_leaked_repo_untouched(self):
        before = _hooks_path_of(self.other)
        self.assertEqual(before, "")

        result = _run_install(self.dotfiles, self.home, self.leak_env)

        self.assertEqual(_hooks_path_of(self.other), "",
                          "the repo named by the leaked GIT_DIR must be unaffected")
        self.assertIn("issue #70", result.stdout)
        self.assertIn("Refusing to write core.hooksPath", result.stdout)

    def test_bug_reproduces_on_main_install_py(self):
        other = self.root / "other-main"
        other.mkdir()
        _git("init", "-q", cwd=other)
        dotfiles = self.root / "dotfiles-main"
        dotfiles.mkdir()
        _archive_main_tree(dotfiles)
        _stub_legacy_provisioner(dotfiles)
        home = self.root / "home-main"
        _seed_home(home)
        leak_env = {"GIT_DIR": str(other / ".git"), "GIT_WORK_TREE": str(other)}

        self.assertEqual(_hooks_path_of(other), "")

        _run_install(dotfiles, home, leak_env)

        self.assertEqual(
            _hooks_path_of(other), str(dotfiles / "hooks"),
            "main's install.py is expected to (wrongly) honor the leaked "
            "GIT_DIR and repoint the OTHER repo's core.hooksPath -- if this "
            "assertion fails, main's install.py is no longer vulnerable and "
            "this demonstration (not the fix itself) needs updating",
        )


class NormalCaseStillSetsHooksPathTest(TempDirMixin, unittest.TestCase):
    """(c) <DOTFILES> is its own repo root -- the ordinary, intended case."""

    def setUp(self):
        super().setUp()
        self.dotfiles = self.root / "dotfiles"
        self.dotfiles.mkdir()
        _copy_tracked_tree(self.dotfiles)
        _git("init", "-q", cwd=self.dotfiles)
        _stub_legacy_provisioner(self.dotfiles)
        self.home = self.root / "home"
        _seed_home(self.home)

    def test_hookspath_still_set_when_dotfiles_is_its_own_repo(self):
        result = _run_install(self.dotfiles, self.home)
        self.assertEqual(
            _hooks_path_of(self.dotfiles), str(self.dotfiles / "hooks"),
            result.stderr,
        )
        self.assertIn("core.hooksPath ->", result.stdout)


class LinkedWorktreeTest(TempDirMixin, unittest.TestCase):
    """(d) <DOTFILES> is a linked worktree of a primary checkout."""

    def setUp(self):
        super().setUp()
        self.primary = self.root / "primary"
        self.primary.mkdir()
        _copy_tracked_tree(self.primary)
        _stub_legacy_provisioner(self.primary)
        _git("init", "-q", cwd=self.primary)
        _git("add", "-A", cwd=self.primary)
        _git(
            "-c", "user.name=Test", "-c", "user.email=test@example.com",
            "commit", "-q", "-m", "init",
            cwd=self.primary,
        )
        self.worktree = self.root / "worktree-copy"
        _git(
            "-C", str(self.primary), "worktree", "add",
            str(self.worktree), "-b", "worktree-branch",
        )
        self.home = self.root / "home"
        _seed_home(self.home)

    def test_linked_worktree_refuses_shared_config_write(self):
        before = _hooks_path_of(self.primary)
        self.assertEqual(before, "")

        result = _run_install(self.worktree, self.home)

        self.assertEqual(
            _hooks_path_of(self.primary), "",
            "the PRIMARY checkout's shared core.hooksPath must remain unset "
            "-- writing it from a linked worktree would repoint hooks for "
            "every worktree sharing this .git/config",
        )
        self.assertIn("issue #70", result.stdout)
        self.assertIn("linked git worktree", result.stdout)


if __name__ == "__main__":
    unittest.main()
