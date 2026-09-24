#!/usr/bin/env python3
"""
legacy/provision_legacy.py -- interim home for the parts of the old
install.py that are machine-state provisioning, not dotfiles linking:
package/binary/CLI installs, credential-store seeding, credential-forwarding
checks, and macOS defaults.

Why this file exists (issue #39, part of epic #35)
----------------------------------------------------
#39 slims install.py down to Layer 2 -- a pure symlink farm plus
profile-gated linking of the AI config directories. Everything in this file
used to live in install.py, interleaved with the linking code. It has NOT
been deleted: #44 (and the rest of the Phase 3 issues, #41-#45) impose a
hard retirement gate -- an install.py/install.ps1 chunk is only removed once
its Ansible role reaches VERIFIED PARITY against a running system, not
merely against its own test suite. Those roles do not exist yet, so this
code has to keep running, verbatim, from somewhere. This module is that
somewhere.

Each section below is tagged with the Phase 3 issue expected to retire it:

    #41  provision/roles/packages   -- binary/CLI installs (starship, neovim,
                                        lazygit, yazi, Kilo/Copilot/
                                        devcontainer CLIs, rtk, and the
                                        devcontainer-extras package installs)
    #42  provision/roles/macos      -- macOS defaults
    #44  provision/roles/secrets    -- credential-store seeding and
                                        credential-forwarding checks

Do not add new provisioning here. This module is a holding pen, not a new
home -- new Layer 1 (machine state) work belongs in provision/, per
provision/README.md.

Invocation
----------
Invoked once by install.py, as a subprocess, AFTER all of install.py's
linking is done (see install.py's "legacy machine-state provisioning"
section for why: this preserves the original script's ordering guarantee
that a hard failure late in the old monolithic install.py -- e.g. `ensure-
delta.sh` or `macos/defaults.sh` exiting non-zero -- stops the process
before its final "Done!" message, same as an uncaught CalledProcessError
would have in the original single-process script). It is a leaf script
(never imports install.py, never gets imported by it) so it can be run,
tested, or even deleted piecewise without touching install.py.

`--dry-run` carries the exact same guarantee it did in the original
install.py: every side-effecting call in this file is gated on `not
DRY_RUN` (the sole pre-existing exception is `macos/defaults.sh`, which was
NOT gated in the original install.py either -- see the macOS section below;
that gap is inherited verbatim, not introduced here, per the #39 brief's
"move, don't improve" instruction for this migration).
"""

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

DOTFILES = Path(__file__).parent.parent.resolve()
HOME = Path.home()

# Pinned deliberately (supply-chain hygiene — do not switch to an unpinned or
# caret/range install). Bump by checking `npm view @kilocode/cli version` and
# updating this constant (used at both @kilocode/cli install call sites below,
# and mentioned in README.md).
KILO_CLI_VERSION = "7.4.22"

# Same rationale as KILO_CLI_VERSION above. Bump by checking
# `npm view @github/copilot version` and updating this constant (used at both
# @github/copilot install call sites below, and mentioned in README.md).
COPILOT_CLI_VERSION = "1.0.80"

# Same rationale as KILO_CLI_VERSION above. Bump by checking
# `npm view @devcontainers/cli version` and updating this constant.
DEVCONTAINERS_CLI_VERSION = "0.89.0"

# rtk (Rust Token Killer) — installed from the project's own release script.
# Trust model, strongest link first:
#   * RTK_INSTALLER_SHA pins install.sh to an immutable commit (a git *tag*
#     like v0.47.0 is mutable and re-resolved on every fetch — a moved tag
#     would feed arbitrary script straight into `sh`). Reviewed install.sh
#     sha256: d6eb73a772903e13ff34ee1be8a8b24e896ba9a978f20d2279a08b4083ea6f77
#   * That pinned script downloads the rtk binary tarball for RTK_VERSION and
#     verifies it against the release's checksums.txt before extracting
#     (expected x86_64-unknown-linux-musl tarball sha256:
#     7c0175d867f96c4f8f788479af82ca8f0990ea944226268834d224a525186fb7).
#   * Residual risk: a compromised release could ship a matching tarball +
#     checksums. Accepted here — this is already stricter than the repo's
#     other `curl | sh` installs (starship, Claude Code), which pin nothing.
# Bump both together: pick the `vX.Y.Z` stable tag from
# https://github.com/rtk-ai/rtk/releases/latest (not a `dev-*-rc` pre-release),
# set RTK_INSTALLER_SHA to the commit it points at, and refresh the hashes above.
RTK_VERSION = "v0.47.0"
RTK_INSTALLER_SHA = "34fe2553192aef5f6ca19944cb52a272a5294c27"

# ── args ──────────────────────────────────────────────────────────────────────
parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("--dry-run", action="store_true")
ARGS = parser.parse_args()
DRY_RUN = ARGS.dry_run

# ── helpers (duplicated from install.py on purpose) ──────────────────────────
# This module is deliberately a leaf/standalone script (see module docstring)
# so it never imports install.py -- importing it would re-run install.py's
# entire top-level linking sequence, since that file has no `if __name__ ==
# "__main__"` guard around its linking code. The handful of small helpers
# duplicated below are the price of that independence; they are intentionally
# kept minimal since this whole module is transitional (see the retirement
# gate in the module docstring).
BLUE = "\033[0;34m"; GREEN = "\033[0;32m"; YELLOW = "\033[0;33m"; RED = "\033[0;31m"; RESET = "\033[0m"

def log(m):     print(f"{BLUE}▶{RESET} {m}")
def success(m): print(f"{GREEN}✔{RESET} {m}")
def warn(m):    print(f"{YELLOW}⚠{RESET} {m}")
def error(m):   print(f"{RED}✖{RESET} {m}", file=sys.stderr)

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

def git_credential_approve(protocol, host, username, password):
    inp = f"protocol={protocol}\nhost={host}\nusername={username}\npassword={password}\n"
    try:
        subprocess.run(
            ["git", "-c", "credential.interactive=never", "credential", "approve"],
            input=inp, capture_output=True, text=True, timeout=10, env=_no_gui_env(),
        )
    except Exception:
        pass

def write_through_symlink(path: Path, content: str):
    """Write content to path's real target so symlinks aren't replaced by plain files."""
    real = path.resolve() if path.is_symlink() else path
    tmp = real.parent / (real.name + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    tmp.replace(real)

def is_devcontainer():
    return any([
        os.environ.get("REMOTE_CONTAINERS"), os.environ.get("CODESPACES"),
        os.environ.get("DEVCONTAINER"), Path("/.dockerenv").exists(),
    ])

is_macos   = sys.platform == "darwin"
is_linux   = sys.platform.startswith("linux")
is_windows = sys.platform == "win32"

if DRY_RUN: warn("DRY RUN — no changes will be made")

IDENTITY_HOST = "dotfiles-identity.local"
GH_HOST       = "dotfiles-gh.local"

# ── git credential-store seeding ─────────────────────────────────────────────
# Retires with: #44 (Ansible role `secrets`).
#
# install.py already rendered ~/.gitconfig (and, on first run, created
# ~/.gitconfig.local) before this module runs -- see install.py's "git"
# section for why that chain stays there rather than moving here. This
# section only WRITES to the credential store; nothing downstream in the
# original script ever read those writes back in the same run, so moving
# them here (after all linking) changes console-message ordering only, not
# final state.
log("Git identity credential-store seeding...")
effective_name  = run("git", "config", "--file", str(HOME / ".gitconfig"), "--get", "user.name").stdout.strip()
effective_email = run("git", "config", "--file", str(HOME / ".gitconfig"), "--get", "user.email").stdout.strip()

if effective_name and effective_email and not is_devcontainer() and not is_windows:
    # Push git identity into the credential store under a synthetic host so
    # devcontainers can pull it via `git credential fill dotfiles-identity.local`.
    # Skipped on Windows — GCM handles devcontainer credential forwarding natively
    # and shows interactive dialogs for unrecognised hosts regardless of env flags.
    if DRY_RUN:
        print(f"  would write git identity to credential store: host={IDENTITY_HOST} username={effective_name}")
    else:
        git_credential_approve("https", IDENTITY_HOST, effective_name, effective_email)

if not is_devcontainer() and not is_windows and shutil.which("gh"):
    if DRY_RUN:
        print(f"  would write gh OAuth token to credential store: host={GH_HOST} username=gh-cli (skipping 'gh auth token')")
    else:
        gh_token = run("gh", "auth", "token", timeout=10).stdout.strip()
        if gh_token:
            git_credential_approve("https", GH_HOST, "gh-cli", gh_token)
            readback = git_credential_fill("https", GH_HOST, "gh-cli").get("password", "")
            if readback != gh_token:
                warn("gh token approve reported success but reading it back didn't match — likely not persisted. "
                     "Run 'git config --get credential.helper' to check. See secrets/README.md.")

# ── starship ──────────────────────────────────────────────────────────────────
# Retires with: #41 (Ansible role `packages`). The config symlink itself
# stayed in install.py; only the binary install is here.
log("Starship...")
if is_linux and not shutil.which("starship"):
    if DRY_RUN:
        print("  would install starship to ~/.local/bin (curl https://starship.rs/install.sh)")
    else:
        local_bin = HOME / ".local" / "bin"
        local_bin.mkdir(parents=True, exist_ok=True)
        r = subprocess.run(
            f"curl -fsSL https://starship.rs/install.sh | sh -s -- --yes -b {local_bin}",
            shell=True,
        )
        if r.returncode != 0:
            warn("starship install skipped (no curl or offline)")

# ── neovim ────────────────────────────────────────────────────────────────────
# Retires with: #41 (Ansible role `packages`). The config symlink itself
# stayed in install.py; only the binary install is here.
log("Neovim...")
if is_linux and not shutil.which("nvim"):
    if DRY_RUN:
        print("  would install neovim to ~/.local (GitHub releases tarball)")
    else:
        _arch = "x86_64" if platform.machine() == "x86_64" else "arm64"
        _url  = f"https://github.com/neovim/neovim/releases/latest/download/nvim-linux-{_arch}.tar.gz"
        log(f"Installing neovim ({_arch})...")
        try:
            with tempfile.TemporaryDirectory() as _tmp:
                _tar = Path(_tmp) / "nvim.tar.gz"
                urllib.request.urlretrieve(_url, _tar)
                (HOME / ".local").mkdir(parents=True, exist_ok=True)
                subprocess.run(
                    ["tar", "xzf", str(_tar), "--strip-components=1", "-C", str(HOME / ".local")],
                    check=True,
                )
            success("neovim installed")
        except Exception as _e:
            warn(f"neovim install skipped: {_e}")

# ── lazygit ───────────────────────────────────────────────────────────────────
# Retires with: #41 (Ansible role `packages`). The config symlink itself
# stayed in install.py; only the binary install is here.
log("lazygit...")
if is_linux and not shutil.which("lazygit"):
    if DRY_RUN:
        print("  would install lazygit to ~/.local/bin (GitHub releases)")
    else:
        _arch = "x86_64" if platform.machine() == "x86_64" else "arm64"
        log("Installing lazygit...")
        try:
            with urllib.request.urlopen(
                "https://api.github.com/repos/jesseduffield/lazygit/releases/latest"
            ) as _r:
                _ver = json.loads(_r.read())["tag_name"].lstrip("v")
            _url = (
                f"https://github.com/jesseduffield/lazygit/releases/download/v{_ver}/"
                f"lazygit_{_ver}_Linux_{_arch}.tar.gz"
            )
            with tempfile.TemporaryDirectory() as _tmp:
                _tar = Path(_tmp) / "lazygit.tar.gz"
                urllib.request.urlretrieve(_url, _tar)
                subprocess.run(["tar", "xzf", str(_tar), "-C", _tmp, "lazygit"], check=True)
                _bin = HOME / ".local" / "bin"
                _bin.mkdir(parents=True, exist_ok=True)
                shutil.move(str(Path(_tmp) / "lazygit"), str(_bin / "lazygit"))
                (_bin / "lazygit").chmod(0o755)
            success(f"lazygit v{_ver} installed")
        except Exception as _e:
            warn(f"lazygit install skipped: {_e}")

# ── yazi ──────────────────────────────────────────────────────────────────────
# Retires with: #41 (Ansible role `packages`). The config symlink itself
# stayed in install.py; only the binary install is here.
log("yazi...")
if is_linux and not shutil.which("yazi"):
    if DRY_RUN:
        print("  would install yazi to ~/.local/bin (GitHub releases zip)")
    else:
        _arch = "x86_64" if platform.machine() == "x86_64" else "aarch64"
        _zip_name = f"yazi-{_arch}-unknown-linux-musl.zip"
        _url = f"https://github.com/sxyazi/yazi/releases/latest/download/{_zip_name}"
        log(f"Installing yazi ({_arch})...")
        try:
            with tempfile.TemporaryDirectory() as _tmp:
                _zippath = Path(_tmp) / "yazi.zip"
                urllib.request.urlretrieve(_url, _zippath)
                _bin = HOME / ".local" / "bin"
                _bin.mkdir(parents=True, exist_ok=True)
                _prefix = f"yazi-{_arch}-unknown-linux-musl"
                with zipfile.ZipFile(_zippath) as _zf:
                    for _name in ("yazi", "ya"):
                        _member = f"{_prefix}/{_name}"
                        if _member in _zf.namelist():
                            (_bin / _name).write_bytes(_zf.read(_member))
                            (_bin / _name).chmod(0o755)
            success("yazi installed")
        except Exception as _e:
            warn(f"yazi install skipped: {_e}")

# ── Kilo Code CLI ──────────────────────────────────────────────────────────────
# Retires with: #41 (Ansible role `packages`).
# Installed alongside Claude Code wherever that tool is expected. The dependency
# is npm (provided by node — in the Brewfile on macOS, in apt.txt on Linux, or
# preinstalled in devcontainer base images). On Windows, Kilo is not installed
# natively — powershell/profile.ps1 forwards `kilo` into the WSL distro, same
# pattern as `claude`.
log("Kilo Code CLI...")
if not is_windows and not shutil.which("kilo"):
    if DRY_RUN:
        print(f"  would install kilo via: npm install -g @kilocode/cli@{KILO_CLI_VERSION}")
    else:
        _npm = shutil.which("npm")
        if _npm:
            log("Installing Kilo Code...")
            _r = subprocess.run([_npm, "install", "-g", f"@kilocode/cli@{KILO_CLI_VERSION}"],
                                capture_output=True, text=True, timeout=120)
            if _r.returncode == 0:
                success("kilo installed")
            else:
                warn(f"kilo install skipped (npm error): {(_r.stderr or '').strip()[:200]}")
        else:
            warn(f"npm not found — skipping kilo install. Run: npm install -g @kilocode/cli@{KILO_CLI_VERSION}")

# ── GitHub Copilot CLI ───────────────────────────────────────────────────────────
# Retires with: #41 (Ansible role `packages`).
# Same npm-global pattern as Kilo above. Authenticates automatically from the
# GH_TOKEN already exported by shell/exports.sh (Copilot CLI checks
# COPILOT_GITHUB_TOKEN, then GH_TOKEN, then GITHUB_TOKEN) — no separate secrets
# plumbing needed. On Windows, not installed natively — powershell/profile.ps1
# forwards `copilot` into the WSL distro, same pattern as `claude`/`kilo`.
log("GitHub Copilot CLI...")
if not is_windows and not shutil.which("copilot"):
    if DRY_RUN:
        print(f"  would install copilot via: npm install -g @github/copilot@{COPILOT_CLI_VERSION}")
    else:
        _npm = shutil.which("npm")
        if _npm:
            log("Installing GitHub Copilot CLI...")
            _r = subprocess.run([_npm, "install", "-g", f"@github/copilot@{COPILOT_CLI_VERSION}"],
                                capture_output=True, text=True, timeout=120)
            if _r.returncode == 0:
                success("copilot installed")
            else:
                warn(f"copilot install skipped (npm error): {(_r.stderr or '').strip()[:200]}")
        else:
            warn(f"npm not found — skipping copilot install. Run: npm install -g @github/copilot@{COPILOT_CLI_VERSION}")

# ── devcontainer CLI ─────────────────────────────────────────────────────────
# Retires with: #41 (Ansible role `packages`).
# Same npm-global pattern as Kilo/Copilot above. Backs tools/start-project.sh
# (the `sp` alias), which builds/starts a project's devcontainer from the
# terminal the way VS Code's "Reopen in Container" does from its UI.
log("devcontainer CLI...")
if not is_windows and not shutil.which("devcontainer"):
    if DRY_RUN:
        print(f"  would install devcontainer CLI via: npm install -g @devcontainers/cli@{DEVCONTAINERS_CLI_VERSION}")
    else:
        _npm = shutil.which("npm")
        if _npm:
            log("Installing devcontainer CLI...")
            _r = subprocess.run([_npm, "install", "-g", f"@devcontainers/cli@{DEVCONTAINERS_CLI_VERSION}"],
                                capture_output=True, text=True, timeout=120)
            if _r.returncode == 0:
                success("devcontainer CLI installed")
            else:
                warn(f"devcontainer CLI install skipped (npm error): {(_r.stderr or '').strip()[:200]}")
        else:
            warn(f"npm not found — skipping devcontainer CLI install. Run: npm install -g @devcontainers/cli@{DEVCONTAINERS_CLI_VERSION}")

# ── rtk (Rust Token Killer) ──────────────────────────────────────────────────
# Retires with: #41 (Ansible role `packages`).
# CLI proxy that filters/compresses command output before it reaches an agent's
# context. Wired into Claude Code by claude/hooks/rtk-rewrite.sh (registered in
# claude/settings.json), which transparently rewrites e.g. `git status` to
# `rtk git status`. No apt/npm package — install from the project's own release
# script (pinned to a commit via RTK_INSTALLER_SHA; it then downloads and
# checksum-verifies the RTK_VERSION binary — see the constants block). Lands in
# ~/.local/bin (already on PATH via shell/exports.sh). Not installed on Windows —
# powershell/profile.ps1 forwards `rtk` into the WSL distro, same as `claude`.
log("rtk (Rust Token Killer)...")
_rtk_url = f"https://raw.githubusercontent.com/rtk-ai/rtk/{RTK_INSTALLER_SHA}/install.sh"
_rtk_hint = f'curl -fsSL "{_rtk_url}" | RTK_VERSION={RTK_VERSION} sh'
if not is_windows and not shutil.which("rtk"):
    if DRY_RUN:
        print(f"  would install rtk via: {_rtk_hint}")
    elif shutil.which("curl"):
        log("Installing rtk...")
        # Download then run (not `curl | sh`): a failed download must not leave
        # an empty stdin that `sh` exits 0 on, reporting a phantom success.
        _r = subprocess.run(
            f'_t=$(mktemp) && curl -fsSL "{_rtk_url}" -o "$_t" '
            f'&& RTK_VERSION={RTK_VERSION} sh "$_t"; _rc=$?; rm -f "$_t"; exit $_rc',
            shell=True, capture_output=True, text=True, timeout=180)
        if _r.returncode == 0:
            success("rtk installed")
        else:
            warn(f"rtk install skipped (installer error): {(_r.stderr or '').strip()[:200]}")
    else:
        warn(f"curl not found — skipping rtk install. Run: {_rtk_hint}")

# ── devcontainer extras ───────────────────────────────────────────────────────
# Retires with: #41 (Ansible role `packages`, for the binary installs and
# ensure-delta.sh) and #44 (Ansible role `secrets`, for the credential-
# forwarding checks and onboarding pre-configuration below).
if is_devcontainer():
    log("Devcontainer extras...")

    if not shutil.which("claude") and not DRY_RUN:
        log("Installing Claude Code in container...")
        if subprocess.run("curl -fsSL https://claude.ai/install.sh | bash", shell=True).returncode != 0:
            warn("Claude Code install skipped (no curl or offline)")

    if not shutil.which("kilo") and not DRY_RUN:
        log("Installing Kilo Code in container...")
        if subprocess.run(f"npm install -g @kilocode/cli@{KILO_CLI_VERSION}", shell=True).returncode != 0:
            warn("Kilo Code install skipped (no npm or offline)")

    if not shutil.which("copilot") and not DRY_RUN:
        log("Installing GitHub Copilot CLI in container...")
        if subprocess.run(f"npm install -g @github/copilot@{COPILOT_CLI_VERSION}", shell=True).returncode != 0:
            warn("GitHub Copilot CLI install skipped (no npm or offline)")

    if not shutil.which("gh") and not DRY_RUN:
        log("Installing gh in container...")
        r = subprocess.run(
            "sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends gh",
            shell=True,
        )
        if r.returncode != 0:
            warn("gh install skipped (no sudo/network, offline, or not in this image's apt sources)")

    if DRY_RUN:
        print("  would check/install delta (git/ensure-delta.sh)")
    else:
        subprocess.run(["bash", str(DOTFILES / "git" / "ensure-delta.sh")], check=True)

    CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", str(HOME / ".cache"))) / "dotfiles"
    SENTINEL  = CACHE_DIR / "claude-token.configured"

    if not SENTINEL.exists() and shutil.which("git") and not DRY_RUN:
        log("Checking Claude Code credential forwarding...")
        creds = git_credential_fill("https", "dotfiles-secrets.local", "claude-code")
        forwarded = creds.get("password", "")
        if forwarded:
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            SENTINEL.touch()
            log("Credential forwarding confirmed — CLAUDE_CODE_OAUTH_TOKEN will be exported automatically in new shells.")
            if shutil.which("jq"):
                claude_json = HOME / ".claude.json"
                if not claude_json.exists():
                    claude_json.write_text("{}", encoding="utf-8")
                r = subprocess.run(["jq", ".hasCompletedOnboarding = true", str(claude_json)],
                                   capture_output=True, text=True)
                if r.returncode == 0:
                    write_through_symlink(claude_json, r.stdout)
                claude_dir = HOME / ".claude"
                settings_json = claude_dir / "settings.json"
                real_settings = settings_json.resolve() if settings_json.is_symlink() else settings_json
                if not real_settings.exists():
                    real_settings.write_text("{}", encoding="utf-8")
                r2 = subprocess.run(["jq", '.theme = "light-daltonized"', str(real_settings)],
                                    capture_output=True, text=True)
                if r2.returncode == 0:
                    write_through_symlink(real_settings, r2.stdout)
                log("Claude Code onboarding (login picker + theme) pre-configured.")
            else:
                warn("jq not found — skipping Claude Code onboarding pre-configuration.")
        else:
            warn("Credential forwarding not confirmed for Claude Code token — new shells won't export it automatically. "
                 "See secrets/README.md.")

    GH_SENTINEL = CACHE_DIR / "gh-token.configured"
    if not GH_SENTINEL.exists() and shutil.which("git") and not DRY_RUN:
        log("Checking gh credential forwarding...")
        gh_creds = git_credential_fill("https", GH_HOST, "gh-cli")
        if gh_creds.get("password"):
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            GH_SENTINEL.touch()
            log("gh credential forwarding confirmed — GH_TOKEN will be exported automatically in new shells.")
        else:
            warn("Credential forwarding not confirmed for gh token — new shells won't export GH_TOKEN automatically. "
                 "Run 'gh auth login' on the host and rebuild, or inside this container directly. See secrets/README.md.")

    OPENROUTER_HOST = "dotfiles-openrouter.local"
    OPENROUTER_SENTINEL = CACHE_DIR / "openrouter-token.configured"
    if not OPENROUTER_SENTINEL.exists() and shutil.which("git") and not DRY_RUN:
        log("Checking OpenRouter credential forwarding...")
        or_creds = git_credential_fill("https", OPENROUTER_HOST, "openrouter")
        if or_creds.get("password"):
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            OPENROUTER_SENTINEL.touch()
            log("OpenRouter credential forwarding confirmed — OPENROUTER_API_KEY will be exported automatically in new shells.")
        else:
            warn("Credential forwarding not confirmed for OpenRouter key — new shells won't export OPENROUTER_API_KEY automatically. "
                 "See secrets/README.md.")

# ── macOS system defaults ─────────────────────────────────────────────────────
# Retires with: #42 (Ansible role `macos`).
#
# NOT gated on DRY_RUN in the original install.py either -- that gap is
# inherited verbatim here, not introduced by this move. Flagged in this PR's
# description as a pre-existing finding rather than silently fixed, per the
# #39 brief's "move, don't improve" instruction: fixing it would be a
# behaviour change riding along on a refactor, and it cannot be exercised
# from this (non-macOS) verification environment regardless.
if is_macos and not is_devcontainer():
    defaults_sh = DOTFILES / "macos" / "defaults.sh"
    if defaults_sh.exists():
        log("macOS defaults...")
        subprocess.run(["bash", str(defaults_sh)], check=True)

sys.exit(0)
