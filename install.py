#!/usr/bin/env python3
"""
install.py -- shared dotfiles installer core for macOS, Linux, devcontainers, and Windows.
Called by install.sh and install.ps1; not meant to be run directly.

Usage (via wrappers):
    ./install.sh [--dry-run]
    .\\install.ps1 [-DryRun]
"""

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

DOTFILES = Path(__file__).parent.resolve()
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
GH_HOST       = "dotfiles-gh.local"

# ── git ───────────────────────────────────────────────────────────────────────
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
elif not is_devcontainer() and not is_windows:
    # Push git identity into the credential store under a synthetic host so
    # devcontainers can pull it via `git credential fill dotfiles-identity.local`.
    # Skipped on Windows — GCM handles devcontainer credential forwarding natively
    # and shows interactive dialogs for unrecognised hosts regardless of env flags.
    git_credential_approve("https", IDENTITY_HOST, effective_name, effective_email)

if not is_devcontainer() and not is_windows and shutil.which("gh"):
    gh_token = run("gh", "auth", "token", timeout=10).stdout.strip()
    if gh_token:
        git_credential_approve("https", GH_HOST, "gh-cli", gh_token)
        readback = git_credential_fill("https", GH_HOST, "gh-cli").get("password", "")
        if readback != gh_token:
            warn("gh token approve reported success but reading it back didn't match — likely not persisted. "
                 "Run 'git config --get credential.helper' to check. See secrets/README.md.")

# ── git hooks ─────────────────────────────────────────────────────────────────
log("Git hooks...")
if DRY_RUN:
    print("  git config core.hooksPath hooks")
else:
    subprocess.run(["git", "-C", str(DOTFILES), "config", "core.hooksPath", "hooks"], check=True)
    for h in (DOTFILES / "hooks").glob("*"):
        h.chmod(h.stat().st_mode | 0o111)
    success("core.hooksPath -> hooks")

existing_global_hooks = run("git", "config", "--global", "--get", "core.hooksPath").stdout.strip()
if existing_global_hooks == str(DOTFILES / "git" / "global-hooks"):
    if DRY_RUN:
        print("  git config --global --unset core.hooksPath")
    else:
        run("git", "config", "--global", "--unset", "core.hooksPath")
        success("Removed global core.hooksPath (identity guard retired in favor of shell/doctor.sh)")

# ── install receipt ──────────────────────────────────────────────────────────
# Records which checkout this $HOME was deliberately installed from, so
# hooks/_dispatch.sh can tell a real install from an incidental one. A `git
# worktree add` shares the primary checkout's .git/config -- including the
# core.hooksPath just set above -- and since `hooks` is a relative path it
# resolves inside whichever checkout the hook actually fires from; without
# this, a branch switch inside a brand-new, possibly-unreviewed worktree would
# silently install that worktree's content into the real $HOME. Same for
# `git clone -c core.hooksPath=hooks`, which persists the setting into a
# fresh clone and fires on its first checkout. The receipt has to live
# outside the repo (a clone would copy an in-repo marker along with it) and
# outside .git/config (worktrees share that file), so ~/.local/state is the
# only location that's both durable and tied to this $HOME rather than to any
# one checkout. See hooks/_dispatch.sh for the guard that reads this back.
log("Install receipt...")
if DRY_RUN:
    print(f"  would record install root: {DOTFILES}")
else:
    receipt = HOME / ".local" / "state" / "dotfiles" / "install-root"
    receipt.parent.mkdir(parents=True, exist_ok=True)
    # Refuse to write through a symlink. write_text() opens with plain
    # open(..., "w"), which follows symlinks and truncates whatever they
    # point at -- a symlink planted at the receipt path (or its immediate
    # parent dir) before this runs would turn a routine install into an
    # attacker-chosen arbitrary-file overwrite. Same awareness as
    # write_through_symlink() above, applied in the opposite direction: that
    # helper deliberately follows a symlink because a user's own dotfile
    # symlinks are meant to be written through; this receipt has no
    # legitimate reason to ever be a symlink, so we refuse instead.
    if receipt.parent.is_symlink():
        error(f"{receipt.parent} is a symlink — refusing to write install receipt through it")
        sys.exit(1)
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
link(DOTFILES / "starship" / "starship.toml", HOME / ".config" / "starship.toml")

# ── tmux ──────────────────────────────────────────────────────────────────────
link(DOTFILES / "tmux" / ".tmux.conf", HOME / ".tmux.conf")

# ── neovim ────────────────────────────────────────────────────────────────────
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
link(DOTFILES / "nvim", HOME / ".config" / "nvim")

# ── lazygit ───────────────────────────────────────────────────────────────────
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
link(DOTFILES / "lazygit" / "config.yml", HOME / ".config" / "lazygit" / "config.yml")

# ── yazi ──────────────────────────────────────────────────────────────────────
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
link(DOTFILES / "yazi", HOME / ".config" / "yazi")

# ── Kilo Code CLI ──────────────────────────────────────────────────────────────
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
link(DOTFILES / "claude" / "CLAUDE.md",             claude_dir / "CLAUDE.md")
link(DOTFILES / "claude" / "settings.json",          claude_dir / "settings.json")
link(DOTFILES / "claude" / "statusline-command.sh",  claude_dir / "statusline-command.sh")
link(DOTFILES / "claude" / "agents",                 claude_dir / "agents")
link(DOTFILES / "claude" / "hooks",                  claude_dir / "hooks")
link(DOTFILES / "claude" / "skills",                 claude_dir / "skills")

# ── Kilo Code ───────────────────────────────────────────────────────────────────
# Same schema, same structure as the ~/.config/kilo/ directory Kilo itself
# creates — config files are symlinked from the repo just like the claude/
# entries above. The global instructions file is shared from claude/CLAUDE.md
# (one source of truth — the content is tool-agnostic, so both Claude Code
# reading CLAUDE.md and Kilo reading AGENTS.md see the same rules).
log("Kilo Code global config...")
kilo_config_dir = HOME / ".config" / "kilo"
link(DOTFILES / "claude" / "CLAUDE.md",              kilo_config_dir / "AGENTS.md")
link(DOTFILES / "kilo" / "kilo.jsonc",               kilo_config_dir / "kilo.jsonc")
link(DOTFILES / "kilo" / "tui.jsonc",                kilo_config_dir / "tui.jsonc")
link(DOTFILES / "kilo" / ".kilo",                    kilo_config_dir / ".kilo")
# Plugin directory must be a real symlink, not just a config-file reference:
# kilo.jsonc's `plugin` array resolves relative paths against the *literal*
# path of the config file (this symlink target's parent), not its realpath,
# so without this the require-devcontainer plugin would silently fail to load
# -- confirmed empirically, no error, no log line, the hook just never fires.
link(DOTFILES / "kilo" / "plugin",                   kilo_config_dir / "plugin")

# ── GitHub Copilot CLI ───────────────────────────────────────────────────────────
# Same one-source-of-truth pattern as Kilo above — Copilot CLI reads global
# instructions from ~/.copilot/copilot-instructions.md, symlinked straight from
# claude/CLAUDE.md rather than duplicated. Skills are shared the same way, from
# claude/skills; everything genuinely Copilot-specific (the devcontainer hook
# shim, its wiring, and the agent roster in Copilot's own schema) lives in
# copilot/.
log("GitHub Copilot CLI global config...")
copilot_dir = HOME / ".copilot"
link(DOTFILES / "claude" / "CLAUDE.md",      copilot_dir / "copilot-instructions.md")

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
# UNCONDITIONAL, EVERY RUN, BEFORE THE LINK. A settings.json the CLI cannot parse
# turns the devcontainer guard off with no warning of any kind (see the function's
# docstring), so the only place that can be caught is here. Gate the symlink on it:
# installing a file we know is broken would be actively worse than leaving the
# previous one in place.
copilot_settings_ok = check_copilot_settings_parse(copilot_settings_src)
report_detached_copilot_settings(copilot_settings_src, copilot_dir / "settings.json")
# Hooks must be configured in settings.json, NOT config.json. Put them in
# config.json and they appear to work exactly once, after which the CLI migrates
# them out, logs `Settings migration: "hooks" differs...` and deletes them --
# leaving the devcontainer guard silently gone with nothing to notice. Copilot
# says as much in config.json's own header ("User settings belong in
# settings.json", "This file is managed automatically"), so config.json is
# deliberately left alone here and never symlinked.
#
# This link is also the REPAIR for the detached case reported just above, not only
# a first-install step: it is the only thing that reattaches the live config to
# this repo after the CLI has rewritten it. Re-run install.py whenever
# `ls -l ~/.copilot/settings.json` shows a regular file instead of a symlink.
if copilot_settings_ok:
    link(copilot_settings_src, copilot_dir / "settings.json")
else:
    error(f"SKIPPED linking {copilot_dir / 'settings.json'} — see the errors above.")
# The hooks directory symlink is load-bearing, not cosmetic -- same class of trap
# as Kilo's plugin dir above. copilot/settings.json invokes the guard as
# `bash "$HOME/.copilot/hooks/require-devcontainer.sh"` (Copilot does expand
# $HOME inside a hook command -- verified empirically, it is undocumented), so
# without this link the script simply is not there and the guard never fires:
# no error, no log line, just an unguarded session.
link(DOTFILES / "copilot" / "hooks",         copilot_dir / "hooks")
# Personal custom agents -- Copilot discovers them as ~/.copilot/agents/*.agent.md.
link(DOTFILES / "copilot" / "agents",        copilot_dir / "agents")
# Skills point at claude/skills deliberately: the SAME source of truth Claude
# Code uses, not a copy. Copilot reads SKILL.md in the identical format, and a
# whole-directory symlink here was confirmed to list every skill under "Personal
# skills" in a live session and to actually load them. Same reasoning as
# copilot-instructions.md above and Kilo's AGENTS.md -- one file, both tools.
link(DOTFILES / "claude" / "skills",         copilot_dir / "skills")

# ── devcontainer extras ───────────────────────────────────────────────────────
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
if is_macos and not is_devcontainer():
    defaults_sh = DOTFILES / "macos" / "defaults.sh"
    if defaults_sh.exists():
        log("macOS defaults...")
        subprocess.run(["bash", str(defaults_sh)], check=True)

if shell_changed:
    success("Done! Shell config changed -- open a new shell or: source ~/.zshrc (or ~/.bashrc)")
else:
    success("Done! No shell-init files changed -- no new shell needed.")

# Restated last, on purpose. A broken copilot/settings.json silently disables the
# devcontainer guard, and an error a few hundred lines up the scrollback is an
# error nobody reads. Non-zero exit so a caller (or CI) notices too.
if not copilot_settings_ok:
    error("copilot/settings.json did NOT parse and was not installed — the Copilot"
          " devcontainer guard is not wired up. Fix it and re-run this script.")
    sys.exit(1)
