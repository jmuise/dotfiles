#!/usr/bin/env python3
"""dotfiles -- user-facing CLI for this checkout. Linked to ~/.local/bin/dotfiles
by install.py, alongside the other user commands in tools/ (start-project,
smart-editor).

Today this has exactly one subcommand:

    dotfiles profile                 # print the active profile and its source
    dotfiles profile <bare|inline|agentic>  # switch profiles
    dotfiles profile <name> --dry-run       # preview the switch, change nothing

See profile/README.md for the full `bare ⊂ inline ⊂ agentic` contract this
wraps. This file contains NO profile-parsing logic of its own -- it is a thin
wrapper around profile/profile.py's resolve_profile()/write_profile() (the
one shared implementation; see that module's own "do not add a second parser"
rule) plus two subprocess calls: this checkout's own install.py (Layer 2,
the symlink farm) and, if available, `ansible-playbook provision/site.yml`
(Layer 1, machine state).

Switching profiles is three steps, in order:
  1. Validate the requested name and write it to the profile file --
     write_profile() already carries the issue-#29 symlink-ancestry check
     (warn + skip, never raise) and the atomic temp-file-plus-rename write;
     this module does not re-implement either.
  2. Re-run install.py so this checkout's own symlinks (~/.claude,
     ~/.config/kilo, ~/.copilot) match the new profile immediately.
  3. If `ansible-playbook` is on PATH, re-run provision/site.yml scoped to
     the tags that matter for a profile switch (packages, not e.g. macOS
     defaults) so machine-level state (AI CLI installs) matches too. If it
     is not on PATH, print the exact command to run by hand -- never a
     silent skip.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

DOTFILES = Path(__file__).resolve().parent.parent
HOME = Path.home()

# profile/profile.py is the ONE shared implementation of the profile contract
# (profile/README.md) -- same import-by-path pattern install.py and
# profile/test_profile.py already use, aliased away from the stdlib
# `profile` module (cProfile-adjacent) this shadows on sys.path.
sys.path.insert(0, str(DOTFILES / "profile"))
import profile as _profile_mod  # noqa: E402  (profile/profile.py, not stdlib `profile`)

BLUE = "\033[0;34m"; GREEN = "\033[0;32m"; YELLOW = "\033[0;33m"; RED = "\033[0;31m"; RESET = "\033[0m"


def log(m: str) -> None:
    print(f"{BLUE}▶{RESET} {m}")


def success(m: str) -> None:
    print(f"{GREEN}✔{RESET} {m}")


def warn(m: str) -> None:
    print(f"{YELLOW}⚠{RESET} {m}")


def error(m: str) -> None:
    print(f"{RED}✖{RESET} {m}", file=sys.stderr)


# The Ansible tags that matter for a profile switch. Only `packages` +
# `ai_clis` today -- see provision/site.yml and
# provision/roles/packages/tasks/main.yml, which tag the profile-gated AI CLI
# install task `ai_clis` specifically so a profile switch doesn't have to
# re-run the whole apt/brew package sweep (slow, needs sudo) just to pick up
# claude/copilot going in or out. Kept as a tuple (not a single string) so a
# future consumer of provision/site.yml's tags doesn't have to re-split one.
ANSIBLE_TAGS = ("ai_clis",)


def _print_profile(dry_run: bool) -> int:
    """`dotfiles profile` with no argument: print the resolved profile + its
    source, and do nothing else -- this is a read, never a write, regardless
    of --dry-run (there is nothing to preview)."""
    path = _profile_mod.profile_path()
    try:
        is_symlink = path.is_symlink()
    except OSError:
        is_symlink = False
    file_present = is_symlink or path.exists()

    try:
        active = _profile_mod.resolve_profile()
    except _profile_mod.ProfileError as exc:
        error(f"Invalid dotfiles profile: {exc}")
        return 1

    source = str(path) if file_present else "default (no profile file present)"
    print(f"{active}  (source: {source})")
    return 0


def _run_install(dry_run: bool) -> int:
    cmd = [sys.executable, str(DOTFILES / "install.py")]
    if dry_run:
        cmd.append("--dry-run")
    log(f"Re-running the Layer 2 linker: {' '.join(cmd)}")
    return subprocess.run(cmd, cwd=str(DOTFILES)).returncode


def _ansible_command(name: str, dry_run: bool) -> list[str]:
    cmd = ["ansible-playbook", "site.yml", "-e", f"profile={name}"]
    for tag in ANSIBLE_TAGS:
        cmd += ["--tags", tag]
    if dry_run:
        cmd += ["--check", "--diff"]
    return cmd


def _run_ansible(name: str, dry_run: bool) -> int:
    """Re-run Layer 1 (machine state) scoped to the tags a profile switch
    actually needs. Returns 0 if ansible-playbook isn't on PATH at all --
    that is not a failure of this CLI, it just means Layer 1 was never
    installed on this machine (e.g. a bare devcontainer). The exact command
    is always printed so nothing is a silent no-op."""
    provision_dir = DOTFILES / "provision"
    cmd = _ansible_command(name, dry_run)
    printable = "cd " + str(provision_dir) + " && " + " ".join(cmd)

    if shutil.which("ansible-playbook") is None:
        warn(
            f"ansible-playbook not found on PATH -- Layer 1 (machine state) "
            f"was NOT re-run. Run this yourself to apply it for profile '{name}':\n"
            f"  {printable}"
        )
        return 0

    log(f"Re-running Layer 1 (machine state): {printable}")
    return subprocess.run(cmd, cwd=str(provision_dir)).returncode


def _switch_profile(name: str, dry_run: bool) -> int:
    # Strict validation, rejecting before any write: argparse's `choices=`
    # already refused an unknown/mis-cased name before this function is ever
    # called (see build_parser() below) -- this is a second, defence-in-depth
    # check for anyone calling this function directly (e.g. from a test)
    # rather than through main(). Either way, nothing has touched the
    # filesystem yet.
    if name not in _profile_mod.PROFILES:
        error(
            f"'{name}' is not a valid profile; valid values are "
            f"{', '.join(_profile_mod.PROFILES)} (case-sensitive, no fuzzy match)"
        )
        return 1

    path = _profile_mod.profile_path()

    if dry_run:
        print(f"  would write: {name!r} -> {path}")
    else:
        try:
            ok = _profile_mod.write_profile(name)
        except _profile_mod.ProfileError as exc:
            # write_profile() itself already validates `name` before this
            # point, so this branch is unreachable given the check above --
            # kept anyway so a future refactor of either function can't
            # silently turn a validation bug into an uncaught traceback.
            error(str(exc))
            return 1
        if not ok:
            # write_profile() already printed the "is a symlink -- refusing
            # to write" warning to stderr (issue #29's ancestry check). Warn
            # and skip means exactly that: skip, so this returns here
            # without touching the linker or Ansible -- there is nothing new
            # for either of them to apply.
            error(
                f"Profile file left unchanged at {path} -- fix the symlinked "
                "ancestor above, then re-run 'dotfiles profile "
                f"{name}'."
            )
            return 1
        success(f"Wrote profile '{name}' -> {path}")

    rc = _run_install(dry_run)
    if rc != 0:
        error(f"install.py exited {rc} -- stopping before Ansible.")
        return rc

    return _run_ansible(name, dry_run)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dotfiles")
    sub = parser.add_subparsers(dest="command", required=True)

    profile_p = sub.add_parser(
        "profile",
        help="print or switch the active AI-capability profile (bare/inline/agentic)",
    )
    # `choices=` is the strict, case-sensitive, no-fuzzy-match validation the
    # profile/README.md contract requires -- argparse rejects an unknown or
    # mis-cased value here, before main() calls anything that could touch a
    # file.
    profile_p.add_argument(
        "name",
        nargs="?",
        choices=list(_profile_mod.PROFILES),
        metavar="{bare,inline,agentic}",
        help="profile to switch to; omit to print the current one",
    )
    profile_p.add_argument(
        "--dry-run",
        action="store_true",
        help="preview the switch (profile file, install.py, ansible-playbook) without changing anything",
    )
    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)

    if args.command == "profile":
        if args.name is None:
            return _print_profile(args.dry_run)
        return _switch_profile(args.name, args.dry_run)

    return 2  # unreachable: subparsers are required=True with one choice today


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
