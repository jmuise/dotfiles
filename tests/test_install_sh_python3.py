#!/usr/bin/env python3
"""Tests for install.sh's python3 bootstrap in devcontainers.

VS Code runs install.sh as dotfiles.installCommand on container creation, and
some base images (mcr.microsoft.com/devcontainers/base:bookworm) ship without
python3, so install.sh used to stop at "python3 not found". It now installs
the distro python3 with apt-get — but only in a container, only as root or via
passwordless ``sudo -n``, and never on a host. Covered here, all against real
subprocess runs of a scratch copy of install.sh with a hand-built PATH
(never the host's python3, apt-get or sudo) and stubbed apt-get/sudo/id:

  * container + root: apt-get update, then install -y --no-install-recommends
    python3, then install.py runs with the freshly installed python3;
  * container + non-root + passwordless sudo: same, through ``sudo -n``;
  * host (no container signal): apt-get is never run, the old error stands;
  * --dry-run prints the command and runs nothing;
  * container + no root and no usable sudo: nothing run, clear error + remedy;
  * apt-get failing: clear error, non-zero exit;
  * python3 already present: no-op, install.py runs.

The host case can't be tested inside a container (/.dockerenv is a container
signal install.sh can't be told to ignore), so it is skipped there.

Run directly: ``python3 tests/test_install_sh_python3.py``
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INSTALL_SH = REPO / "install.sh"
# Tools install.sh itself needs, linked into a private bin dir so the PATH
# provably contains no real python3/apt-get/sudo/git, whatever the host has.
TOOLS = ["bash", "dirname", "env", "cat", "chmod", "true"]
IN_CONTAINER = Path("/.dockerenv").exists()


class Sandbox:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="install-sh-py3-test-"))
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.dot = self.root / "dotfiles"
        self.log = self.root / "calls.log"
        for d in (self.home, self.bin, self.dot):
            d.mkdir()
        for t in TOOLS:
            p = shutil.which(t)
            if p:
                (self.bin / t).symlink_to(p)
        shutil.copy2(INSTALL_SH, self.dot / "install.sh")
        self.log.write_text("")

    def stub(self, name, body):
        f = self.bin / name
        f.write_text("#!/bin/sh\n" + body)
        f.chmod(0o755)

    def add_python3(self):
        self.stub("python3", 'echo "install.py ran: $*"\n')

    def add_id(self, uid):
        self.stub("id", f'[ "$1" = -u ] && echo {uid}\n')

    def add_apt_get(self, fail=False):
        # Logs every call; a successful "install ... python3" drops a python3
        # stub onto PATH, as the real package would.
        py = self.bin / "python3"
        body = f'echo "apt-get $*" >> "{self.log}"\n'
        if fail:
            body += "exit 100\n"
        else:
            body += ('case "$1" in install)\n'
                     f"  printf '%s\\n' '#!/bin/sh' 'echo \"install.py ran: $*\"' > \"{py}\"\n"
                     f'  chmod 755 "{py}";;\nesac\n')
        self.stub("apt-get", body)

    def add_sudo(self, passwordless=True):
        body = f'echo "sudo $*" >> "{self.log}"\n'
        body += '[ "$1" = -n ] || { echo "sudo: test stub requires -n" >&2; exit 1; }\nshift\n'
        if not passwordless:
            body += 'echo "sudo: a password is required" >&2\nexit 1\n'
        else:
            body += 'exec "$@"\n'
        self.stub("sudo", body)

    def run(self, *args, container=True):
        env = {"PATH": str(self.bin), "HOME": str(self.home)}
        if container:
            env["DEVCONTAINER"] = "1"
        return subprocess.run([str(self.bin / "bash"), str(self.dot / "install.sh"), *args],
                              capture_output=True, text=True, env=env, timeout=60)

    def calls(self):
        return self.log.read_text().splitlines()

    def apt_calls(self):
        return [c for c in self.calls() if c.startswith("apt-get")]

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


APT_EXPECTED = ["apt-get update", "apt-get install -y --no-install-recommends python3"]


class InstallShPython3(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.addCleanup(self.sb.cleanup)

    def test_container_root_installs_python3(self):
        self.sb.add_id(0)
        self.sb.add_apt_get()
        self.sb.add_sudo()
        r = self.sb.run()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.sb.apt_calls(), APT_EXPECTED)
        self.assertFalse(any(c.startswith("sudo") for c in self.sb.calls()), self.sb.calls())
        self.assertIn("install.py ran", r.stdout)

    def test_container_nonroot_uses_sudo_n(self):
        self.sb.add_id(1000)
        self.sb.add_apt_get()
        self.sb.add_sudo()
        r = self.sb.run()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.sb.apt_calls(), APT_EXPECTED)
        sudo = [c for c in self.sb.calls() if c.startswith("sudo")]
        self.assertTrue(sudo and all(c.startswith("sudo -n ") for c in sudo), sudo)
        self.assertIn("install.py ran", r.stdout)

    @unittest.skipIf(IN_CONTAINER, "/.dockerenv exists: can't simulate a host here")
    def test_host_never_installs(self):
        self.sb.add_id(0)
        self.sb.add_apt_get()
        self.sb.add_sudo()
        r = self.sb.run(container=False)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.sb.calls(), [])
        self.assertIn("python3 not found", r.stderr)
        self.assertIn("remedy", r.stderr)

    def test_dry_run_prints_but_does_not_install(self):
        self.sb.add_id(1000)
        self.sb.add_apt_get()
        self.sb.add_sudo()
        r = self.sb.run("--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.sb.apt_calls(), [])
        self.assertIn("sudo -n apt-get update && sudo -n apt-get install -y "
                      "--no-install-recommends python3", r.stderr)
        self.assertFalse((self.sb.bin / "python3").exists())

    def test_no_passwordless_sudo_errors_clearly(self):
        self.sb.add_id(1000)
        self.sb.add_apt_get()
        self.sb.add_sudo(passwordless=False)
        r = self.sb.run()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.sb.apt_calls(), [])
        self.assertEqual(self.sb.calls(), ["sudo -n true"])  # probe only, never prompts
        self.assertIn("python3 not found", r.stderr)
        self.assertIn("remedy", r.stderr)

    def test_no_sudo_binary_errors_clearly(self):
        self.sb.add_id(1000)
        self.sb.add_apt_get()
        r = self.sb.run()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.sb.apt_calls(), [])
        self.assertIn("python3 not found", r.stderr)

    def test_apt_get_failure_errors_clearly(self):
        self.sb.add_id(0)
        self.sb.add_apt_get(fail=True)
        r = self.sb.run()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.sb.apt_calls(), ["apt-get update"])
        self.assertIn("apt-get could not install python3", r.stderr)
        self.assertIn("python3 not found", r.stderr)

    def test_python3_present_is_noop(self):
        self.sb.add_id(0)
        self.sb.add_apt_get()
        self.sb.add_sudo()
        self.sb.add_python3()
        r = self.sb.run()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.sb.calls(), [])
        self.assertIn("install.py ran", r.stdout)


if __name__ == "__main__":
    unittest.main()
