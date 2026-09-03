#!/usr/bin/env python3
"""Tests for profile/profile.py -- one assertion per rule in the contract.

Run directly: ``python3 profile/test_profile.py`` (uses stdlib unittest, no
third-party deps). ``profile/run-tests.sh`` runs this plus the shell suite.
"""

import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import profile as mod  # noqa: E402


class ResolveTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.path = self.tmp / ".config" / "dotfiles" / "profile"
        self.path.parent.mkdir(parents=True)
        self.addCleanup(self._tmp.cleanup)

    def write(self, data):
        if isinstance(data, bytes):
            self.path.write_bytes(data)
        else:
            self.path.write_text(data, encoding="utf-8")

    def resolve(self):
        # swallow the symlink warning lines; assertions target the return value
        with contextlib.redirect_stderr(io.StringIO()):
            return mod.resolve_profile(self.path, home=self.tmp)

    # rule 1
    def test_absent_resolves_to_agentic(self):
        self.assertFalse(self.path.exists())
        self.assertEqual(self.resolve(), "agentic")

    # rule 2 -- the three canonical values
    def test_each_valid_value(self):
        for name in ("bare", "inline", "agentic"):
            self.write(name)
            self.assertEqual(self.resolve(), name)

    # rule 2 -- trailing / surrounding whitespace is trimmed
    def test_trailing_newline_ok(self):
        self.write("agentic\n")
        self.assertEqual(self.resolve(), "agentic")

    def test_many_trailing_newlines_ok(self):
        self.write("agentic\n\n\n")
        self.assertEqual(self.resolve(), "agentic")

    def test_leading_and_trailing_blanks_ok(self):
        self.write("  inline  ")
        self.assertEqual(self.resolve(), "inline")

    def test_tabs_and_crlf_trimmed(self):
        self.write("\t\r\nbare\r\n\t")
        self.assertEqual(self.resolve(), "bare")

    # rule 3
    def test_empty_file_errors(self):
        self.write("")
        with self.assertRaises(mod.ProfileError):
            self.resolve()

    def test_whitespace_only_errors(self):
        self.write("   \n\t\n")
        with self.assertRaises(mod.ProfileError):
            self.resolve()

    # rule 4
    def test_two_words_error(self):
        self.write("agentic bare")
        with self.assertRaises(mod.ProfileError):
            self.resolve()

    def test_second_line_error(self):
        self.write("agentic\nbare\n")
        with self.assertRaises(mod.ProfileError):
            self.resolve()

    def test_internal_space_error(self):
        self.write("agen tic")
        with self.assertRaises(mod.ProfileError):
            self.resolve()

    # rule 5 -- unknown words
    def test_unknown_word_error(self):
        for bad in ("full", "none", "agent", "on", "yes", "default"):
            self.write(bad)
            with self.assertRaises(mod.ProfileError):
                self.resolve()

    # rule 5 -- case sensitivity
    def test_case_sensitive(self):
        for bad in ("AGENTIC", "Agentic", "BARE", "Bare", "Inline", "INLINE"):
            self.write(bad)
            with self.assertRaises(mod.ProfileError):
                self.resolve()

    # rule 6 -- not a regular file
    def test_directory_at_path_errors(self):
        self.path.rmdir() if self.path.exists() else None
        self.path.mkdir()
        with self.assertRaises(mod.ProfileError):
            self.resolve()

    def test_broken_symlink_errors(self):
        self.path.symlink_to(self.tmp / "does-not-exist")
        with self.assertRaises(mod.ProfileError):
            self.resolve()

    # rule 7
    def test_invalid_utf8_errors(self):
        self.write(b"\xff\xfe\xfa")
        with self.assertRaises(mod.ProfileError):
            self.resolve()

    # never silently falls open to agentic on a bad value
    def test_invalid_never_returns_agentic(self):
        for bad in ("", "   ", "AGENTIC", "full", "agentic bare"):
            self.write(bad)
            with self.assertRaises(mod.ProfileError):
                self.resolve()


class SymlinkAncestryReadTests(unittest.TestCase):
    """A symlink in the ancestry warns but does not fail a *read*."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_symlinked_file_warns_and_still_reads(self):
        real = self.tmp / "real-profile"
        real.write_text("inline\n", encoding="utf-8")
        link = self.tmp / ".config" / "dotfiles" / "profile"
        link.parent.mkdir(parents=True)
        link.symlink_to(real)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            got = mod.resolve_profile(link, home=self.tmp)
        self.assertEqual(got, "inline")
        self.assertIn("is a symlink", err.getvalue())

    def test_symlinked_ancestor_warns_and_still_reads(self):
        realdir = self.tmp / "real-config"
        (realdir / "dotfiles").mkdir(parents=True)
        (realdir / "dotfiles" / "profile").write_text("bare\n", encoding="utf-8")
        (self.tmp / ".config").symlink_to(realdir)
        path = self.tmp / ".config" / "dotfiles" / "profile"
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            got = mod.resolve_profile(path, home=self.tmp)
        self.assertEqual(got, "bare")
        self.assertIn("is a symlink", err.getvalue())


class AtLeastTests(unittest.TestCase):
    def test_nesting_true(self):
        self.assertTrue(mod.profile_at_least("bare", "bare"))
        self.assertTrue(mod.profile_at_least("inline", "bare"))
        self.assertTrue(mod.profile_at_least("agentic", "bare"))
        self.assertTrue(mod.profile_at_least("inline", "inline"))
        self.assertTrue(mod.profile_at_least("agentic", "inline"))
        self.assertTrue(mod.profile_at_least("agentic", "agentic"))

    def test_nesting_false(self):
        self.assertFalse(mod.profile_at_least("bare", "inline"))
        self.assertFalse(mod.profile_at_least("bare", "agentic"))
        self.assertFalse(mod.profile_at_least("inline", "agentic"))

    def test_bad_name_raises(self):
        with self.assertRaises(mod.ProfileError):
            mod.profile_at_least("agentic", "full")
        with self.assertRaises(mod.ProfileError):
            mod.profile_at_least("AGENTIC", "bare")


class ProfilePathTests(unittest.TestCase):
    def test_uses_xdg_config_home(self):
        with _env(XDG_CONFIG_HOME="/somewhere/cfg"):
            self.assertEqual(
                mod.profile_path(), Path("/somewhere/cfg/dotfiles/profile")
            )

    def test_empty_xdg_falls_back_to_home_config(self):
        with _env(XDG_CONFIG_HOME=""):
            self.assertEqual(
                mod.profile_path(), Path.home() / ".config" / "dotfiles" / "profile"
            )

    def test_explicit_override_wins(self):
        with _env(XDG_CONFIG_HOME="/somewhere/cfg"):
            self.assertEqual(
                mod.profile_path("/other"), Path("/other/dotfiles/profile")
            )


class WriteTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.path = self.tmp / ".config" / "dotfiles" / "profile"

    def test_writes_and_creates_parents(self):
        self.assertFalse(self.path.parent.exists())
        ok = mod.write_profile("bare", self.path, home=self.tmp)
        self.assertTrue(ok)
        self.assertEqual(self.path.read_text(encoding="utf-8"), "bare\n")

    def test_written_value_round_trips_through_reader(self):
        mod.write_profile("inline", self.path, home=self.tmp)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(
                mod.resolve_profile(self.path, home=self.tmp), "inline"
            )

    def test_overwrite_is_atomic_replace(self):
        mod.write_profile("agentic", self.path, home=self.tmp)
        mod.write_profile("bare", self.path, home=self.tmp)
        self.assertEqual(self.path.read_text(encoding="utf-8"), "bare\n")
        # no stray temp files left behind
        leftovers = [p.name for p in self.path.parent.iterdir() if p.name != "profile"]
        self.assertEqual(leftovers, [])

    def test_invalid_name_raises_and_writes_nothing(self):
        with self.assertRaises(mod.ProfileError):
            mod.write_profile("full", self.path, home=self.tmp)
        with self.assertRaises(mod.ProfileError):
            mod.write_profile("AGENTIC", self.path, home=self.tmp)
        self.assertFalse(self.path.exists())
        self.assertFalse(self.path.parent.exists())

    def test_symlinked_ancestor_skips_write_and_warns(self):
        # ~/.config is an attacker-planted symlink to a dir they control
        evil = self.tmp / "evil"
        evil.mkdir()
        (self.tmp / ".config").symlink_to(evil)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            ok = mod.write_profile("agentic", self.path, home=self.tmp)
        self.assertFalse(ok)
        self.assertIn("is a symlink", err.getvalue())
        self.assertIn("refusing to write", err.getvalue())
        # nothing was written through the symlink
        self.assertFalse((evil / "dotfiles").exists())

    def test_symlinked_file_itself_skips_write(self):
        self.path.parent.mkdir(parents=True)
        target = self.tmp / "target"
        self.path.symlink_to(target)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            ok = mod.write_profile("bare", self.path, home=self.tmp)
        self.assertFalse(ok)
        self.assertFalse(target.exists())

    def test_symlink_check_runs_before_mkdir(self):
        # deeper: ~/.config/dotfiles would be created by mkdir(parents=True);
        # the symlink is one level up, so the check must fire before mkdir.
        evil = self.tmp / "evil"
        evil.mkdir()
        (self.tmp / ".config").symlink_to(evil)
        with contextlib.redirect_stderr(io.StringIO()):
            mod.write_profile("bare", self.path, home=self.tmp)
        self.assertFalse((evil / "dotfiles").exists())


class CliTests(unittest.TestCase):
    """Exercise the actual `python3 profile.py` entry point Ansible uses."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.cfg = self.tmp / "cfg"
        (self.cfg / "dotfiles").mkdir(parents=True)
        self.path = self.cfg / "dotfiles" / "profile"
        self.addCleanup(self._tmp.cleanup)

    def run_cli(self, *args):
        env = dict(os.environ)
        env["XDG_CONFIG_HOME"] = str(self.cfg)
        return subprocess.run(
            [sys.executable, str(HERE / "profile.py"), *args],
            capture_output=True, text=True, env=env,
        )

    def test_absent_prints_agentic_exit_0(self):
        r = self.run_cli()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "agentic")

    def test_valid_prints_value_exit_0(self):
        self.path.write_text("inline\n", encoding="utf-8")
        r = self.run_cli()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "inline")

    def test_invalid_exit_2_stderr(self):
        self.path.write_text("full\n", encoding="utf-8")
        r = self.run_cli()
        self.assertEqual(r.returncode, 2)
        self.assertEqual(r.stdout, "")
        self.assertIn("profile:", r.stderr)

    def test_empty_exit_2(self):
        self.path.write_text("", encoding="utf-8")
        r = self.run_cli()
        self.assertEqual(r.returncode, 2)

    def test_at_least_satisfied_exit_0(self):
        self.path.write_text("agentic\n", encoding="utf-8")
        self.assertEqual(self.run_cli("--at-least", "inline").returncode, 0)

    def test_at_least_not_satisfied_exit_1(self):
        self.path.write_text("bare\n", encoding="utf-8")
        self.assertEqual(self.run_cli("--at-least", "agentic").returncode, 1)

    def test_at_least_broken_file_exit_2(self):
        self.path.write_text("nonsense\n", encoding="utf-8")
        self.assertEqual(self.run_cli("--at-least", "bare").returncode, 2)

    def test_at_least_absent_uses_default(self):
        # absent -> agentic, so "--at-least inline" is satisfied
        self.assertEqual(self.run_cli("--at-least", "inline").returncode, 0)

    def test_bad_argument_exit_2(self):
        self.assertEqual(self.run_cli("--bogus").returncode, 2)


@contextlib.contextmanager
def _env(**kw):
    saved = {k: os.environ.get(k) for k in kw}
    try:
        for k, v in kw.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        yield
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


if __name__ == "__main__":
    unittest.main(verbosity=2)
