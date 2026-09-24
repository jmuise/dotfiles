#!/usr/bin/env python3
"""
install.py -- Layer 2 of the three-layer provisioning split (see issue #35):
the dotfiles symlink farm. No Ansible dependency. Called by install.sh and
install.ps1; not meant to be run directly.

Scope, deliberately narrow:
  * Pure symlinking of this repo's tracked config files into $HOME.
  * Profile-gated linking of the AI config directories (~/.claude,
    ~/.config/kilo, ~/.copilot) -- see resolve_ai_gate() below and
    profile/README.md for the contract.
  * The install receipt (~/.local/state/dotfiles/install-root), preserved
    here rather than deleted, because hooks/_dispatch.sh's #54 security fix
    depends on it naming this checkout. See the "install receipt" section
    below for the full reasoning.
  * The git identity / git-credential-manager prerequisite chain that has to
    run, in order, *before* ~/.gitconfig can be rendered correctly on a
    fresh machine. See the "git" section below for why this one chunk of
    otherwise machine-provisioning-shaped code stays here instead of moving
    to legacy/provision_legacy.py.

Everything else this repo used to do from install.py that is *not* one of
the above -- package/binary installs, CLI installs, credential-store writes,
credential-forwarding checks, macOS defaults -- has moved to
legacy/provision_legacy.py, invoked once near the end of this script. See
that module's docstring for why it exists and when each chunk it carries is
expected to go away.

Usage (via wrappers):
    ./install.sh [--dry-run]
    .\\install.ps1 [-DryRun]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

DOTFILES = Path(__file__).parent.resolve()
HOME = Path.home()

# ── profile reader ───────────────────────────────────────────────────────────
# profile/profile.py is the ONE shared implementation of the profile contract
# (profile/README.md) -- the shell reader, this linker, and Ansible all defer
# to it rather than each parsing the file themselves. Imported by path, same
# pattern profile/test_profile.py already uses, and aliased away from the
# stdlib `profile` module (cProfile-adjacent) that this shadows on sys.path.
sys.path.insert(0, str(DOTFILES / "profile"))
import profile as _profile_mod  # noqa: E402  (profile/profile.py, not stdlib `profile`)

# ── args ──────────────────────────────────────────────────────────────────────
parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("--dry-run", action="store_true")
ARGS = parser.parse_args()
DRY_RUN = ARGS.dry_run

# ── helpers ───────────────────────────────────────────────────────────────────
BLUE = "\033[0;34m"; GREEN = "\033[0;32m"; YELLOW = "\033[0;33m"; RED = "\033[0;31m"; RESET = "\033[0m"

def log(m):     print(f"{BLUE}▶{RESET} {m}")
def success(m): print(f"{GREEN}✔{RESET} {m}")
def warn(m):    print(f"{YELLOW}⚠{RESET} {m}")
def error(m):   print(f"{RED}✖{RESET} {m}", file=sys.stderr)

def link(src: Path, dst: Path) -> bool:
    """Symlink dst -> src. Returns True iff this changed dst on disk (or would,
    under --dry-run) -- i.e. dst wasn't already correctly linked to src. Callers
    use this to tell a real change from a no-op re-link, e.g. to decide whether
    a shell-init file actually changed and a new shell is needed."""
    src, dst = Path(src), Path(dst)
    already_linked = dst.is_symlink() and dst.readlink() == src
    if DRY_RUN:
        print(f"  {'up to date' if already_linked else 'link'}: {src} → {dst}")
        return not already_linked
    if already_linked:
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.is_symlink():
        dst.unlink()
    elif dst.exists():
        warn(f"Backing up {dst} → {dst}.bak"); dst.replace(str(dst) + ".bak")
    dst.symlink_to(src)
    success(f"linked {dst}")
    return True

def unlink_gated(dst: Path) -> None:
    """Remove dst iff it is a symlink pointing INTO this checkout.

    Used when a profile switch narrows and a previously-linked AI config
    path (~/.claude, ~/.config/kilo, ~/.copilot, or something under one of
    them) needs to come back out. Deliberately conservative in both
    directions required by #39: never touches a non-symlink (a user's own
    real file/directory there is left alone, same as link()'s backup-to-.bak
    behaviour would suggest, but here there is nothing to install in its
    place, so there is nothing to even back up), and never touches a
    symlink that resolves outside this checkout (some other tool's or the
    user's own symlink, unrelated to dotfiles).
    """
    dst = Path(dst)
    if not dst.is_symlink():
        return
    target = dst.readlink()
    target_abs = target if target.is_absolute() else (dst.parent / target)
    try:
        target_abs = target_abs.resolve(strict=False)
    except OSError:
        return  # can't resolve -- be conservative, don't touch it
    dotfiles_resolved = DOTFILES.resolve()
    inside_repo = target_abs == dotfiles_resolved or dotfiles_resolved in target_abs.parents
    if not inside_repo:
        return
    if DRY_RUN:
        print(f"  unlink (profile-gated off): {dst} → {target}")
        return
    dst.unlink()
    success(f"unlinked {dst} (profile-gated off)")

def apply_gated_links(action: bool | None, entries) -> None:
    """Apply the AI-gate tri-state to every (src, dst) pair.

    `action` is the tri-state resolve_ai_gate() returns as its second element,
    not a plain bool -- do not coerce it with `if action:` at a new call site,
    that silently collapses `None` (leave alone) into the unlink branch:

      * True  -> link every entry.
      * False -> unlink every entry (via unlink_gated() -- see its docstring
        for the safety rules on removal).
      * None  -> touch NOTHING. This is the invalid-profile state: there is no
        basis to decide add or remove, so every dst is left exactly as it is
        on disk, whether that's linked, unlinked, or something else entirely.
    """
    if action is None:
        return
    for src, dst in entries:
        if action:
            link(src, dst)
        else:
            unlink_gated(dst)

def render(content: str, dst: Path, marker: str):
    dst = Path(dst)
    if DRY_RUN:
        print(f"  render: → {dst}"); return
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.is_symlink():
        dst.unlink()
    elif dst.exists():
        try:
            existing = dst.read_text(errors="replace")
        except OSError:
            existing = ""
        if not existing.startswith(marker):
            warn(f"Backing up {dst} → {dst}.bak"); dst.replace(str(dst) + ".bak")
    dst.write_text(content, encoding="utf-8")
    success(f"rendered {dst}")

_EMPTY = subprocess.CompletedProcess([], 1, stdout="", stderr="")

def run(*cmd, timeout=30, **kw):
    try:
        return subprocess.run(list(cmd), capture_output=True, text=True, timeout=timeout, **kw)
    except subprocess.TimeoutExpired:
        warn(f"Command timed out ({timeout}s): {' '.join(str(c) for c in cmd)}")
        return _EMPTY

def _no_gui_env():
    e = os.environ.copy()
    e["GCM_INTERACTIVE"] = "never"   # Git Credential Manager: suppress all GUI dialogs
    e["GCM_NO_UI"] = "true"          # older GCM builds
    return e

def git_credential_fill(protocol, host, username=None):
    inp = f"protocol={protocol}\nhost={host}\n"
    if username:
        inp += f"username={username}\n"
    try:
        r = subprocess.run(
            ["git", "-c", "credential.interactive=never", "credential", "fill"],
            input=inp, capture_output=True, text=True, timeout=5, env=_no_gui_env(),
        )
        return dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line)
    except Exception:
        return {}

# ── context detection ─────────────────────────────────────────────────────────
def is_devcontainer():
    return any([
        os.environ.get("REMOTE_CONTAINERS"), os.environ.get("CODESPACES"),
        os.environ.get("DEVCONTAINER"), Path("/.dockerenv").exists(),
    ])

is_macos   = sys.platform == "darwin"
is_linux   = sys.platform.startswith("linux")
is_windows = sys.platform == "win32"

if DRY_RUN: warn("DRY RUN — no changes will be made")

log(f"Dotfiles dir: {DOTFILES}")
if is_devcontainer(): log("Context: devcontainer")
if is_macos:          log("Context: macOS")
if is_linux:          log("Context: Linux")
if is_windows:        log("Context: Windows")

IDENTITY_HOST = "dotfiles-identity.local"

# ── AI profile gating ─────────────────────────────────────────────────────────
# See profile/README.md for the full contract. Absent file -> agentic
# (preserves pre-profile behaviour). Invalid file -> hard stop for
# AI-related linking specifically, never a silent fall-open to agentic and
# never a silent fall-closed to bare -- the reader's own rule, just enforced
# here at the point where this linker would otherwise act on it.
def resolve_ai_gate():
    """Return (profile_name_or_None, ai_enabled: bool | None).

    profile_name is None iff the profile file is present but invalid, in
    which case ai_enabled is also None -- a genuine third state, not False --
    meaning nothing AI-related is linked or unlinked -- whatever is already on
    disk is left exactly as it is, since an error state gives no basis for
    deciding what should be there. Every gated call site (apply_gated_links()
    and the direct unlink_gated() call on copilot_settings_dst) must treat
    None as "leave alone", distinct from False's "actively unlink" -- collapsing
    the two by testing `if ai_enabled:` alone is exactly the bug this tri-state
    exists to prevent from coming back. The caller is responsible for making
    that failure loud and for making the process exit non-zero once the rest
    of the (unrelated) linking work is done -- see the bottom of this file.
    """
    try:
        active = _profile_mod.resolve_profile()
    except _profile_mod.ProfileError as exc:
        error(f"Invalid dotfiles profile: {exc}")
        error("Refusing to link OR unlink any AI configuration (~/.claude, "
              "~/.config/kilo, ~/.copilot) until this is fixed -- leaving "
              "whatever is currently there untouched. Every other symlink in "
              "this run still applies normally.")
        return None, None
    # Only `agentic` links the full AI config directories today. `inline` is
    # deliberately conservative (see #39's brief and PR description): this
    # repo's current ~/.claude / ~/.config/kilo / ~/.copilot layouts don't
    # cleanly separate "one-shot CLI" files from "agentic roster / skills /
    # MCP / orchestrator" files (CLAUDE.md, settings.json and hooks/ serve
    # both concerns at once), so rather than guess at a partial split that
    # could leak agentic-only capability into `inline`, nothing AI-related is
    # linked for `inline` yet. #40 (nested profile model + nvim gate) is
    # expected to define the exact inline asset list; this function is the
    # single place that decision plugs into.
    enabled = _profile_mod.profile_at_least(active, "agentic")
    return active, enabled

ACTIVE_PROFILE, AI_ENABLED = resolve_ai_gate()
if ACTIVE_PROFILE is not None:
    log(f"AI profile: {ACTIVE_PROFILE} ({'linking' if AI_ENABLED else 'not linking'} "
        "~/.claude, ~/.config/kilo, ~/.copilot)")

# ── git ───────────────────────────────────────────────────────────────────────
# NOTE on scope: everything in this section stays here rather than moving to
# legacy/provision_legacy.py, even though ensure-gcm.sh and the credential
# forwarding read below look exactly like the "gcm, credential-forwarding
# checks" examples #39's brief calls out to relocate. They don't move because
# they are a genuine prerequisite CHAIN for rendering ~/.gitconfig correctly
# on a fresh machine in a single pass:
#   ensure-gcm.sh (a credential.helper must be active)
#     -> git credential fill (devcontainer identity carry-forward READS it)
#     -> ~/.gitconfig.local gets its content
#     -> render() combines the template with that content into ~/.gitconfig
# legacy/provision_legacy.py is invoked once, near the end of this script
# (i.e. after linking). Moving any link in this chain there would mean it
# runs too late to affect *this* run's render() -- a fresh devcontainer's
# very first install would render ~/.gitconfig without the identity that
# credential forwarding would otherwise have supplied, and only pick it up
# on a *second* run. That is a real behaviour regression, not a refactor, so
# this chain is kept intact. What DOES move is everything that only WRITES
# to the credential store and that nothing downstream in this same run reads
# back (the identity/gh-token credential-store seeding) -- see
# legacy/provision_legacy.py's git-credential section.
log("Git...")
link(DOTFILES / "git" / ".gitignore_global", HOME / ".gitignore_global")

if is_linux and not is_windows:
    if DRY_RUN:
        print("  would check/install git-credential-manager (git/ensure-gcm.sh)")
    else:
        subprocess.run(["bash", str(DOTFILES / "git" / "ensure-gcm.sh")], check=True)

gitconfig_local = HOME / ".gitconfig.local"
if not gitconfig_local.exists():
    existing_gitconfig = HOME / ".gitconfig"
    existing_name  = run("git", "config", "--file", str(existing_gitconfig), "--get", "user.name").stdout.strip()
    existing_email = run("git", "config", "--file", str(existing_gitconfig), "--get", "user.email").stdout.strip()

    if is_devcontainer() and (not existing_name or existing_name == "Your Name"
                               or not existing_email or existing_email == "you@example.com"):
        creds = git_credential_fill("https", IDENTITY_HOST)
        fwd_name, fwd_email = creds.get("username", ""), creds.get("password", "")
        if fwd_name and fwd_email:
            existing_name, existing_email = fwd_name, fwd_email
            success(f"Pulled real git identity ({existing_name} <{existing_email}>) via credential forwarding")

    placeholder = lambda s: not s or s in ("Your Name", "you@example.com")
    if not placeholder(existing_name) and not placeholder(existing_email):
        if not DRY_RUN:
            gitconfig_local.write_text(
                "# ~/.gitconfig.local — machine-specific overrides, NOT committed to dotfiles\n"
                f"[user]\n\tname  = {existing_name}\n\temail = {existing_email}\n",
                encoding="utf-8",
            )
        success(f"Carried forward existing git identity ({existing_name} <{existing_email}>) into ~/.gitconfig.local")
    else:
        if not DRY_RUN:
            gitconfig_local.write_text(
                "# ~/.gitconfig.local — machine-specific overrides, NOT committed to dotfiles\n"
                "# No identity could be auto-detected. Fill in your name and email, e.g.:\n"
                "#[user]\n#\tname  = Your Name\n#\temail = you@example.com\n",
                encoding="utf-8",
            )
        warn("Created ~/.gitconfig.local with no git identity set — run: "
             "git config user.name \"Your Name\" && git config user.email you@example.com "
             "(then re-run install, or edit ~/.gitconfig.local directly).")

MARKER = "# Managed by dotfiles install.py — do not edit directly.\n"
gitconfig_marker  = MARKER + "# Edit git/.gitconfig.template or ~/.gitconfig.local, then re-run install.py.\n\n"
gitconfig_local_content = gitconfig_local.read_text(encoding="utf-8") if gitconfig_local.exists() else ""
gitconfig_template      = (DOTFILES / "git" / ".gitconfig.template").read_text(encoding="utf-8")
gitconfig_rendered = gitconfig_marker + gitconfig_template
if is_windows:
    # tools/smart-editor.sh is a POSIX shell script with no native-Windows
    # counterpart (and per README.md, a .cmd shim can't safely wrap it -
    # cmd.exe re-scans a batch file's %* with no working escape, which is
    # exactly the injection class that got windows/claude.cmd removed).
    # powershell/profile.ps1 already keeps native Windows on a hardcoded
    # `code --wait` for $env:EDITOR for the same reason; match that here so
    # core.editor doesn't diverge onto a script this platform can't run.
    # Inserted between the template and ~/.gitconfig.local (not after) so a
    # user's own override there still wins, same as everywhere else.
    gitconfig_rendered += "\n[core]\n\teditor = code --wait\n"
gitconfig_rendered += "\n" + gitconfig_local_content
render(gitconfig_rendered, HOME / ".gitconfig", gitconfig_marker)

effective_name  = run("git", "config", "--file", str(HOME / ".gitconfig"), "--get", "user.name").stdout.strip()
effective_email = run("git", "config", "--file", str(HOME / ".gitconfig"), "--get", "user.email").stdout.strip()

if not effective_name or not effective_email:
    warn("No git identity set — run: git config user.name \"Your Name\" && git config user.email you@example.com "
         "(or edit ~/.gitconfig.local and re-run install).")

# ── git hooks ─────────────────────────────────────────────────────────────────
# core.hooksPath is written as the ABSOLUTE path of this checkout's hooks/
# dir, never the bare relative "hooks". A relative value resolves against the
# git process's current working directory, so a git operation on a linked
# worktree (which shares this .git/config) can make the hook fire out of
# whichever tree git happened to run from — the defect behind issue #54. An
# absolute path pins the hook to the checkout that installed it.
# hooks/_dispatch.sh still validates the working tree against the receipt
# regardless of this; the absolute path is defence in depth.
hooks_path = str(DOTFILES / "hooks")
log("Git hooks...")
if DRY_RUN:
    print(f"  git config core.hooksPath {hooks_path}")
else:
    subprocess.run(["git", "-C", str(DOTFILES), "config", "core.hooksPath", hooks_path], check=True)
    for h in (DOTFILES / "hooks").glob("*"):
        h.chmod(h.stat().st_mode | 0o111)
    success(f"core.hooksPath -> {hooks_path}")

existing_global_hooks = run("git", "config", "--global", "--get", "core.hooksPath").stdout.strip()
if existing_global_hooks == str(DOTFILES / "git" / "global-hooks"):
    if DRY_RUN:
        print("  git config --global --unset core.hooksPath")
    else:
        run("git", "config", "--global", "--unset", "core.hooksPath")
        success("Removed global core.hooksPath (identity guard retired in favor of shell/doctor.sh)")

# ── install receipt ──────────────────────────────────────────────────────────
# Records which checkout this $HOME was deliberately installed from, so
# hooks/_dispatch.sh can tell a real install from an incidental one.
#
# PRESERVED HERE DELIBERATELY -- this is a deviation from #39's literal text
# ("delete the receipt code"). See "Receipt retained (deviation from #39)" in
# this PR's description for the full reasoning; in short, hooks/_dispatch.sh
# (issue #54, PRs #59/#60) refuses hook-triggered installs unless this
# receipt names the current working tree, and that guard has no replacement
# yet. Deleting the writer would silently disarm hook auto-sync for every
# machine that has one, which is a real behaviour change dressed up as a
# refactor. Issue #30 (Windows receipt-path normalization) stays open and is
# unaffected by this move.
#
# A `git worktree add` shares the primary checkout's .git/config -- including
# the core.hooksPath just set above -- and since `hooks` is a relative path
# it resolves inside whichever checkout the hook actually fires from; without
# this, a branch switch inside a brand-new, possibly-unreviewed worktree
# would silently install that worktree's content into the real $HOME. Same
# for `git clone -c core.hooksPath=hooks`, which persists the setting into a
# fresh clone and fires on its first checkout. The receipt has to live
# outside the repo (a clone would copy an in-repo marker along with it) and
# outside .git/config (worktrees share that file), so ~/.local/state is the
# only location that's both durable and tied to this $HOME rather than to any
# one checkout. See hooks/_dispatch.sh for the guard that reads this back.
log("Install receipt...")

def _first_symlinked_ancestor(path: Path, home: Path) -> Path | None:
    """Return the first symlink at `path` or any ancestor up to `home`.

    None if the ancestry is clean. This is issue #29's ancestry-walk check,
    kept as a single named helper (rather than inlined) so there is exactly
    one implementation of it in this file even though there is only one
    call site today -- a second state-marker write in this script should
    reuse this rather than re-deriving the walk.
    """
    current = path
    while True:
        if current.is_symlink():
            return current
        if current == home or current.parent == current:
            return None
        current = current.parent

if DRY_RUN:
    print(f"  would record install root: {DOTFILES}")
else:
    receipt = HOME / ".local" / "state" / "dotfiles" / "install-root"
    # Refuse to write through a symlink. write_text() opens with plain
    # open(..., "w"), which follows symlinks and truncates whatever they
    # point at -- a symlink planted at the receipt path, at its immediate
    # parent dir, or at ANY ancestor dir up to $HOME before this runs would
    # turn a routine install into an attacker-chosen arbitrary-file
    # overwrite. A symlinked ancestor is just as dangerous as a symlinked
    # parent: receipt.parent.mkdir(parents=True) would happily create the
    # rest of the tree *inside* the redirected location and the write would
    # then land there undetected, so the check has to walk every component
    # from receipt.parent up to (and including) HOME, and must run before
    # the mkdir.
    #
    # A symlink anywhere on that path is a warn-and-skip, NOT an abort. The
    # receipt only arms the git-hook auto-sync convenience (see
    # hooks/_dispatch.sh); it is not load-bearing for the rest of this
    # install -- shell, editors, CLIs, SSH, VS Code and global config all
    # come afterward and must still run. Skipping the write leaves the guard
    # disarmed, which is the safe direction, but the user has to be told.
    symlinked_component = _first_symlinked_ancestor(receipt.parent, HOME)
    if symlinked_component is not None:
        warn(f"{symlinked_component} is a symlink — NOT writing the install receipt "
             f"through it (an ancestor symlink would redirect the write outside "
             f"~/.local/state). The git-hook auto-sync guard stays DISARMED: "
             f"hooks/_dispatch.sh will skip every hook-triggered install of this "
             f"checkout until you remove the symlinked component and re-run "
             f"'bash install.sh' by hand. The rest of this install continues.")
    else:
        receipt.parent.mkdir(parents=True, exist_ok=True)
        if receipt.is_symlink():
            receipt.unlink()
        receipt.write_text(f"{DOTFILES}\n", encoding="utf-8")
        success(f"Recorded install root ({DOTFILES}) -> {receipt}")

# ── shell ─────────────────────────────────────────────────────────────────────
# Only these files are sourced into a running shell's environment at startup, so
# only a change here means an already-open shell is stale. Everything else this
# script links (Claude/Kilo config, git config, VS Code settings, ...) is read
# fresh by its own tool on every invocation and never needs a shell restart.
log("Shell...")
shell_changed = any([
    link(DOTFILES / "shell" / "aliases.sh",     HOME / ".aliases"),
    link(DOTFILES / "shell" / "exports.sh",     HOME / ".exports"),
    link(DOTFILES / "shell" / "doctor.sh",      HOME / ".doctor"),
    link(DOTFILES / "shell" / "self-heal.sh",   HOME / ".self-heal"),
    link(DOTFILES / "shell" / ".bashrc",        HOME / ".bashrc"),
    link(DOTFILES / "shell" / ".bash_profile",  HOME / ".bash_profile"),
    link(DOTFILES / "shell" / ".zshrc",         HOME / ".zshrc"),
    link(DOTFILES / "shell" / ".zprofile",      HOME / ".zprofile"),
])

# ── editor ────────────────────────────────────────────────────────────────────
# Read fresh from PATH on every invocation, like starship.toml below — doesn't
# need shell_changed / a shell restart. See tools/smart-editor.sh for why this
# exists instead of hardcoding `code --wait`.
log("Editor...")
link(DOTFILES / "tools" / "smart-editor.sh", HOME / ".local" / "bin" / "smart-editor")

# ── starship ──────────────────────────────────────────────────────────────────
# Binary install moved to legacy/provision_legacy.py (Phase 3 packages, #41);
# only the config symlink is pure Layer 2 linking.
log("Starship...")
link(DOTFILES / "starship" / "starship.toml", HOME / ".config" / "starship.toml")

# ── tmux ──────────────────────────────────────────────────────────────────────
link(DOTFILES / "tmux" / ".tmux.conf", HOME / ".tmux.conf")

# ── neovim ────────────────────────────────────────────────────────────────────
# Binary install moved to legacy/provision_legacy.py (Phase 3 packages, #41);
# only the config symlink is pure Layer 2 linking.
log("Neovim...")
link(DOTFILES / "nvim", HOME / ".config" / "nvim")

# ── lazygit ───────────────────────────────────────────────────────────────────
# Binary install moved to legacy/provision_legacy.py (Phase 3 packages, #41);
# only the config symlink is pure Layer 2 linking.
log("lazygit...")
link(DOTFILES / "lazygit" / "config.yml", HOME / ".config" / "lazygit" / "config.yml")

# ── yazi ──────────────────────────────────────────────────────────────────────
# Binary install moved to legacy/provision_legacy.py (Phase 3 packages, #41);
# only the config symlink is pure Layer 2 linking.
log("yazi...")
link(DOTFILES / "yazi", HOME / ".config" / "yazi")

# Kilo Code CLI, GitHub Copilot CLI, devcontainer CLI and rtk installs (all
# npm-global or standalone-binary installs, no linking of their own) moved to
# legacy/provision_legacy.py -- Phase 3 packages, #41.

log("start-project (sp)...")
link(DOTFILES / "tools" / "start-project.sh", HOME / ".local" / "bin" / "start-project")

# ── SSH ───────────────────────────────────────────────────────────────────────
log("SSH...")
ssh_dir = HOME / ".ssh"
if not DRY_RUN:
    ssh_dir.mkdir(mode=0o700, parents=True, exist_ok=True)

ssh_config_local = ssh_dir / "config.local"
if not ssh_config_local.exists():
    if not DRY_RUN:
        shutil.copy(str(DOTFILES / "ssh" / "config.local.example"), str(ssh_config_local))
    warn("Created ~/.ssh/config.local — add machine-specific hosts there")

ssh_marker   = MARKER + "# Edit ssh/config.template or ~/.ssh/config.local, then re-run install.py.\n\n"
ssh_template = (DOTFILES / "ssh" / "config.template").read_text(encoding="utf-8")
ssh_rendered = ssh_marker + "Include ~/.ssh/config.local\n\n" + ssh_template
render(ssh_rendered, ssh_dir / "config", ssh_marker)
if not DRY_RUN and not is_windows:
    (ssh_dir / "config").chmod(0o600)

# ── VS Code ───────────────────────────────────────────────────────────────────
if not is_devcontainer():
    log("VS Code...")
    if is_macos:
        vscode_dir = HOME / "Library" / "Application Support" / "Code" / "User"
    elif is_windows:
        vscode_dir = Path(os.environ.get("APPDATA", HOME / "AppData" / "Roaming")) / "Code" / "User"
    else:
        vscode_dir = HOME / ".config" / "Code" / "User"
    link(DOTFILES / "vscode" / "settings.json",    vscode_dir / "settings.json")
    link(DOTFILES / "vscode" / "keybindings.json", vscode_dir / "keybindings.json")

    # Scoop-installed VS Code runs in portable mode and reads its user data from
    # <scoop app>/data/user-data/User, not %APPDATA%\Code\User above — so the
    # links just above silently do nothing for a Scoop install. `apps/vscode/
    # current` is a version junction Scoop repoints on every update, but
    # `persist/vscode` survives updates/reinstalls, so link there instead. Root
    # resolution matches Scoop's own: $env:SCOOP if set, else ~/scoop (Scoop's
    # documented default of $env:USERPROFILE\scoop). Gated on an actual Scoop
    # VS Code install so this is a no-op on any machine without one.
    if is_windows:
        scoop_root = Path(os.environ.get("SCOOP", str(HOME / "scoop")))
        if (scoop_root / "apps" / "vscode").is_dir():
            scoop_vscode_dir = scoop_root / "persist" / "vscode" / "data" / "user-data" / "User"
            link(DOTFILES / "vscode" / "settings.json",    scoop_vscode_dir / "settings.json")
            link(DOTFILES / "vscode" / "keybindings.json", scoop_vscode_dir / "keybindings.json")

# ── Claude Code ───────────────────────────────────────────────────────────────
log("Claude Code global config...")
claude_dir = HOME / ".claude"
apply_gated_links(AI_ENABLED, [
    (DOTFILES / "claude" / "CLAUDE.md",             claude_dir / "CLAUDE.md"),
    (DOTFILES / "claude" / "settings.json",          claude_dir / "settings.json"),
    (DOTFILES / "claude" / "statusline-command.sh",  claude_dir / "statusline-command.sh"),
    (DOTFILES / "claude" / "agents",                 claude_dir / "agents"),
    (DOTFILES / "claude" / "hooks",                  claude_dir / "hooks"),
    (DOTFILES / "claude" / "skills",                 claude_dir / "skills"),
    # rtk's command-rewrite hook (hooks/rtk-rewrite.sh) works with zero context
    # cost, so rtk-awareness.md is deliberately NOT pulled into CLAUDE.md. It's
    # linked here only so `@rtk-awareness.md` resolves on demand for the rtk meta
    # commands (`rtk gain`, `rtk discover`).
    (DOTFILES / "claude" / "rtk-awareness.md",       claude_dir / "rtk-awareness.md"),
])

# ── Kilo Code ───────────────────────────────────────────────────────────────────
# Same schema, same structure as the ~/.config/kilo/ directory Kilo itself
# creates — config files are symlinked from the repo just like the claude/
# entries above. The global instructions file is shared from claude/CLAUDE.md
# (one source of truth — the content is tool-agnostic, so both Claude Code
# reading CLAUDE.md and Kilo reading AGENTS.md see the same rules).
log("Kilo Code global config...")
kilo_config_dir = HOME / ".config" / "kilo"
apply_gated_links(AI_ENABLED, [
    (DOTFILES / "claude" / "CLAUDE.md",              kilo_config_dir / "AGENTS.md"),
    (DOTFILES / "kilo" / "kilo.jsonc",               kilo_config_dir / "kilo.jsonc"),
    (DOTFILES / "kilo" / "tui.jsonc",                kilo_config_dir / "tui.jsonc"),
    # Agents must land directly under ~/.config/kilo/agents, NOT nested inside a
    # linked ~/.config/kilo/.kilo/ directory: Kilo (an opencode fork) discovers
    # agents by globbing `{agent,agents}/**/*.md` *inside* each config directory
    # it already knows about, and ~/.config/kilo/ is that directory -- a file at
    # `.kilo/agents/number-one.md` relative to it has ".kilo" as its first path
    # segment, which the glob never matches. Confirmed empirically: linking the
    # whole .kilo/ directory (the old wiring) left `kilo agent list` never
    # mentioning number-one at all, no error, no warning.
    (DOTFILES / "kilo" / ".kilo" / "agents",         kilo_config_dir / "agents"),
    # Plugin directory must be a real symlink, not just a config-file reference:
    # kilo.jsonc's `plugin` array resolves relative paths against the *literal*
    # path of the config file (this symlink target's parent), not its realpath,
    # so without this the require-devcontainer plugin would silently fail to load
    # -- confirmed empirically, no error, no log line, the hook just never fires.
    (DOTFILES / "kilo" / "plugin",                   kilo_config_dir / "plugin"),
])
# `commands/` holds only a `.gitkeep` today (no real command files), so it is
# deliberately NOT linked here yet -- Kilo's command glob also wants a
# top-level `commands/` (confirmed: `{command,commands}/**/*.md`), so wire it
# the same way as agents/ above once it actually holds content worth serving.
#
# The pre-fix wiring above also symlinked kilo/.kilo/ wholesale, which is why
# ~/.config/kilo/.kilo may still exist as a leftover from before this fix;
# clean up only that exact stale symlink, never anything else that might be
# sitting at that path. Runs regardless of AI_ENABLED -- it only ever REMOVES
# one specific known-stale link, the same safety rule apply_gated_links'
# unlink_gated() enforces elsewhere in this file.
_stale_dot_kilo_link = kilo_config_dir / ".kilo"
if _stale_dot_kilo_link.is_symlink() and _stale_dot_kilo_link.readlink() == DOTFILES / "kilo" / ".kilo":
    if DRY_RUN:
        print(f"  remove stale link: {_stale_dot_kilo_link} -> {DOTFILES / 'kilo' / '.kilo'}")
    else:
        _stale_dot_kilo_link.unlink()
        success(f"removed stale link {_stale_dot_kilo_link}")

# ── GitHub Copilot CLI ───────────────────────────────────────────────────────────
# Same one-source-of-truth pattern as Kilo above — Copilot CLI reads global
# instructions from ~/.copilot/copilot-instructions.md, symlinked straight from
# claude/CLAUDE.md rather than duplicated. Skills are shared the same way, from
# claude/skills; everything genuinely Copilot-specific (the devcontainer hook
# shim, its wiring, and the agent roster in Copilot's own schema) lives in
# copilot/.
log("GitHub Copilot CLI global config...")
copilot_dir = HOME / ".copilot"

def strip_jsonc_line_comments(text: str) -> str:
    """Drop whole-line `//` comments so json can parse copilot/settings.json.

    copilot/settings.json is JSONC: the Copilot CLI accepts `//` comments, and a
    `"//"` string key (the other obvious way to annotate JSON) is REJECTED by it,
    so those comments have to stay comments. Every comment in that file is a whole
    line by convention, which is what makes this one-liner sufficient -- a trailing
    `//` after a value would defeat it, which is exactly why the convention exists
    and why check_copilot_settings_parse() below says so when it fails.
    """
    return "\n".join(
        ln for ln in text.splitlines() if not ln.lstrip().startswith("//")
    )


def check_copilot_settings_parse(src: Path) -> bool:
    """Parse copilot/settings.json on EVERY run and shout if it does not parse.

    AN UNPARSEABLE settings.json DISABLES THE DEVCONTAINER GUARD SILENTLY. That is
    observed, not inferred: with one syntax error injected into
    ~/.copilot/settings.json the CLI emitted no warning and no error, the
    preToolUse hook never ran, and a write landed in a guarded repo. An unknown
    top-level KEY does warn ("Ignoring unknown top-level key(s)") and trailing
    commas are tolerated -- it is specifically the parse failure that says nothing.
    The file is hand-maintained JSONC with ~80 comment lines, so a broken edit is
    an ordinary accident rather than an exotic one, and its only symptom is a
    session that is quietly unguarded.

    So this runs unconditionally, and not only inside the detached-file branch
    below where a parse error was previously swallowed by an `except ValueError`.
    It is read-only and therefore --dry-run safe, and it catches every exception it
    can rather than propagating one: install.py aborting on an unrelated
    filesystem error would be a worse outcome than the report it is trying to make.
    It returns False rather than raising, and the caller then declines to install
    the symlink -- leaving whatever is already live in place instead of replacing
    it with something known-broken.
    """
    try:
        raw = src.read_text(encoding="utf-8")
    except OSError as exc:
        error(f"Could not read {src}: {exc}")
        error("  The Copilot devcontainer guard's wiring could not be checked or installed.")
        return False

    def _reject_json_constant(name: str) -> float:
        """Reject NaN/Infinity/-Infinity, which Python accepts and the CLI does not.

        Those three bare tokens are a Python `json` EXTENSION; they are not in the
        JSON grammar and the Copilot CLI's parser refuses them. Accepting one here
        is a fail-OPEN in the one direction that matters: this check would pass,
        install.py would link the file, and the CLI would then fail to parse it --
        silently, exactly as the docstring above describes -- leaving the
        devcontainer guard OFF for every session with nothing to say why. Raising
        ValueError routes it into the same branch as any other syntax error.
        """
        raise ValueError(
            f"{name} is a Python json extension, not JSON --"
            " the Copilot CLI rejects it and would then run no hooks at all"
        )

    try:
        parsed = json.loads(
            strip_jsonc_line_comments(raw), parse_constant=_reject_json_constant
        )
    except ValueError as exc:
        error(f"{src} IS NOT VALID JSON(C): {exc}")
        error("  This is not cosmetic. The Copilot CLI does not report a settings file it")
        error("  cannot parse -- no warning, no error -- it simply runs no hooks, so the")
        error("  devcontainer guard would be silently OFF for every session.")
        error("  Refusing to install it. Fix the syntax and re-run this script.")
        error("  (This check is deliberately STRICTER than the CLI in two known ways, so")
        error("   not everything it rejects is something the CLI would have choked on:")
        error("   comments must be WHOLE-LINE `//` only, and a `//` after a value on the")
        error("   same line fails here; and a TRAILING COMMA fails here even though the")
        error("   CLI tolerates one. It is deliberately never more LENIENT than the CLI --")
        error("   NaN and Infinity are refused here precisely because the CLI refuses")
        error("   them, and letting them through would install a file the CLI cannot read.)")
        return False
    except Exception as exc:                     # never abort the whole install
        error(f"Unexpected failure while checking {src}: {exc!r}")
        error("  Refusing to install it. Inspect it by hand and re-run this script.")
        return False

    if not isinstance(parsed, dict):
        error(f"{src} parsed as {type(parsed).__name__}, not a JSON object.")
        error("  Refusing to install it -- the CLI expects a top-level object.")
        return False

    # Not a parse failure, so not fatal, but the same silent-fail-open family: a
    # settings file that parses cleanly yet has lost its hook block leaves the
    # session unguarded just as thoroughly, and just as quietly.
    hooks = parsed.get("hooks")
    pre = hooks.get("preToolUse") if isinstance(hooks, dict) else None
    if not (isinstance(pre, list) and pre):
        warn(f"{src} parses, but carries no hooks.preToolUse entry — the devcontainer"
             " guard will NOT fire under Copilot. Installing it anyway; restore the hook"
             " block if that was not deliberate.")
    return True


def report_detached_copilot_settings(src: Path, dst: Path) -> None:
    """Warn when ~/.copilot/settings.json has stopped being our symlink.

    THE SYMLINK IS NOT DURABLE. Copilot writes settings atomically -- temp file
    plus rename -- so saving settings REPLACES the symlink with a regular file
    rather than writing through it. Observed twice against an isolated
    COPILOT_HOME, triggered by entirely ordinary actions: `copilot skill add`,
    `copilot plugin install`, `/memory on|off`, `/settings ...`.

    Nothing leaks into the repo when that happens -- the CLI writes its own file,
    not ours. The damage is quieter: from that moment copilot/settings.json is no
    longer the source of truth for the live config, so any edit to the guard's
    matcher, timeout or hook path sits there doing nothing until install.py runs
    again, with no error and no log line. That is the same silent-fail-open shape
    the guard exists to prevent, so it gets a loud warning rather than a quiet
    re-link. The rewrite also strips every `//` comment and normalizes the hook
    schema; the hook block itself survived and kept firing in both observations.

    Read-only and DRY_RUN-safe: this only looks and reports. The re-link is
    link()'s job on the very next line, and link() moves the detached file to
    .bak first, so nothing the CLI wrote is destroyed without a copy. It is still
    named here key by key, because a .bak nobody is told about is not a backup.
    """
    if dst.is_symlink():
        if dst.readlink() == src:
            return                               # healthy
        warn(f"{dst} is a symlink to {dst.readlink()}, not to {src} — re-linking.")
        return
    if not dst.exists():
        return                                   # first install; link() creates it

    warn(f"{dst} is a REGULAR FILE, not a symlink to {src}.")
    warn("  The Copilot CLI rewrote it (a skill/plugin install, /memory or /settings all"
         " do this), which detaches it from this repo. Until now, edits to"
         " copilot/settings.json — including the devcontainer guard's wiring — have had"
         " NO effect on the live config.")

    # Name whatever the CLI added, so re-linking cannot silently drop a setting.
    try:
        live = json.loads(dst.read_text(encoding="utf-8"))
        # The repo file is JSONC; strip_jsonc_line_comments() makes it parseable.
        # A failure here is only a lost COMPARISON -- the file's own parseability
        # is checked unconditionally by check_copilot_settings_parse() before this
        # runs, so a syntax error is already loud by the time we get here and this
        # `except` is no longer where it goes to die.
        repo = json.loads(strip_jsonc_line_comments(src.read_text(encoding="utf-8")))
    except (OSError, ValueError):
        warn("  Could not compare the two files; inspect them by hand before continuing.")
        return

    if isinstance(live, dict) and isinstance(repo, dict):
        extra = sorted(set(live) - set(repo))
        if extra:
            warn(f"  Keys present only in the live file: {', '.join(extra)}. Re-linking"
                 f" moves it to {dst.name}.bak — copy anything worth keeping into"
                 " copilot/settings.json, then re-run this script.")
        else:
            warn("  It carries no top-level keys this repo's copy lacks, so re-linking"
                 f" loses nothing but CLI-side formatting (a copy lands in {dst.name}.bak).")

copilot_settings_src = DOTFILES / "copilot" / "settings.json"
copilot_settings_dst = copilot_dir / "settings.json"
if AI_ENABLED is None:
    # Invalid profile: the tri-state's "leave alone" state -- same rule as
    # apply_gated_links(None, ...) below. No basis to decide add or remove, so
    # this destination is not touched at all, not even the unlink branch.
    copilot_settings_ok = True  # not a parse failure -- nothing evaluated by design
elif AI_ENABLED:
    # UNCONDITIONAL, EVERY RUN, BEFORE THE LINK. A settings.json the CLI cannot parse
    # turns the devcontainer guard off with no warning of any kind (see the function's
    # docstring), so the only place that can be caught is here. Gate the symlink on it:
    # installing a file we know is broken would be actively worse than leaving the
    # previous one in place.
    copilot_settings_ok = check_copilot_settings_parse(copilot_settings_src)
    report_detached_copilot_settings(copilot_settings_src, copilot_settings_dst)
    # This link is also the REPAIR for the detached case reported just above, not only
    # a first-install step: it is the only thing that reattaches the live config to
    # this repo after the CLI has rewritten it. Re-run install.py whenever
    # `ls -l ~/.copilot/settings.json` shows a regular file instead of a symlink.
    if copilot_settings_ok:
        link(copilot_settings_src, copilot_settings_dst)
    else:
        error(f"SKIPPED linking {copilot_settings_dst} — see the errors above.")
else:
    copilot_settings_ok = True  # not applicable at this profile -- nothing installed by design
    unlink_gated(copilot_settings_dst)

apply_gated_links(AI_ENABLED, [
    (DOTFILES / "claude" / "CLAUDE.md",      copilot_dir / "copilot-instructions.md"),
    # The hooks directory symlink is load-bearing, not cosmetic -- same class of trap
    # as Kilo's plugin dir above. copilot/settings.json invokes the guard as
    # `bash "$HOME/.copilot/hooks/require-devcontainer.sh"` (Copilot does expand
    # $HOME inside a hook command -- verified empirically, it is undocumented), so
    # without this link the script simply is not there and the guard never fires:
    # no error, no log line, just an unguarded session.
    (DOTFILES / "copilot" / "hooks",         copilot_dir / "hooks"),
    # Personal custom agents -- Copilot discovers them as ~/.copilot/agents/*.agent.md.
    (DOTFILES / "copilot" / "agents",        copilot_dir / "agents"),
    # Skills point at claude/skills deliberately: the SAME source of truth Claude
    # Code uses, not a copy. Copilot reads SKILL.md in the identical format, and a
    # whole-directory symlink here was confirmed to list every skill under "Personal
    # skills" in a live session and to actually load them. Same reasoning as
    # copilot-instructions.md above and Kilo's AGENTS.md -- one file, both tools.
    (DOTFILES / "claude" / "skills",         copilot_dir / "skills"),
])

# ── legacy machine-state provisioning ─────────────────────────────────────────
# Everything that is package/CLI installs, credential-store seeding,
# credential-forwarding checks, or macOS defaults -- i.e. not linking -- lives
# in legacy/provision_legacy.py now, invoked here as a single step AFTER all
# of the above linking. See that module's docstring for the full inventory
# and which Phase 3 (#41-#45) issue is expected to retire each chunk. This
# call preserves a real dependency the pre-split script had: if this step
# fails hard (matching subprocess check=True calls the original script also
# had), install.py stops here too, before printing "Done!" -- same as the
# original single-process script would have via an uncaught exception.
log("Legacy machine-state provisioning (see legacy/provision_legacy.py)...")
_legacy_cmd = [sys.executable, str(DOTFILES / "legacy" / "provision_legacy.py")]
if DRY_RUN:
    _legacy_cmd.append("--dry-run")
_legacy_rc = subprocess.run(_legacy_cmd).returncode
if _legacy_rc != 0:
    error(f"legacy/provision_legacy.py exited {_legacy_rc} — stopping before completion, "
          "same as the pre-split installer would have on this failure.")
    sys.exit(_legacy_rc)

if shell_changed:
    success("Done! Shell config changed -- open a new shell or: source ~/.zshrc (or ~/.bashrc)")
else:
    success("Done! No shell-init files changed -- no new shell needed.")

# Restated last, on purpose. A broken copilot/settings.json silently disables the
# devcontainer guard, and an error a few hundred lines up the scrollback is an
# error nobody reads. Non-zero exit so a caller (or CI) notices too. Same
# treatment for an invalid profile file -- see resolve_ai_gate() above.
_exit_code = 0
if not copilot_settings_ok:
    error("copilot/settings.json did NOT parse and was not installed — the Copilot"
          " devcontainer guard is not wired up. Fix it and re-run this script.")
    _exit_code = 1
if ACTIVE_PROFILE is None:
    error(f"{_profile_mod.profile_path()} holds an invalid profile — AI configuration"
          " was left untouched (neither linked nor unlinked). Fix it and re-run this script.")
    _exit_code = 1
sys.exit(_exit_code)
