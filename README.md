# dotfiles

Personal dev machine config for macOS, Linux, and Windows — built to work seamlessly inside **devcontainers**.

## What's included

| Path | What it configures |
|------|-------------------|
| `git/` | `.gitconfig` with aliases, delta diff, sane push/pull defaults |
| `shell/` | `.zshrc`, `.bashrc`, shared `aliases.sh` and `exports.sh` |
| `powershell/` | PowerShell 7+ profile (PSReadLine, posh-git) + a Windows PowerShell 5.1 shim that hands off to pwsh |
| `cmd/` | `init.cmd` — doskey macros + prompt for cmd.exe, loaded via AutoRun |
| `vscode/` | `settings.json`, `keybindings.json`, `extensions.txt` |
| `starship/` | Cross-shell prompt config |
| `tmux/` | `.tmux.conf` with vim-style nav and Catppuccin colours |
| `ssh/` | `config.example` template (no keys) |
| `packages/` | `Brewfile`, `apt.txt`, `winget.txt` + a versioned lockfile/update-review workflow for winget |
| `macos/` | Sensible `defaults write` settings |

## Install

### macOS / Linux

```bash
git clone https://github.com/jmuise/dotfiles ~/dotfiles
cd ~/dotfiles
./install.sh
```

Preview what will be symlinked first:

```bash
./install.sh --dry-run
```

### Windows (PowerShell — run as admin, or with Developer Mode enabled)

```powershell
git clone https://github.com/jmuise/dotfiles $HOME\dotfiles
cd $HOME\dotfiles
.\install.ps1
```

The profile targets PowerShell 7+. If you run `install.ps1` from the
built-in Windows PowerShell 5.1, it installs PowerShell 7 via winget (if
missing) and re-launches itself under it automatically — no need to install
pwsh yourself first.

### Packages

```bash
# macOS
brew bundle --file=packages/Brewfile

# Ubuntu/Debian
xargs sudo apt-get install -y < packages/apt.txt

# Windows
Get-Content packages\winget.txt |
  Where-Object { $_ -notmatch '^#|^\s*$' } |
  ForEach-Object { winget install --id $_ -e --silent }
```

#### Windows package version tracking

`packages/winget.txt` is a hand-curated list of package IDs (not a dump of
everything installed on the machine — `winget export` includes OS components
and unrelated software, so it's a poor source of truth here). Versions are
tracked separately in `packages/winget.lock.json`, a small lockfile pinning
exactly what's installed:

| Script | Purpose |
|--------|---------|
| `packages/winget-lock.ps1` | Regenerate the lock file from currently-installed versions. Run after editing `winget.txt`. |
| `packages/winget-check-updates.ps1` | Checks for newer versions and, if found, commits an updated lock file to a `winget-updates` branch — never touches your working tree or checked-out branch. Registered as a weekly Windows Task Scheduler job (`dotfiles-winget-check-updates`) by `install.ps1`. |
| `packages/winget-apply.ps1` | Installs/upgrades packages to match the pinned versions in the lock file. Run after reviewing and merging `winget-updates`. |

Review proposed updates with `git log winget-updates -p`, and accept them
with `git merge winget-updates` followed by `packages/winget-apply.ps1` —
a local, dependabot-style update loop without needing a GitHub remote.

## Devcontainers

VS Code will automatically clone this repo and run `install.sh` inside every devcontainer you open, giving you your shell config, git aliases, and starship prompt everywhere.

**Enable it once in VS Code settings:**

```json
"dotfiles.repository": "https://github.com/jmuise/dotfiles",
"dotfiles.targetPath": "~/dotfiles",
"dotfiles.installCommand": "~/dotfiles/install.sh"
```

These are already set in `vscode/settings.json`. The install script detects the container context (`/.dockerenv`, `$REMOTE_CONTAINERS`, `$CODESPACES`) and skips host-only steps like VS Code settings and macOS defaults. It will attempt to install starship if it's missing from the base image.

## cmd.exe

`install.ps1` sets `HKCU\Software\Microsoft\Command Processor\AutoRun` to run
`cmd\init.cmd` at the start of every new cmd session (existing AutoRun entries
are preserved and chained, not overwritten). `init.cmd` defines doskey macros
for the same git/nav/docker aliases as `shell/aliases.sh` and
`powershell/profile.ps1`, and switches `ls`/`ll`/`cat`/`grep` to eza/bat/rg
when those are installed.

cmd has no scripting hook for a starship-style dynamic prompt — `init.cmd`
just colors the path so it isn't jarring next to the other shells. For a real
shared prompt in cmd, install [Clink](https://chrisant996.github.io/clink/)
(`winget install chrisant996.Clink`) and point it at a `starship init cmd`
script; Clink gives cmd the same shell-integration hooks bash/zsh/PowerShell
already have.

AutoRun is skipped if cmd is started with `cmd /D`.

## Machine-specific config

Never committed, never leaked — put machine-specific overrides in local files that the shell configs source automatically:

| File | For |
|------|-----|
| `~/.gitconfig.local` | Your `user.name` and `user.email` |
| `~/.bashrc.local` | Bash overrides for this machine |
| `~/.zshrc.local` | Zsh overrides for this machine |
| `~/.aliases.local` | Extra aliases |
| `~/.ssh/config` | SSH hosts (copied from `ssh/config.example`, not symlinked) |

The installer creates `~/.gitconfig.local` on first run with placeholder values.

## Structure

```
dotfiles/
├── install.sh          ← Unix entry point (bash/zsh/devcontainer)
├── install.ps1         ← Windows entry point (PowerShell)
├── git/
│   ├── .gitconfig
│   └── .gitignore_global
├── shell/
│   ├── .bashrc
│   ├── .bash_profile
│   ├── .zshrc
│   ├── .zprofile
│   ├── aliases.sh      ← sourced by both bash + zsh
│   └── exports.sh      ← sourced by both bash + zsh
├── powershell/
│   ├── profile.ps1        ← pwsh 7+ profile
│   └── profile.legacy.ps1 ← Windows PowerShell 5.1 shim, hands off to pwsh
├── cmd/
│   └── init.cmd
├── vscode/
│   ├── settings.json
│   ├── keybindings.json
│   └── extensions.txt
├── starship/
│   └── starship.toml
├── tmux/
│   └── .tmux.conf
├── ssh/
│   └── config.example  ← template only, never symlinked
├── packages/
│   ├── Brewfile
│   ├── apt.txt
│   ├── winget.txt
│   ├── winget.lock.json         ← pinned installed versions
│   ├── winget-lock.ps1          ← regenerate the lock file
│   ├── winget-check-updates.ps1 ← weekly scheduled update check
│   └── winget-apply.ps1         ← sync machine to the lock file
└── macos/
    └── defaults.sh
```

## Security

- No secrets, keys, tokens, or credentials are committed
- `~/.gitconfig.local`, `~/.ssh/config`, and `*.local` files are in `.gitignore`
- SSH config is copied (not symlinked) so you can add host entries without affecting the repo
- `.gitignore_global` blocks common secret file patterns globally
