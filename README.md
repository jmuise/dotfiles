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
| `secrets/` | One-time setup scripts that seed `CLAUDE_CODE_OAUTH_TOKEN` (and reuse `gh`'s own session for `GH_TOKEN`) via your OS credential store — see [secrets/README.md](secrets/README.md) |
| `packages/` | `Brewfile`, `apt.txt`, `winget.txt` + a versioned lockfile/update-review workflow for winget |
| `macos/` | Sensible `defaults write` settings |
| `wsl/` | Provisions WSL Debian as the primary Windows shell (apt packages, gitconfig migration, `install.sh`) |
| `windows-terminal/` | Points Windows Terminal's default profile at Debian WSL |

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

By default `install.ps1` also provisions WSL Debian as your primary shell and
points Windows Terminal at it — see [WSL](#wsl-debian) below. Pass `-SkipWSL`
to skip both and keep `install.ps1` Windows-native-only.

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

VS Code will automatically clone this repo and run `install.sh` inside every devcontainer you open, giving you your shell config, git aliases, starship prompt, the Claude Code CLI, the GitHub CLI (`gh`), and `delta` everywhere.

**Enable it once in VS Code settings:**

```json
"dotfiles.repository": "https://github.com/jmuise/dotfiles",
"dotfiles.targetPath": "~/dotfiles",
"dotfiles.installCommand": "~/dotfiles/install.sh"
```

These are already set in `vscode/settings.json`. The install script detects the container context (`/.dockerenv`, `$REMOTE_CONTAINERS`, `$CODESPACES`) and skips host-only steps like VS Code settings and macOS defaults. It will attempt to install starship, the Claude Code CLI, `gh`, and `delta` (via `apt-get`) for whichever of those are missing from the base image.

Git identity comes along for free too: VS Code's Dev Containers "copy git config" feature copies your host `~/.gitconfig` into every container automatically, and since it's a single rendered file (see [Machine-specific config](#machine-specific-config)) rather than one that `include`s another, there's nothing project-specific to configure — no per-project bind mount needed. (Copy-git-config does *not* follow `include.path` — [microsoft/vscode-remote-release#9469](https://github.com/microsoft/vscode-remote-release/issues/9469) — which is what a split file would require.)

`install.sh` also runs `git/ensure-gcm.sh` inside the container if no
`credential.helper` is already active — a backstop alongside VS Code's own
git-credential forwarding, since the latter is only confirmed to work for
real git hosts, not the synthetic host `secrets/` uses for the Claude Code
token (see [secrets/README.md](secrets/README.md)).

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

## WSL (Debian)

cmd/PowerShell parity only goes so far — some tools (tmux, for one) have no
native Windows port at all. So `install.ps1` provisions **WSL Debian as the
real primary shell** and points Windows Terminal's default profile at it,
rather than trying to reimplement a Linux environment on top of Windows.

`wsl/bootstrap.ps1` detects readiness in four states and only automates what's
safe to automate:

| State | What happens |
|-------|--------------|
| WSL not installed | Prints manual install guidance — not safe to enable OS features unattended |
| WSL installed, no Debian distro | Runs `wsl --install -d Debian`, then asks you to reboot if prompted and complete Debian's first-run username/password setup, then re-run `install.ps1` |
| Debian installed, first-run setup not done | Asks you to open "Debian" from the Start menu and finish that one-time prompt, then re-run `install.ps1` |
| Ready | Fully automated — see below |

Once Debian is ready, `install.ps1` (as long as `-SkipWSL` isn't passed):

1. Installs `packages/apt.txt` inside Debian, running as root via `wsl.exe -u root` (no sudo password needed — auth is controlled by `wsl.exe` itself, not Linux-side).
2. Runs `wsl/migrate-gitconfig-credential.sh`, which preserves any existing `[credential]` block in WSL's `~/.gitconfig` (e.g. a Git Credential Manager helper bridging to Windows) by moving it into `~/.gitconfig.local` — the same override mechanism described below — **before** `install.sh` overwrites `~/.gitconfig` with its rendered version. This only matters if WSL already had its own git setup predating this repo; a fresh Debian install has nothing to migrate.
3. Runs `install.sh` inside WSL against this **same** Windows-side checkout (translated to its `/mnt/c/...` path) — no second clone. The 9P translation overhead between WSL2 and the Windows filesystem matters for heavy project I/O and Docker bind mounts, not for a handful of small config text files being symlinked.

`windows-terminal/configure.ps1` then adds a Windows Terminal profile with a
fixed, repo-owned GUID (`wsl.exe -d Debian --cd ~`) and sets it as
`defaultProfile` — deliberately not reusing Windows Terminal's own
auto-generated WSL-distro profile, since that GUID is derived per-machine and
isn't portable across machines. Everything else in your `settings.json`
(color scheme, opacity, keybindings) is left untouched.

## Secrets

Git and `gh` already persist their own auth via your OS credential store /
keyring — nothing to configure. Claude Code's token is the one gap
(`claude setup-token` prints a token but doesn't persist it anywhere), so
it's stored the same way via a synthetic git-credential host. Run once per
machine:

```bash
./secrets/setup-claude-token.sh     # macOS / Linux / WSL / devcontainer
```
```powershell
.\secrets\setup-claude-token.ps1    # native Windows
```

See [secrets/README.md](secrets/README.md) for the full mechanism, the WSL
credential bridge `install.ps1` sets up automatically, and the
`devcontainer.json` snippet for pulling tokens into project containers.

## Machine-specific config

Never committed, never leaked — put machine-specific overrides in local files that the shell configs source automatically:

| File | For |
|------|-----|
| `~/.gitconfig.local` | Your `user.name` and `user.email` — also where a WSL-side git credential helper gets migrated to, if one already existed |
| `~/.bashrc.local` | Bash overrides for this machine |
| `~/.zshrc.local` | Zsh overrides for this machine |
| `~/.aliases.local` | Extra aliases |
| `~/.ssh/config` | SSH hosts (copied from `ssh/config.example`, not symlinked) |

The installer creates `~/.gitconfig.local` on first run with placeholder values.

`~/.gitconfig` is the one exception to "everything tracked gets symlinked
straight from the repo": the installer **renders** it by concatenating
`git/.gitconfig.template` with `~/.gitconfig.local`, instead of symlinking
`git/.gitconfig.template` and pointing at `.gitconfig.local` via
`include.path`. Reason: VS Code's Dev Containers "copy git config" feature
copies the raw `~/.gitconfig` into every container but doesn't follow
`include.path` ([microsoft/vscode-remote-release#9469](https://github.com/microsoft/vscode-remote-release/issues/9469)),
so a split file would need a manual bind-mount re-added to every single
devcontainer project just to get your identity across — a rendered,
self-contained file works everywhere with zero extra config. The tradeoff:
`~/.gitconfig` is a generated file, not a live symlink, so edits to
`git/.gitconfig.template` need an installer re-run to take effect — which
happens automatically; see [Keeping things in sync](#keeping-things-in-sync).

## Keeping things in sync

Editing `git/.gitconfig.template` (or anything else in this repo) doesn't
take effect anywhere until the installer re-runs. Re-running by hand after
every edit gets old fast, so two things trigger it automatically:

1. **Git hooks** (`post-checkout`, `post-merge`, `post-rewrite`) — the
   installer points this checkout at the repo-tracked `hooks/` dir via
   `git config core.hooksPath hooks`, so `git pull`/`git rebase`/switching
   branches all re-run the installer right after they change tracked files.
   All three hooks are wired up (not just `post-merge`) because this repo's
   own `pull.rebase = true` means a plain `git pull` here rewrites commits
   (`post-rewrite`) rather than merging (`post-merge`).
2. **Logon sync** — a small VBScript launcher the installer drops into the
   Startup folder (`shell:startup`) runs `install.ps1 -SkipWSL` hidden, once
   per logon, as a safety net for drift that didn't come through a git pull
   (e.g. something else overwrote a symlink). This intentionally isn't a
   Scheduled Task: `Register-ScheduledTask`/`schtasks /Create` were denied
   outright on this machine (endpoint-security policy blocking Task
   Scheduler persistence, a common hardening measure) even from an elevated
   prompt, while a file in Startup needs no special privilege.

Both paths pass `-SkipWSL` to keep automatic runs fast and non-interactive —
run `install.ps1` by hand (no flag) whenever you want the full WSL/Windows
Terminal provisioning to run too.

## Structure

```
dotfiles/
├── install.sh          ← Unix entry point (bash/zsh/devcontainer)
├── install.ps1         ← Windows entry point (PowerShell)
├── .gitattributes      ← forces LF line endings, even on a fresh Windows clone
├── git/
│   ├── .gitconfig.template  ← rendered (not symlinked) into ~/.gitconfig, see below
│   ├── .gitignore_global
│   └── ensure-gcm.sh    ← installs a credential.helper on Linux/devcontainer if none exists, see secrets/README.md
├── hooks/                       ← core.hooksPath target, wired up by the installer
│   ├── _dispatch.sh              ← shared logic: re-runs install.ps1/install.sh
│   ├── post-checkout
│   ├── post-merge
│   └── post-rewrite
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
├── secrets/
│   ├── README.md
│   ├── setup-claude-token.sh    ← one-time: stores Claude's token via GCM
│   └── setup-claude-token.ps1   ← same, native Windows
├── packages/
│   ├── Brewfile
│   ├── apt.txt
│   ├── winget.txt
│   ├── winget.lock.json         ← pinned installed versions
│   ├── winget-lock.ps1          ← regenerate the lock file
│   ├── winget-check-updates.ps1 ← weekly scheduled update check
│   └── winget-apply.ps1         ← sync machine to the lock file
├── wsl/
│   ├── bootstrap.ps1                      ← orchestrator: state detection, apt, migration, install.sh
│   ├── detect-state.ps1                   ← WSL/Debian readiness-state detection
│   ├── migrate-gitconfig-credential.sh    ← preserves an existing git credential helper
│   └── bridge-gcm.sh                      ← points WSL git at Windows' GCM, see secrets/README.md
├── windows-terminal/
│   └── configure.ps1   ← points Windows Terminal's default profile at Debian WSL
└── macos/
    └── defaults.sh
```

## Security

- No secrets, keys, tokens, or credentials are committed
- `~/.gitconfig.local`, `~/.ssh/config`, and `*.local` files are in `.gitignore`
- SSH config is copied (not symlinked) so you can add host entries without affecting the repo
- `.gitignore_global` blocks common secret file patterns globally
- Tool tokens (Claude Code, `gh`) are never written into this repo or any
  dotfile — they live in your OS credential store / keyring, seeded by
  `secrets/setup-claude-token.*` and `gh auth login`; see
  [secrets/README.md](secrets/README.md)
