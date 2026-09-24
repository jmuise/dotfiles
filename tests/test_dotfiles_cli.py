#!/usr/bin/env python3
"""Regression tests for the `dotfiles profile` CLI (tools/dotfiles.py, #40).

Runs the CLI for real -- never mocked -- against a throwaway, freshly
`git init`-ed COPY of this checkout's tracked (or about-to-be-committed)
working-tree content, with a sandbox $HOME, exactly the pattern
tests/test_install_ai_gate.py established: see that file's docstring for why
this never touches the real $HOME, this worktree, or the canonical
checkout's shared .git/config.

legacy/provision_legacy.py is stubbed to a no-op in every sandbox copy (same
reason as test_install_ai_gate.py: it is unrelated machine-state
provisioning and running it for real would need network access).
git/ensure-gcm.sh is short-circuited by pre-seeding a [credential] block in
~/.gitconfig.local, same as test_install_ai_gate.py.

`ansible-playbook` is controlled explicitly per test via PATH, rather than
however it happens to be installed (or not) on the machine running these
tests, so the Ansible-integration assertions are deterministic in CI either
way:
  * "absent" tests use a PATH containing only /usr/bin:/bin (git, python3,
    find -- no ansible-playbook).
  * "present" tests prepend a tiny stub `ansible-playbook` shell script that
    records its argv and cwd to a file instead of doing anything real, so
    this never depends on network access or an actual Ansible install.

Run directly: ``python3 tests/test_dotfiles_cli.py``
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
NO_ANSIBLE_PATH = "/usr/bin:/bin"


def _tracked_files() -> list[Path]:
    out = subprocess.run(
        ["git", "-C", str(REPO), "ls-files"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [REPO / p for p in out.splitlines() if p]


class DotfilesCliTestBase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.dotfiles = root / "dotfiles"
        self.home = root / "home"
        self.home.mkdir()

        for src in _tracked_files():
            if not src.is_file():
                continue
            rel = src.relative_to(REPO)
            dst = self.dotfiles / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
        (self.dotfiles / "tools" / "dotfiles.py").chmod(0o755)

        subprocess.run(["git", "init", "-q"], cwd=self.dotfiles, check=True)

        legacy = self.dotfiles / "legacy" / "provision_legacy.py"
        legacy.write_text(
            "#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n", encoding="utf-8"
        )

        (self.home / ".gitconfig.local").write_text(
            "[credential]\n\thelper = cache\n", encoding="utf-8"
        )

        self.profile_path = self.home / ".config" / "dotfiles" / "profile"

    def run_cli(self, *args, path=NO_ANSIBLE_PATH, timeout=60):
        env = {"HOME": str(self.home), "PATH": path}
        return subprocess.run(
            [sys.executable, str(self.dotfiles / "tools" / "dotfiles.py"), *args],
            cwd=self.dotfiles, env=env, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=timeout,
        )

    def stub_ansible_path(self, marker: Path) -> str:
        """A PATH whose `ansible-playbook` records argv+cwd to `marker`
        instead of doing anything real, then exits 0."""
        bindir = Path(self._tmp.name) / "stubbin"
        bindir.mkdir(exist_ok=True)
        stub = bindir / "ansible-playbook"
        stub.write_text(
            "#!/usr/bin/env bash\n"
            f'{{ echo "cwd=$PWD"; printf \'%s\\n\' "$@"; }} > "{marker}"\n'
            "exit 0\n",
            encoding="utf-8",
        )
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        return f"{bindir}:{NO_ANSIBLE_PATH}"

    def ai_symlinks(self):
        out = subprocess.run(
            ["find", str(self.home), "-type", "l"],
            capture_output=True, text=True, check=True,
        ).stdout
        gated = ("/.claude/", "/.config/kilo/", "/.copilot/")
        return sorted(line for line in out.splitlines() if any(g in line for g in gated))


class InvalidNameTest(DotfilesCliTestBase):
    def test_invalid_name_rejected_before_any_write(self):
        result = self.run_cli("profile", "full")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.profile_path.exists())
        self.assertFalse(self.profile_path.parent.exists())
        self.assertNotIn("Re-running the Layer 2 linker", result.stdout)

    def test_case_sensitive_no_fuzzy_match(self):
        for bad in ("AGENTIC", "Agentic", "Bare", "agentic "):
            with self.subTest(bad=bad):
                result = self.run_cli("profile", bad)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.profile_path.exists())


class AncestorSymlinkTest(DotfilesCliTestBase):
    def test_symlinked_config_ancestor_warns_and_skips(self):
        evil = Path(self._tmp.name) / "evil"
        evil.mkdir()
        (self.home / ".config").symlink_to(evil)

        result = self.run_cli("profile", "bare")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is a symlink", result.stderr)
        self.assertIn("refusing to write", result.stderr)
        self.assertIn("Profile file left unchanged", result.stderr)
        # Nothing landed through the redirected ~/.config, and the linker
        # was never invoked -- there is nothing new for it to apply.
        self.assertFalse((evil / "dotfiles").exists())
        self.assertNotIn("Re-running the Layer 2 linker", result.stdout)


class DryRunTest(DotfilesCliTestBase):
    def test_dry_run_writes_nothing(self):
        # Establish a real agentic baseline first.
        baseline = self.run_cli("profile", "agentic")
        self.assertEqual(baseline.returncode, 0, baseline.stderr)
        before_links = self.ai_symlinks()
        self.assertTrue(before_links)
        before_content = self.profile_path.read_text(encoding="utf-8")

        result = self.run_cli("profile", "bare", "--dry-run")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("would write", result.stdout)
        self.assertIn("DRY RUN", result.stdout)
        # The file itself is untouched...
        self.assertEqual(self.profile_path.read_text(encoding="utf-8"), before_content)
        # ...and so is every symlink dry-run would have removed.
        self.assertEqual(self.ai_symlinks(), before_links)

    def test_dry_run_passes_through_to_install_and_ansible(self):
        marker = Path(self._tmp.name) / "ansible_argv"
        result = self.run_cli(
            "profile", "bare", "--dry-run", path=self.stub_ansible_path(marker)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--dry-run", result.stdout)  # install.py invocation line
        self.assertTrue(marker.exists(), "ansible-playbook stub was never invoked")
        argv = marker.read_text(encoding="utf-8").splitlines()
        self.assertIn("--check", argv)
        self.assertIn("--diff", argv)
        self.assertIn("profile=bare", argv)


class AtomicWriteAndRoundTripTest(DotfilesCliTestBase):
    def test_write_then_read_back_no_leftover_tempfiles(self):
        result = self.run_cli("profile", "inline")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.profile_path.read_text(encoding="utf-8"), "inline\n")
        leftovers = [p.name for p in self.profile_path.parent.iterdir() if p.name != "profile"]
        self.assertEqual(leftovers, [])

        read_back = self.run_cli("profile")
        self.assertEqual(read_back.returncode, 0, read_back.stderr)
        self.assertIn("inline", read_back.stdout)
        self.assertIn(str(self.profile_path), read_back.stdout)

    def test_inline_links_no_ai_directories_today(self):
        # See PR body: PR #64 shipped inline == bare for the AI-gated
        # directories, and #40 keeps that (documented, open decision for the
        # Captain) rather than forking claude/CLAUDE.md's content. This test
        # pins the CURRENT behaviour so a future change is a deliberate,
        # visible diff to this test, not a silent regression either way.
        result = self.run_cli("profile", "inline")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.ai_symlinks(), [])


class NoArgumentPrintsSourceTest(DotfilesCliTestBase):
    def test_absent_file_prints_default_source(self):
        result = self.run_cli("profile")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("agentic", result.stdout)
        self.assertIn("default", result.stdout)

    def test_present_file_prints_its_path_as_source(self):
        write = self.run_cli("profile", "bare")
        self.assertEqual(write.returncode, 0, write.stderr)

        result = self.run_cli("profile")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bare", result.stdout)
        self.assertIn(str(self.profile_path), result.stdout)


class AnsibleIntegrationTest(DotfilesCliTestBase):
    def test_ansible_absent_prints_exact_command(self):
        result = self.run_cli("profile", "agentic", path=NO_ANSIBLE_PATH)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ansible-playbook not found on PATH", result.stdout)
        self.assertIn(
            "ansible-playbook site.yml -e profile=agentic --tags ai_clis",
            result.stdout,
        )

    def test_ansible_present_invoked_with_expected_args_and_cwd(self):
        marker = Path(self._tmp.name) / "ansible_argv"
        result = self.run_cli(
            "profile", "agentic", path=self.stub_ansible_path(marker)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(marker.exists())
        lines = marker.read_text(encoding="utf-8").splitlines()
        self.assertEqual(lines[0], f"cwd={self.dotfiles / 'provision'}")
        argv = lines[1:]
        self.assertEqual(argv[:2], ["site.yml", "-e"])
        self.assertIn("profile=agentic", argv)
        self.assertIn("ai_clis", argv)
        self.assertNotIn("--check", argv)


if __name__ == "__main__":
    unittest.main()
