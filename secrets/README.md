# Secrets

How tool tokens get onto every machine (and into devcontainers) without ever
being committed to this repo or duplicated across per-project config.

## The mechanism

Three tools, three different answers - deliberately not one scheme for
everything:

| Tool | Where its token lives | How shell init gets it |
|------|------------------------|-------------------------|
| `git` | Already handled - your OS credential store (Windows Credential Manager via Git Credential Manager, macOS Keychain, Linux libsecret), wired up by `git-credential-manager` itself. Nothing this repo needs to do. | N/A |
| `gh` | Already handled - `gh auth login`'s own persisted session (OS keyring). | `gh auth token` in `shell/exports.sh` / `powershell/profile.ps1` |
| `claude` (Claude Code) | The one real gap: `claude setup-token` prints a long-lived token but doesn't persist it anywhere. | Stored via `git-credential-manager` under a synthetic host (`dotfiles-secrets.local`), retrieved the same way `git credential fill` retrieves a real one |

The synthetic-host trick: `git credential approve`/`fill` is a generic
protocol/host/username/password store - it doesn't require the host to be a
real git remote. Since GCM is already the credential backend for real git
hosts on every platform here, reusing it avoids standing up a second secret
store just for one token. `git/.gitconfig.template` sets
`credential.https://dotfiles-secrets.local.provider = generic` so GCM skips
trying to auto-detect a provider for a host that will never resolve.

This mechanism only works where a `credential.helper` is actually active, so
that's a structural dependency now, not an assumption:

| Platform | Where GCM comes from |
|----------|------------------------|
| Windows (native) | Free - Git for Windows bundles it and registers it in the *system* gitconfig (`packages/winget.txt` already installs `Git.Git`) |
| macOS | `packages/Brewfile`'s `cask "git-credential-manager"` - idiomatic, `brew upgrade --cask` handles updates |
| WSL | Bridged to the Windows install - see [WSL](#wsl) below |
| Native Linux / devcontainer | `git/ensure-gcm.sh`, run automatically by `install.sh` - see below |

### `git/ensure-gcm.sh` (Linux / devcontainer)

There's no apt/dpkg repo for GCM, so `install.sh` runs this before rendering
`~/.gitconfig`:

1. **Checks first, always.** If a `credential.helper` is already effective
   (system, global, or local config), it no-ops - never overwrites an
   existing setup, whether that's a user's own manual install or `gh`'s
   independent auth.
2. If `git-credential-manager` is already on `PATH` (e.g. a devcontainer base
   image ships it), it just wires up `~/.gitconfig.local` and stops.
3. Otherwise, downloads a **pinned, checksum-verified** release into
   `~/.local/share/dotfiles/git-credential-manager` and symlinks just the
   binary into `~/.local/bin` (already on `PATH` via `shell/exports.sh`) - no
   sudo, works the same in native Linux, WSL (as a fallback), and
   devcontainers. The release tarball is flat (binary + two `.so` deps + a
   license file), which is why the binary is symlinked out of its own
   directory rather than extracting straight into `~/.local/bin`.

Deliberately **not** auto-updating on every run: the version and its SHA256
are hardcoded constants at the top of the script, bumped by hand when wanted
- same reviewable-version philosophy as `packages/winget-lock.ps1`, just
scoped to one tool instead of a whole lockfile.

It also deliberately does **not** run `git-credential-manager configure` -
that command writes `credential.helper` into `~/.gitconfig` directly via
`git config --global`, which `install.sh`'s render step would silently
overwrite again on the very next run. It writes to `~/.gitconfig.local`
instead, the same file `wsl/bridge-gcm.sh` uses.

## One-time setup

Run once per machine:

```bash
./secrets/setup-claude-token.sh     # macOS / Linux / WSL / devcontainer
```
```powershell
.\secrets\setup-claude-token.ps1    # native Windows
```

Each runs `claude setup-token` against your real terminal (not piped - its
output format isn't documented as "token only", so this avoids silently
capturing the wrong thing), has you paste the token back, shows you what's
about to be stored, and asks for confirmation before calling
`git credential approve`. It also drops a sentinel file (`claude-token.configured`
under `$XDG_CACHE_HOME/dotfiles` or `%LOCALAPPDATA%\dotfiles`) - shell init
checks that file *before* attempting a credential lookup, because a lookup
against an unconfigured host isn't a fast local no-op: GCM tries (and fails)
to network-probe it first, adding several real seconds to shell startup. The
sentinel means that cost is never paid until you've actually run this script.

`gh` needs no setup script - if `gh auth login` has been run on that machine,
`gh auth token` in shell init just works.

## WSL

A fresh WSL Debian install has **no** credential helper configured at all
(confirmed live: `git config --get-all credential.helper` returns nothing)
— so the synthetic-host lookup would silently return empty there without
extra plumbing. `wsl/bootstrap.ps1` handles this automatically: it locates
Windows' `git-credential-manager.exe` and points WSL's
`credential.helper` at it (via `wsl/bridge-gcm.sh`, content-gated so it never
overwrites a pre-existing `[credential]` block), so WSL reads and writes the
*same* Windows Credential Manager store as native PowerShell. Verified live:
storing a secret from WSL and reading it back from native Windows (and vice
versa) returns the same value. This only runs during the full
`install.ps1` (no `-SkipWSL`) / `wsl/bootstrap.ps1` flow, not the fast logon-sync path.

If the bridge can't find the Windows binary (or didn't run), `install.sh`'s
own `git/ensure-gcm.sh` step runs next inside WSL anyway and installs a
native Linux copy as a fallback - the two compose safely because
`ensure-gcm.sh` checks for an already-active `credential.helper` first and
no-ops if the bridge already set one up.

## Devcontainers

`install.sh` runs the same way inside a devcontainer as anywhere else, so
`shell/exports.sh`'s lookup runs there too - but it needs both a working
credential forward *and* the sentinel file for that lookup to actually fire.

**VS Code's Dev Containers git-credential forwarding is the reliable path.**
VS Code proxies `git credential fill`/`approve` from inside the container
back to the host's real credential helper - confirmed live working not just
for real hosts (`github.com`) but for the synthetic host
(`dotfiles-secrets.local`) too, so this works without any per-project
`devcontainer.json` changes. `install.sh`'s devcontainer-extras step tests
this once (with a timeout, so a container where forwarding *isn't* set up
fails fast instead of turning into a slow probe on every future shell) and
writes the sentinel file itself if it succeeds - no manual step needed
beyond having already run `secrets/setup-claude-token.sh` on the host.

**The VS Code Claude Code *extension* (not just the CLI) can come up looking
unauthenticated on first container start, even once `CLAUDE_CODE_OAUTH_TOKEN`
is correctly set and the CLI works fine in the integrated terminal.** The
extension and CLI read the same auth env vars (`ANTHROPIC_API_KEY`,
`CLAUDE_CODE_OAUTH_TOKEN`, `apiKeyHelper`) with identical precedence - this
isn't an OAuth-vs-API-key gap. The cause is timing: the extension host reads
VS Code's cached "resolved shell environment" snapshot, which can be taken
before `install.sh` finishes wiring up credential forwarding and the sentinel
file. **Fix: run `Developer: Reload Window` once after `install.sh`
completes** - confirmed live this resolves it without any config changes.

**`remoteEnv`/`${localEnv:...}` in the project's `devcontainer.json` does
NOT work reliably and shouldn't be relied on**, at least for a project opened
from a WSL folder: confirmed live that even though the tokens were correctly
exported in the WSL shell used to launch VS Code (and visible in that same
window's own integrated terminal), they came through empty inside the
container. Root cause: `${localEnv:...}` is resolved by a separate, more bare
invocation the Dev Containers extension uses to build the container, which -
unlike the integrated terminal - does not appear to go through shell startup
files (`.bashrc`/`.profile`) at all, so it never runs the
`git credential fill` lookup that produces the token in the first place. This
isn't fixable from this repo's side. Use credential forwarding instead.

## Security

- No tokens are ever written into this repo - `git credential approve` hands
  the secret straight to the OS-native store (Windows Credential Manager /
  Keychain / libsecret), never a file here.
- The only repo-tracked artifact is the *name* of the synthetic host
  (`dotfiles-secrets.local`) and the `provider = generic` config line - both
  meaningless without an actual stored secret behind them.
- Sentinel files (`claude-token.configured`) contain no secret material -
  they're just a marker so shell init knows a lookup is worth attempting.
