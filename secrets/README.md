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
`shell/exports.sh`'s lookup runs there too - but two things determine whether
it actually finds anything:

1. **VS Code's Dev Containers git-credential forwarding.** VS Code proxies
   `git credential fill`/`approve` from inside the container back to the
   host's real credential helper - confirmed working for real hosts
   (`github.com`). **Not yet confirmed for a synthetic host** like
   `dotfiles-secrets.local` - the forwarding may or may not be host-agnostic.
   Needs a live test inside an actual devcontainer.
2. **`remoteEnv` in the *project's* `devcontainer.json`.** This repo can't
   modify other projects' `devcontainer.json` files, so if (1) above doesn't
   pan out, the reliable fallback is pulling the token from the *host*
   environment at container-creation time:

   ```json
   "remoteEnv": {
     "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}",
     "GH_TOKEN": "${localEnv:GH_TOKEN}"
   }
   ```

   Add this to a project's `devcontainer.json` and, as long as the host shell
   that launched VS Code already had these exported (which it will, once
   `secrets/setup-claude-token.*` has been run there), they land in the
   container automatically. `shell/exports.sh`'s `-z` guard means it only
   attempts the in-container lookup if these *aren't* already set this way -
   the two mechanisms don't conflict.

   Since it's genuinely unclear whether VS Code launches read `${localEnv:...}`
   from a WSL shell's environment or the Windows one (depends how the project
   was opened), `shell/exports.sh` and `powershell/profile.ps1` both export
   these - whichever one VS Code reads from, it'll be there.

## Security

- No tokens are ever written into this repo - `git credential approve` hands
  the secret straight to the OS-native store (Windows Credential Manager /
  Keychain / libsecret), never a file here.
- The only repo-tracked artifact is the *name* of the synthetic host
  (`dotfiles-secrets.local`) and the `provider = generic` config line - both
  meaningless without an actual stored secret behind them.
- Sentinel files (`claude-token.configured`) contain no secret material -
  they're just a marker so shell init knows a lookup is worth attempting.
