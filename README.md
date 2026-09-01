# dotfiles

Personal dev machine config for macOS, Linux, and Windows — built to work seamlessly inside **devcontainers**.

## What's included

| Path | What it configures |
|------|-------------------|
| `git/` | `.gitconfig` with aliases, delta diff, sane push/pull defaults |
| `shell/` | `.zshrc`, `.bashrc`, shared `aliases.sh` and `exports.sh` (exports `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`, and any forwarded Kilo provider keys) |
| `powershell/` | PowerShell 7+ profile (PSReadLine, posh-git, `claude` → WSL forwarding, `kilo` → WSL forwarding, `copilot` → WSL forwarding) + a Windows PowerShell 5.1 shim that hands off to pwsh |
| `cmd/` | `init.cmd` — doskey macros + prompt for cmd.exe, loaded via AutoRun |
| `vscode/` | `settings.json`, `keybindings.json`, `extensions.txt` |
| `claude/` | Claude Code **global** config (`CLAUDE.md`, `settings.json`), plus `agents/` (the subagent roster, led by the `number-one` orchestrator), `skills/` (on-demand procedural knowledge, including the global-vs-project config-scoping convention) and `hooks/` (`PreToolUse` guardrails blocking PR-merge/force-push and AI-attribution lines) |
| `kilo/` | Kilo Code global config (`kilo.jsonc`, `tui.jsonc`), plus `.kilo/agents/` (the `number-one` orchestrator subagent in Kilo's frontmatter format). `AGENTS.md` is symlinked from `claude/CLAUDE.md` — one source of truth for global rules shared by both tools. GitHub Copilot CLI gets no directory of its own — `install.py` symlinks its `~/.copilot/copilot-instructions.md` straight from `claude/CLAUDE.md` too, same pattern, same source of truth. |
| `starship/` | Cross-shell prompt config |
| `tmux/` | `.tmux.conf` with vim-style nav and Catppuccin colours |
| `ssh/` | `config.template` (rendered to `~/.ssh/config`, no keys) |
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

# Windows — install.ps1 already does this (pinning to winget.lock.json where
# an entry exists); the one-liner below is only for running it standalone.
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

VS Code will automatically clone this repo and run `install.sh` inside every devcontainer you open, giving you your shell config, git aliases, starship prompt, the Claude Code CLI, the Kilo Code CLI, the GitHub Copilot CLI, the GitHub CLI (`gh`), and `delta` everywhere.

**Enable it once in VS Code settings:**

```json
"dotfiles.repository": "https://github.com/jmuise/dotfiles",
"dotfiles.targetPath": "~/dotfiles",
"dotfiles.installCommand": "~/dotfiles/install.sh"
```

These are already set in `vscode/settings.json`. The install script detects the container context (`/.dockerenv`, `$REMOTE_CONTAINERS`, `$CODESPACES`) and skips host-only steps like VS Code settings and macOS defaults. It will attempt to install starship, the Claude Code CLI, the Kilo Code CLI, the GitHub Copilot CLI, `gh`, and `delta` (via `apt-get`) for whichever of those are missing from the base image.

Git identity comes along for free too: VS Code's Dev Containers "copy git config" feature copies your host `~/.gitconfig` into every container automatically, and since it's a single rendered file (see [Machine-specific config](#machine-specific-config)) rather than one that `include`s another, there's nothing project-specific to configure — no per-project bind mount needed. (Copy-git-config does *not* follow `include.path` — [microsoft/vscode-remote-release#9469](https://github.com/microsoft/vscode-remote-release/issues/9469) — which is what a split file would require.)

`install.sh` also runs `git/ensure-gcm.sh` inside the container if no
`credential.helper` is already active — a backstop alongside VS Code's own
git-credential forwarding, since the latter is only confirmed to work for
real git hosts, not the synthetic host `secrets/` uses for the Claude Code
token (see [secrets/README.md](secrets/README.md)).

**`sp [path]`** is the terminal equivalent of clicking "Reopen in Container" in VS Code: it builds/starts the project's devcontainer via the `devcontainer` CLI and drops you into a shell inside it. Pass `-c`/`--code` to attach VS Code to the container instead of opening a shell. Backed by `tools/start-project.sh`; the `devcontainer` CLI itself is installed by `install.py` (pinned as `DEVCONTAINERS_CLI_VERSION`, same npm-global pattern as Kilo/Copilot).

## Claude Code

`claude/agents/number-one.md` is a global orchestrator subagent ("Number One") — decompose an order into tracked tasks, delegate implementation to worker subagents, keep their PRs pushed and current, and hand off to you for review. It never merges: `claude/hooks/block-pr-merge.sh` (wired up via `claude/settings.json`'s `PreToolUse` hook, plus a `permissions.deny` rule) hard-blocks `gh pr merge` and unsafe `git push --force` for every agent, including any subagent it spawns. `claude/hooks/block-ai-attribution.sh` is wired the same way and blocks AI-attribution lines from reaching git history or any repo artifact.

Alongside Number One the roster carries `chief-engineer` (fresh-project provisioning and dev-environment sign-off), `security-officer` (independent read-only review), `implementation-engineer` (scoped implementation through to a CI-green PR), and `duty-officer` (cheap read-only status checks). `claude/skills/` holds procedural knowledge that loads on demand instead of being retyped into every brief — verification discipline, PR/branch hygiene, the dotfiles commit protocol, the security-review checklist, and the config-scoping convention below.

Number One can also grow the roster itself: when it identifies a recurring role (e.g. a "graphic-designer" or "devops-engineer" specialist), it's free to author a new subagent definition under `~/.claude/agents/`, or a new skill under `~/.claude/skills/`. Since those directories are symlinked straight into this repo's `claude/`, new files it creates show up here under version control automatically — expect them to appear as untracked files from time to time, and review them like any other change before committing. It won't commit or push on your behalf.

### Global config vs. a project's own `.claude/`

Everything under `claude/` here is the **global** tier: it describes *you*, and it applies in every repo on every machine. Claude Code also reads a **project** tier — a `.claude/` directory committed inside an individual project's repo — which describes *that codebase*, and applies to anyone who clones it whether or not they have these dotfiles.

The split, in one line each: global is how you like to work; project is what is true about this code. The full convention (which rung to reach for, why project config stays thin and additive rather than a copy of the global tier, and how a newly provisioned project gets seeded) lives in `claude/skills/claude-config-scoping/SKILL.md`, so agents load it on demand rather than re-deriving it per project. `chief-engineer` applies it when provisioning: a fresh project gets a thin project `CLAUDE.md` documenting its stack and entry points, and deliberately nothing else — no empty `agents/`/`skills/`/`hooks/` directories to tempt anyone into copying global content down into them.

Two behaviours of the project tier are worth knowing before you trust a repo you didn't write, both confirmed by experiment rather than documentation:

- **A project agent whose `name` matches a global one replaces it silently** — the global definition disappears from the list entirely, with no warning. A repo shipping its own `security-officer` would review itself. Project-scoped names should be repo-prefixed so this can't happen by accident.
- **Project agents, skills and `CLAUDE.md` are active in an untrusted directory, with no prompt.** Workspace trust gates a project's `permissions.allow` entries (they're discarded with a warning until you accept), but it does not gate instruction-shaped config. So reading an unfamiliar repo's `.claude/` belongs in the same pass as reading its build scripts.

In every case tested the global guardrail hooks still fired and still blocked, including from inside a project that defined competing hooks of its own — but that's a property to re-confirm when the stack changes, not one to assume.

### `claude` on native Windows → WSL

The Claude Code install that's actually kept current lives **inside WSL**. So
that muscle memory still works from the Windows side, `powershell/profile.ps1`
defines a `claude` **function** that starts a session inside Debian, in the
translated working directory (`C:\Users\jerem\code\foo` →
`/mnt/c/Users/jerem/code/foo`), with the exit code handed back to the caller.

**What's covered — and what isn't.** The function is the only forwarding
mechanism, so it applies exactly where the profile is loaded:

| Context | What `claude` does |
|---------|-------------------|
| Interactive PowerShell 7 with the profile loaded (Windows Terminal, the VS Code integrated terminal) | Forwards into WSL. Functions always outrank a PATH lookup, so this wins |
| Raw `cmd.exe`, `pwsh -NoProfile`, VS Code tasks, npm scripts — anything that spawns `claude` as a child process | **Not intercepted.** Falls through to the still-installed native `%USERPROFILE%\.local\bin\claude.exe`, i.e. native Windows Claude Code, not WSL |

That leftover `claude.exe` is deliberately being left in place for now. If it's
ever deleted, `claude` in those un-intercepted contexts simply won't be found —
nothing else will pick it up.

**Why there's no `.cmd` shim.** An earlier version of this repo also shipped a
`windows/claude.cmd`, installed onto the user PATH by `install.ps1`, to cover
cmd.exe and profile-less PowerShell. It was **removed, not patched**, because
it was command-injectable: cmd.exe re-scans a batch file's command line after
`%*` is substituted, and it has no argument escape (`\"` is not honoured — every
literal `"` just flips quote state), so a `&`, `|` or `>` inside an argument
could break out and run arbitrary Windows commands. The same re-scan silently
expanded `%VAR%` in arguments, which would have exposed
`CLAUDE_CODE_OAUTH_TOKEN`. There is no way to make a batch-file wrapper safe
here — **do not reintroduce one.** `install.ps1` deletes the previously
installed copy and drops its PATH entry on the next run. The PowerShell function
is not affected: it calls `wsl.exe` (a real `.exe`) directly and builds a real
argv, with no cmd.exe anywhere in the chain.

Other deliberate choices worth knowing about:

- **Arguments are passed as argv, never interpolated.** The function runs
  `wsl.exe -d Debian -e bash -lc <fixed script> claude <args…>`, so the script
  text is a constant and every user argument arrives as `$1`, `$2`, … — nothing
  a user types can be re-parsed as shell syntax. Verified for spaces, quotes,
  `&`, `|`, `%`, `!`, backslash paths and empty strings.
- **`wsl.exe` by absolute path.** `$env:SystemRoot\System32\wsl.exe`, not a PATH
  lookup, so the forwarding can't itself be hijacked by a `wsl.exe` earlier on
  PATH. If that file is missing, the function isn't defined at all.
- **No `--cd`.** `wsl.exe` already translates the caller's working directory
  (including `\\wsl.localhost\Debian\…` → the native distro path) and falls back
  to the Linux home directory when a path has no WSL mapping, e.g. a network
  drive. An explicit `--cd` would turn that graceful fallback into a hard
  `Wsl/ERROR_PATH_NOT_FOUND`.
- **A login shell plus an explicit PATH prepend.** `bash -lc` picks up
  `/etc/profile.d`, but isn't enough on its own: `~/.bashrc` returns early when
  non-interactive and `~/.profile` is skipped whenever `~/.bash_profile` exists,
  so `~/.local/bin` and `~/bin` are prepended explicitly (with an `nvm` fallback
  if Claude was installed through npm).

Set `CLAUDE_WSL_DISTRO` to target a distro other than `Debian`. The function
only speaks up in genuinely broken situations — WSL absent, distro missing, or
Claude Code not installed inside the distro — and refuses to run a `/mnt/…`
Windows `claude` from inside WSL so it can't recurse into itself.

### `kilo` on native Windows → WSL

Same forwarding pattern as `claude` above — the Kilo Code install lives inside
the WSL distro, and `powershell/profile.ps1` defines a `kilo` function that
starts a Kilo session inside Debian with the same argument-forwarding
guarantees (no cmd.exe, absolute `wsl.exe` path, no `--cd`). Run
`npm install -g @kilocode/cli@7.4.22` inside the distro to install it there
(pinned deliberately — see `KILO_CLI_VERSION` in `install.py`). Set
`KILO_WSL_DISTRO` to target a different distro.

Authentication (`kilo auth login`) is done interactively inside the WSL distro —
each provider's API key is stored in `~/.local/share/kilo/auth.json`, which the
dotfiles never touch (no credential forwarding needed, unlike Claude Code's
OAuth token).

### `copilot` on native Windows → WSL

Same forwarding pattern as `claude`/`kilo` above — the GitHub Copilot CLI
install lives inside the WSL distro, and `powershell/profile.ps1` defines a
`copilot` function with the same argument-forwarding guarantees. Run
`npm install -g @github/copilot@1.0.80` inside the distro to install it there
(pinned deliberately — see `COPILOT_CLI_VERSION` in `install.py`). Set
`COPILOT_WSL_DISTRO` to target a different distro.

No separate login step or credential forwarding needed: Copilot CLI checks
`GH_TOKEN` automatically, which `shell/exports.sh` already exports from `gh`'s
own persisted session.

## Derived checkouts (pull-only mirrors)

**Every checkout fast-forwards itself before it relinks anything.**
`install.ps1` and `install.sh` both run `git pull --ff-only origin` against the
checkout they were launched from. A machine you only ever *run* the installer
on therefore converges on whatever was last pushed, without anyone having to
remember to pull first — which matters most for checkouts nobody edits.

**`--ff-only` is the entire enforcement mechanism.** If a checkout has commits
`origin` doesn't, the pull fails, the installer prints a loud warning and
continues with the relinking. Nothing is reset, merged, rebased, stashed or
discarded, ever. A non-fast-forward means someone edited a checkout that was
supposed to be derived, and that's a human's problem to resolve — not something
a provisioning script should decide at logon time. There is deliberately
nothing stronger: no commit-blocking hook, no read-only file attributes. Refuse
and warn is enough. (An unreachable remote fails the same way; the checkout is
then simply stale, which is harmless.)

**Why a WSL-driven Windows box still needs a real checkout on local disk.**
When all the editing happens inside WSL it's tempting to keep exactly one
checkout there and point Windows at it over `\\wsl.localhost\…`. That doesn't
work. Windows refuses to execute an unsigned script from a UNC path, so a
UNC-hosted profile fails with `PSSecurityException` on every new shell. And
the Windows-native integrations `install.ps1` sets up all bake in an
**absolute path** to whatever checkout the installer ran from:

| Integration | Points at |
|-------------|-----------|
| PowerShell 7 profile symlink (`$PROFILE`) | `powershell/profile.ps1` |
| Windows PowerShell 5.1 profile symlink (`Documents\WindowsPowerShell\…`) | `powershell/profile.legacy.ps1` |
| `DOTFILES_DIR` user environment variable | the checkout root — read by `cmd\init.cmd` |
| cmd.exe AutoRun key (`HKCU\Software\Microsoft\Command Processor`) | `cmd\init.cmd` |
| Startup-folder VBS launcher (`dotfiles-install-at-logon.vbs`) | `install.ps1` |

So the Windows side keeps its own checkout on local disk, and that checkout is
exactly the derived mirror described above: edits happen in the primary
checkout and are pushed from there, and the installer fast-forwards the mirror
before relinking.

**Learned the hard way.** A consolidation pass once renamed that checkout aside
without checking what pointed into it, and all five integrations broke at once
and silently — no error anyone saw, just a profile that stopped loading and a
logon sync that failed every login. Moving or renaming a checkout that Windows
integrations point at breaks all of them, quietly; treat its location as
load-bearing and re-run `install.ps1` if it ever has to change.

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

### `.wslconfig` and Docker Desktop WSL integration flakiness

`install.ps1` also renders `~/.wslconfig` (template + `~/.wslconfig.local`
merged, same pattern as `~/.gitconfig`/`~/.ssh/config` — see
[Machine-specific config](#machine-specific-config)) with
`autoMemoryReclaim=dropcache` instead of WSL2's default `gradual`, and
`packages/apt.txt` installs `docker-buildx` explicitly. Together these fix a
recurring failure mode: Docker Desktop's own VM restarting (sleep/resume,
or memory pressure that `gradual` reclaim has been observed to worsen)
leaves every already-running WSL distro's `/mnt/wsl/docker-desktop/cli-tools`
mount pointing at a now-destroyed VM session, so the `docker-compose`/
`docker-buildx` symlinks under `/usr/local/lib/docker/cli-plugins` that
Docker Desktop's WSL integration publishes start failing with I/O errors —
breaking `docker compose`/`docker buildx`, and with them VS Code's Dev
Containers extension, until `wsl --shutdown` forces a remount. Debian's own
`docker-compose`/`docker-buildx` apt packages install real plugin binaries
that don't depend on that mount at all, so they keep working across Docker
Desktop VM restarts without a `wsl --shutdown`.

`~/.wslconfig` changes still require `wsl --shutdown` to take effect —
`install.ps1` warns when it changes the file but never runs `wsl --shutdown`
itself, since that stops every running WSL distro/container.

## Secrets

Git and `gh` already persist their own auth via your OS credential store /
keyring — nothing to configure. Claude Code's token is the one gap
(`claude setup-token` prints a token but doesn't persist it anywhere), so
it's stored the same way via a synthetic git-credential host. Kilo Code
authenticates via `kilo auth login` (per-provider API keys stored in
`~/.local/share/kilo/auth.json`), which doesn't need a setup script — just
run it once inside the distro or devcontainer where you want it active. The
GitHub Copilot CLI needs nothing at all — it picks up the `GH_TOKEN` that
`shell/exports.sh` already exports from `gh`'s own session. Run once per
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
| `~/.ssh/config.local` | Your own SSH hosts/overrides (see `ssh/config.local.example`) |
| `~/.wslconfig.local` | Your WSL2 memory/processors tuning (see `wsl/.wslconfig.local.example`) |

The installer creates `~/.gitconfig.local`, `~/.ssh/config.local`, and
`~/.wslconfig.local` on first run — the last one carries forward any tuning
from a pre-existing `~/.wslconfig` instead of using the placeholder example.

`~/.ssh/config`, like `~/.gitconfig`, is rendered (not copied once) — every
install.sh run merges `ssh/config.template` with `~/.ssh/config.local` into a
fresh `~/.ssh/config`. That means a bugfix to the tracked template reaches
machines that already bootstrapped automatically, via the post-merge hook
below, instead of being frozen in at first install with no way for a later
`git pull` to fix it. Your own hosts and per-host overrides live in
`~/.ssh/config.local`, which install.sh creates once and never touches again.

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
take effect anywhere until the installer re-runs — on the machine whose
checkout you edited *and* on every other machine, once the change reaches it.
Re-running by hand after every edit gets old fast, so two things trigger the
installer automatically, and the installer pulls for itself once it starts:

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

Both of those pass `-SkipWSL` to keep automatic runs fast and non-interactive —
run `install.ps1` by hand (no flag) whenever you want the full WSL/Windows
Terminal provisioning to run too.

**The installer also updates its own checkout first.** Before relinking,
`install.ps1`/`install.sh` fast-forward the checkout they were launched from
(`git pull --ff-only origin`, never destructive — see
[Derived checkouts](#derived-checkouts-pull-only-mirrors)). So a logon-triggered
run picks up changes pushed from somewhere else, rather than only re-applying
whatever was already on disk. That's what closes the loop for a checkout nobody
ever edits or pulls by hand.

**That self-pull and the hooks would otherwise chase each other.** A pull that
actually lands commits fires `post-merge`/`post-rewrite`, which runs
`hooks/_dispatch.sh`, which runs the installer — from inside the installer, so
every run that pulled anything would do the whole install twice. Both installers
therefore export `DOTFILES_INSTALL_ACTIVE=1` for the duration of that one `git
pull`; `_dispatch.sh` finds it in the environment it inherits and exits
immediately, leaving the outer run to do the relinking once. The variable is
scoped to that single git invocation and restored straight after, so a `git
pull` you type by hand still triggers a normal sync.

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
├── claude/
│   ├── CLAUDE.md
│   ├── settings.json
│   ├── statusline-command.sh
│   ├── agents/                ← global subagent roster, see below
│   │   ├── number-one.md          ← orchestrator
│   │   ├── chief-engineer.md      ← fresh-project provisioning + dev-env sign-off
│   │   ├── security-officer.md    ← independent read-only review
│   │   ├── implementation-engineer.md
│   │   └── duty-officer.md        ← cheap read-only status checks
│   ├── skills/                ← procedural knowledge, loaded on demand
│   │   ├── claude-config-scoping/     ← global tier vs. a project's own .claude/
│   │   ├── verification-discipline/
│   │   ├── pr-branch-hygiene/
│   │   ├── dotfiles-commit-protocol/
│   │   └── security-review-checklist/
│   └── hooks/
│       ├── block-pr-merge.sh       ← PreToolUse guardrail: blocks gh pr merge / unsafe force-push
│       └── block-ai-attribution.sh ← PreToolUse guardrail: blocks AI-attribution lines
├── kilo/
│   ├── kilo.jsonc              ← symlinked → ~/.config/kilo/kilo.jsonc (permissions, providers)
│   ├── tui.jsonc               ← symlinked → ~/.config/kilo/tui.jsonc (theme, notifications)
│   └── .kilo/
│       └── agents/
│           └── number-one.md   ← orchestrator subagent (Kilo frontmatter format)
├── starship/
│   └── starship.toml
├── tmux/
│   └── .tmux.conf
├── ssh/
│   ├── config.template        ← rendered into ~/.ssh/config, never symlinked
│   └── config.local.example   ← stub copied to ~/.ssh/config.local on first run
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
│   ├── bridge-gcm.sh                      ← points WSL git at Windows' GCM, see secrets/README.md
│   ├── .wslconfig.template                ← rendered into ~/.wslconfig, never symlinked
│   └── .wslconfig.local.example           ← stub copied to ~/.wslconfig.local on first run
├── windows-terminal/
│   └── configure.ps1   ← points Windows Terminal's default profile at Debian WSL
└── macos/
    └── defaults.sh
```

## Security

- No secrets, keys, tokens, or credentials are committed
- `~/.gitconfig.local`, `~/.ssh/config`, `~/.ssh/config.local`, and `*.local` files are in `.gitignore`
- SSH config is rendered (not symlinked) so you can add host entries in `~/.ssh/config.local` without affecting the repo
- `.gitignore_global` blocks common secret file patterns globally
- Tool tokens (Claude Code, `gh`) are never written into this repo or any
  dotfile — they live in your OS credential store / keyring, seeded by
  `secrets/setup-claude-token.*` and `gh auth login`; see
  [secrets/README.md](secrets/README.md)
