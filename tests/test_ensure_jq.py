#!/usr/bin/env python3
"""Tests for the jq-in-devcontainer fix (issue #88).

The Claude PreToolUse guards are fail-closed and parse their input with jq, so
a container without jq blocked every Bash/Edit/Write call with a misleading
"the guard itself failed" message. Covered here, all against real subprocess
runs in a sandbox $HOME with a hand-built PATH (never the host's jq):

  * each of the three guards, with no jq anywhere, exits 2 and says
    "jq not found" plus the remedy (and still fails CLOSED);
  * with jq only in $HOME/.local/bin (not on PATH) the guards find it;
  * rtk-rewrite.sh still exits 0 (it is deliberately fail-open) with a warning;
  * tools/ensure-jq.sh: no-op when jq is on PATH or already in ~/.local/bin,
    exit 1 on an unsupported arch, and exit 3 on a checksum mismatch, which
    installs nothing and leaves no temp file behind;
  * install.py aborts on exit 3 and only warns on any other non-zero exit.

The success download path needs the network and is exercised manually (see
the PR), not here.

Run directly: ``python3 tests/test_ensure_jq.py``
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
HOOKS = REPO / "claude" / "hooks"
ENSURE = REPO / "tools" / "ensure-jq.sh"
GUARDS = ["block-pr-merge.sh", "block-ai-attribution.sh", "require-devcontainer.sh"]
PAYLOAD = '{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/workspaces/x"}'
# Tools the scripts under test need, linked into a private bin dir so the PATH
# contains them and provably NOT jq, whatever the host has installed.
TOOLS = ["bash", "cat", "dirname", "mktemp", "awk", "sha256sum", "mv", "rm",
         "mkdir", "chmod", "grep", "sed", "tr", "uname", "git"]


class Sandbox:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="ensure-jq-test-"))
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.home.mkdir()
        self.bin.mkdir()
        for t in TOOLS:
            p = shutil.which(t)
            if p:
                (self.bin / t).symlink_to(p)

    def stub(self, name, body, where=None):
        d = where or self.bin
        d.mkdir(parents=True, exist_ok=True)
        f = d / name
        f.write_text("#!/bin/sh\n" + body)
        f.chmod(0o755)

    def run(self, script, stdin="", env_extra=None):
        env = {"PATH": str(self.bin), "HOME": str(self.home)}
        env.update(env_extra or {})
        return subprocess.run([str(self.bin / "bash"), str(script)], input=stdin,
                              capture_output=True, text=True, env=env, timeout=60)

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


class JqTestCase(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.addCleanup(self.sb.cleanup)


class GuardsWithoutJq(JqTestCase):
    def test_guards_fail_closed_with_jq_not_found(self):
        for g in GUARDS:
            with self.subTest(guard=g):
                r = self.sb.run(HOOKS / g, PAYLOAD)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertIn("jq not found", r.stderr)
                self.assertIn("ensure-jq.sh", r.stderr)
                self.assertNotIn("guard itself failed", r.stderr)

    def test_guards_find_jq_in_local_bin_off_path(self):
        self.sb.stub("jq", 'echo ""', where=self.sb.home / ".local" / "bin")
        for g in GUARDS:
            with self.subTest(guard=g):
                r = self.sb.run(HOOKS / g, PAYLOAD)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertNotIn("jq not found", r.stderr)

    def test_rtk_rewrite_stays_fail_open(self):
        r = self.sb.run(HOOKS / "rtk-rewrite.sh", PAYLOAD)
        self.assertEqual(r.returncode, 0)
        self.assertIn("jq is not installed", r.stderr)


class EnsureJq(JqTestCase):
    def test_noop_when_jq_on_path(self):
        self.sb.stub("jq", "echo jq-stub")
        r = self.sb.run(ENSURE)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("already on PATH", r.stdout)
        self.assertFalse((self.sb.home / ".local" / "bin" / "jq").exists())

    def test_noop_when_jq_already_in_local_bin(self):
        self.sb.stub("jq", "echo jq-stub", where=self.sb.home / ".local" / "bin")
        r = self.sb.run(ENSURE)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("already present", r.stdout)

    def test_unsupported_arch_fails_cleanly(self):
        (self.sb.bin / "uname").unlink()
        self.sb.stub("uname", "echo riscv64")
        r = self.sb.run(ENSURE)
        self.assertEqual(r.returncode, 1)
        self.assertIn("Unsupported architecture riscv64", r.stderr)
        self.assertFalse((self.sb.home / ".local" / "bin" / "jq").exists())

    def test_checksum_mismatch_installs_nothing(self):
        (self.sb.bin / "uname").unlink()
        self.sb.stub("uname", "echo x86_64")
        # fake curl: writes attacker-controlled bytes to the -o target
        self.sb.stub("curl", 'while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done\n'
                             'echo not-a-real-jq > "$out"\n')
        r = self.sb.run(ENSURE)
        # 3 (not the generic 1): install.py aborts on it but only warns on 1.
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("Checksum mismatch", r.stderr)
        local_bin = self.sb.home / ".local" / "bin"
        self.assertEqual(sorted(p.name for p in local_bin.iterdir()), [])


class InstallPyBranching(JqTestCase):
    """install.py's reaction to ensure-jq.sh's exit status, run for real in a
    devcontainer-flagged scratch copy (never this checkout) with ensure-jq.sh
    stubbed to a fixed exit code: 3 (checksum mismatch) aborts the install,
    any other non-zero only warns and the install carries on."""

    def _install(self, jq_rc):
        dot = self.sb.root / "dotfiles"
        files = subprocess.run(["git", "-C", str(REPO), "ls-files"], capture_output=True,
                               text=True, check=True).stdout.splitlines()
        for rel in files:
            src = REPO / rel
            if src.is_file():
                (dot / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dot / rel)
        subprocess.run(["git", "init", "-q"], cwd=dot, check=True)
        (dot / "legacy" / "provision_legacy.py").write_text("import sys\nsys.exit(0)\n")
        (dot / "tools" / "ensure-jq.sh").write_text(f"#!/usr/bin/env bash\nexit {jq_rc}\n")
        (self.sb.home / ".gitconfig.local").write_text("[credential]\n\thelper = cache\n")
        env = {"HOME": str(self.sb.home), "PATH": os.environ.get("PATH", ""), "DEVCONTAINER": "1"}
        return subprocess.run([sys.executable, "install.py"], cwd=dot, env=env,
                              capture_output=True, text=True, timeout=120)

    def test_checksum_mismatch_aborts_install(self):
        r = self._install(3)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("SHA256", r.stderr)
        self.assertNotIn("jq could not be installed", r.stdout)

    def test_ordinary_failure_warns_and_continues(self):
        r = self._install(1)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("jq could not be installed", r.stdout)


if __name__ == "__main__":
    unittest.main()
