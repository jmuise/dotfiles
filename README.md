# dotfiles

Personal dev machine config for macOS, Linux, and Windows — built to work seamlessly inside **devcontainers**.

## What's included

| Path | What it configures |
|------|-------------------|
| `git/` | `.gitconfig` with aliases, delta diff, sane push/pull defaults |
| `shell/` | `.zshrc`, `.bashrc`, shared `aliases.sh` and `exports.sh` |
| `powershell/` | PowerShell profile with PSReadLine and posh-git |
| `vscode/` | `settings.json`, `keybindings.json`, `extensions.txt` |
| `starship/` | Cross-shell prompt config |
| `tmux/` | `.tmux.conf` with vim-style nav and Catppuccin colours |
| `ssh/` | `config.example` template (no keys) |
| `packages/` | `Brewfile`, `apt.txt`, `winget.txt` |
| `macos/` | Sensible `defaults write` settings |

## Install

### macOS / Linux

```bash
git clone https://github.com/jeremymuise/dotfiles ~/dotfiles
cd ~/dotfiles
./install.sh
```

Preview what will be symlinked first:

```bash
./install.sh --dry-run
```

### Windows (PowerShell — run as admin, or with Developer Mode enabled)

```powershell
git clone https://github.com/jeremymuise/dotfiles $HOME\dotfiles
cd $HOME\dotfiles
.\install.ps1
```

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

## Devcontainers

VS Code will automatically clone this repo and run `install.sh` inside every devcontainer you open, giving you your shell config, git aliases, and starship prompt everywhere.

**Enable it once in VS Code settings:**

```json
"dotfiles.repository": "https://github.com/jeremymuise/dotfiles",
"dotfiles.targetPath": "~/dotfiles",
"dotfiles.installCommand": "~/dotfiles/install.sh"
```

These are already set in `vscode/settings.json`. The install script detects the container context (`/.dockerenv`, `$REMOTE_CONTAINERS`, `$CODESPACES`) and skips host-only steps like VS Code settings and macOS defaults. It will attempt to install starship if it's missing from the base image.

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
│   └── profile.ps1
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
│   └── winget.txt
└── macos/
    └── defaults.sh
```

## Security

- No secrets, keys, tokens, or credentials are committed
- `~/.gitconfig.local`, `~/.ssh/config`, and `*.local` files are in `.gitignore`
- SSH config is copied (not symlinked) so you can add host entries without affecting the repo
- `.gitignore_global` blocks common secret file patterns globally
