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

def link(src: Path, dst: Path):
    src, dst = Path(src), Path(dst)
    if DRY_RUN:
        print(f"  link: {src} → {dst}"); return
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.is_symlink():
        dst.unlink()
    elif dst.exists():
        warn(f"Backing up {dst} → {dst}.bak"); dst.replace(str(dst) + ".bak")
    dst.symlink_to(src)
    success(f"linked {dst}")

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

def run(*cmd, **kw):
    return subprocess.run(list(cmd), capture_output=True, text=True, **kw)

def git_credential_fill(protocol, host, username=None):
    inp = f"protocol={protocol}\nhost={host}\n"
    if username:
        inp += f"username={username}\n"
    try:
        r = subprocess.run(
            ["git", "-c", "credential.interactive=false", "credential", "fill"],
            input=inp, capture_output=True, text=True, timeout=5,
        )
        return dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line)
    except Exception:
        return {}

def git_credential_approve(protocol, host, username, password):
    inp = f"protocol={protocol}\nhost={host}\nusername={username}\npassword={password}\n"
    try:
        subprocess.run(["git", "credential", "approve"], input=inp, capture_output=True, text=True, timeout=5)
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
gitconfig_rendered = gitconfig_marker + gitconfig_template + "\n" + gitconfig_local_content
render(gitconfig_rendered, HOME / ".gitconfig", gitconfig_marker)

effective_name  = run("git", "config", "--file", str(HOME / ".gitconfig"), "--get", "user.name").stdout.strip()
effective_email = run("git", "config", "--file", str(HOME / ".gitconfig"), "--get", "user.email").stdout.strip()

if not effective_name or not effective_email:
    warn("No git identity set — run: git config user.name \"Your Name\" && git config user.email you@example.com "
         "(or edit ~/.gitconfig.local and re-run install).")
elif not is_devcontainer():
    git_credential_approve("https", IDENTITY_HOST, effective_name, effective_email)

if not is_devcontainer() and shutil.which("gh"):
    gh_token = run("gh", "auth", "token").stdout.strip()
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

# ── shell ─────────────────────────────────────────────────────────────────────
log("Shell...")
link(DOTFILES / "shell" / "aliases.sh",     HOME / ".aliases")
link(DOTFILES / "shell" / "exports.sh",     HOME / ".exports")
link(DOTFILES / "shell" / "doctor.sh",      HOME / ".doctor")
link(DOTFILES / "shell" / "self-heal.sh",   HOME / ".self-heal")
link(DOTFILES / "shell" / ".bashrc",        HOME / ".bashrc")
link(DOTFILES / "shell" / ".bash_profile",  HOME / ".bash_profile")
link(DOTFILES / "shell" / ".zshrc",         HOME / ".zshrc")
link(DOTFILES / "shell" / ".zprofile",      HOME / ".zprofile")

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

# ── Claude Code ───────────────────────────────────────────────────────────────
log("Claude Code global config...")
claude_dir = HOME / ".claude"
link(DOTFILES / "claude" / "CLAUDE.md",             claude_dir / "CLAUDE.md")
link(DOTFILES / "claude" / "settings.json",          claude_dir / "settings.json")
link(DOTFILES / "claude" / "statusline-command.sh",  claude_dir / "statusline-command.sh")

# ── devcontainer extras ───────────────────────────────────────────────────────
if is_devcontainer():
    log("Devcontainer extras...")

    if not shutil.which("claude") and not DRY_RUN:
        log("Installing Claude Code in container...")
        if subprocess.run("curl -fsSL https://claude.ai/install.sh | bash", shell=True).returncode != 0:
            warn("Claude Code install skipped (no curl or offline)")

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

# ── macOS system defaults ─────────────────────────────────────────────────────
if is_macos and not is_devcontainer():
    defaults_sh = DOTFILES / "macos" / "defaults.sh"
    if defaults_sh.exists():
        log("macOS defaults...")
        subprocess.run(["bash", str(defaults_sh)], check=True)

success("Done! Open a new shell or: source ~/.zshrc (or ~/.bashrc)")
