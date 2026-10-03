# role: packages

Installs OS packages from the repo's existing manifests, the binary/CLI
tools that aren't apt/Brewfile-packaged (starship, neovim, lazygit, yazi,
devcontainer CLI), profile-gated AI CLIs (Claude Code, Copilot CLI, Kilo
Code CLI, rtk), and the Windows Scoop/winget package sets. Keeps **no
package list of its own** — the manifests at the repo root stay the single
source of truth.

## What it does

| OS family | Task file(s)                                    | Reads                         | Verified?                                                    |
| --------- | ------------------------------------------------ | ------------------------------ | ------------------------------------------------------------ |
| Debian    | `tasks/apt.yml`                                   | `packages/apt.txt`              | yes — real run + idempotent re-run, trixie & bookworm containers |
| Debian    | `tasks/delta.yml`                                 | (fallback; no manifest)         | yes — bookworm fallback path, trixie apt-available path       |
| Debian    | `tasks/starship.yml`, `neovim.yml`, `lazygit.yml`, `yazi.yml` | (unpinned upstream GitHub releases) | yes — real run + idempotent re-run + `--check --diff`, trixie & bookworm |
| (any, non-Windows) | `tasks/devcontainer_cli.yml`              | pinned in `defaults/main.yml`   | yes — real run + idempotent re-run + `--check --diff`          |
| Darwin    | `tasks/homebrew.yml`                              | `packages/Brewfile`             | **no** — written, never executed (no Mac reachable)            |
| Windows   | `tasks/windows.yml`                               | `packages/scoop.txt`, `packages/winget.txt` | **no** — written, never executed (no Windows host reachable, WinRM not enabled) |
| (any)     | `tasks/ai_clis.yml`                               | pinned in `defaults/main.yml`   | `claude`/`copilot`/`kilo`/`rtk` — real run + idempotent re-run + `--check --diff`, trixie & bookworm; parity-checked against `legacy/provision_legacy.py` |

Every "yes" row above was verified with: a real `-e profile=agentic` run,
a real `-e profile=bare` run (AI CLIs absent, everything else present), an
idempotent re-run of the agentic run (`changed=0`), and `--check --diff` on
a separately-fresh container (no errors, sensible dry-run preview) — each
against both a fresh `debian:trixie` and a fresh `debian:bookworm`
container. See "Findings from verifying this role against a running
system (#41)" below for what that surfaced and fixed.

## Profile gating

`tasks/ai_clis.yml` is imported only when `want_ai_clis` is true, which
`site.yml` sets from the shared profile reader (`profile/profile.py`). So:

- `profile=bare` → OS packages + binary tools only, no AI CLIs
- `profile=inline` / `profile=agentic` → the above + `claude` + `copilot` +
  `kilo` + `rtk`

This is a **deliberate behaviour change from legacy**:
`legacy/provision_legacy.py` installs Kilo/Copilot/rtk unconditionally
(gated only on "not Windows"), with no profile awareness at all. This
role's brief (#41, epic #35) requires AI CLIs to stay gated on
`profile != bare`, so Kilo and rtk join Copilot under that same gate here,
rather than reproducing legacy's ungated behaviour verbatim. Everything
else in this role (apt/brew/scoop/winget packages, starship, neovim,
lazygit, yazi, devcontainer CLI, delta) is **not** profile-gated, matching
legacy exactly.

## Key variables (`defaults/main.yml`)

| Variable                            | Default   | Purpose                                                       |
| ------------------------------------ | --------- | -------------------------------------------------------------- |
| `packages_apt_become`                | `true`    | set `false` to dry-run without passwordless sudo               |
| `packages_apt_update_cache`          | `true`    | set `false` to dry-run without root                             |
| `packages_apt_exclude`               | `[]`      | apt.txt entries this host sources elsewhere (e.g. `nodejs`/`npm` via nvm) |
| `packages_copilot_cli_version`       | pinned    | **now the source of truth** — was `COPILOT_CLI_VERSION` in legacy |
| `packages_kilo_cli_version`          | pinned    | **now the source of truth** — was `KILO_CLI_VERSION` in legacy |
| `packages_devcontainers_cli_version` | pinned    | **now the source of truth** — was `DEVCONTAINERS_CLI_VERSION` in legacy |
| `packages_rtk_version` / `packages_rtk_installer_sha` | pinned | **now the source of truth** — was `RTK_VERSION` / `RTK_INSTALLER_SHA` in legacy |
| `packages_delta_version` / `packages_delta_sha256_x86_64` / `packages_delta_sha256_arm64` | pinned | **now the source of truth** — was `DELTA_VERSION` / `DELTA_SHA256_*` in `git/ensure-delta.sh` |

`packages_apt_exclude` defaults to empty on purpose: drift between `apt.txt`
and what a machine actually has should be *visible* in `--check --diff`, not
silently masked. Only pin it per-host when a divergence is deliberate and
permanent.

Every pin above is a straight copy of the constant it replaces. Until the
legacy file/script it replaces actually retires, bump the value **here
first**, then mirror the same bump into the legacy copy so the two paths
can't silently drift while both are alive.

## Manifest parsing

- `apt.txt` / `scoop.txt` / `winget.txt`: strip `#` comments (inline +
  full-line), trim, drop blanks.
- `Brewfile`: `regex_findall` for `^tap "…"`, `^brew "…"`, `^cask "…"`;
  trailing `# comments` are ignored by the pattern.

None of these parsers re-list packages — they read the file byte-for-byte
via `slurp` at play time (delegated to `localhost` in `tasks/windows.yml`,
since the manifest lives in the controller's checkout, not necessarily on a
remote Windows target).

## #67 — git-delta on bookworm

`git-delta` is not apt-installable on Debian 12 (bookworm) — see
`tasks/apt.yml`'s probe and `tasks/delta.yml`'s fallback. The fallback
downloads and checksum-verifies the same pinned release
`git/ensure-delta.sh` already uses, laid out the same way
(`~/.local/share/dotfiles/delta`, symlinked into `~/.local/bin`). Because
the same "apt doesn't have it" gate applies regardless of container-ness,
this also picks up the #41-tagged portion of legacy's "devcontainer extras"
block that shelled out to `git/ensure-delta.sh` — no separate
`is_devcontainer` branch was needed for that.

The probe generalizes to every entry in `packages/apt.txt`, not just
`git-delta`: a real (not `--check`) run against a fresh `debian:bookworm`
container while verifying this role surfaced a second, previously unnoticed
instance of the identical problem — `docker-buildx` is *also* trixie/sid-only
and absent on bookworm. A git-delta-only special case would have left that
one aborting the whole apt install again, reproducing #67 for a different
package the next time bookworm gained a manifest entry with the same gap.
`tasks/apt.yml` now probes `apt-cache policy` for every wanted package,
warns (visibly, via `ansible.builtin.debug`) about whichever entries this
release's apt cannot supply, and drops only those from the install list.

## Findings from verifying this role against a running system (#41)

A green `ansible-lint`/`--syntax-check` and a `--check --diff` pass do not
exercise real installs. Verifying with actual real runs (not just
`--check --diff`, which was all PR #55 ever used per #67) against fresh
`debian:trixie`/`debian:bookworm` containers surfaced three more defects,
all fixed in this PR:

- **`get_url` + a pre-created empty `tempfile` silently downloads nothing.**
  `neovim.yml`/`lazygit.yml`/`yazi.yml` created the destination with
  `ansible.builtin.tempfile` before calling `ansible.builtin.get_url` into
  that same path. Because the destination already existed, `get_url`
  performed a conditional GET keyed on the fresh tempfile's mtime; GitHub
  answered `304 Not Modified`, and the module reported `ok` while leaving a
  0-byte file — `unarchive` then failed on an invalid archive. Fixed with
  `force: true` on each affected `get_url` task.
- **`~/.local/bin` is never on the PATH Ansible's `connection: local`
  inherits.** Every "already on PATH" probe for a tool this role installs
  into `~/.local/bin` (starship, neovim, lazygit, yazi, Claude Code, rtk)
  reported "absent" on *every* run, real or idempotent-rerun, because the
  controller process's PATH (not a login shell's) is what `ansible_env.PATH`
  reflects. Every run reinstalled all six from scratch. Fixed by extending
  `PATH` explicitly on each probe via the new `packages_search_path`
  default (`defaults/main.yml`).
- **`ansible.builtin.tempfile`/`community.general.npm` don't fully support
  check mode.** `tempfile` registers no `path` under `--check`, and `npm`
  hard-requires the `npm` executable to exist even to preview a change —
  both broke `--check --diff` outright on a genuinely fresh box (where
  `packages/apt.txt`'s own `nodejs`/`npm` entry is only *simulated*, not
  actually installed, by the same `--check` run). Fixed by gating each
  affected install block on `not ansible_check_mode` and adding an explicit
  `ansible.builtin.debug` preview task instead — the honest equivalent of
  legacy's own `if DRY_RUN: print(...)` branches for these same installs.

## Windows branch (`tasks/windows.yml`) — UNVERIFIED

Written using native `community.windows.win_scoop` /
`community.windows.win_scoop_bucket` (both idempotent, and `win_scoop`
bootstraps Scoop itself if missing — no manual `Invoke-RestMethod`
bootstrap needed, unlike `install.ps1`). `packages/winget.txt` has no
native Ansible module upstream in either `ansible.windows` or
`community.windows` as of the versions this role was built against — only
`win_package` (local `.msi`/`.exe` payloads) and `win_command`/`win_shell`
exist, none of which drive `winget install --id` idempotently. The winget
branch therefore falls back to `ansible.windows.win_command`, checking
`winget list --id` first to decide whether to install. **This is the
upstream-contribution candidate flagged in `provision/README.md`**: a
`community.windows.win_winget` module (real check-mode/idempotency support)
would remove that fallback entirely.

No Windows host was reachable while writing this role, and WinRM must not
be enabled on this host per the task brief — this branch has **never
executed**. Treat it exactly like `tasks/homebrew.yml`: written and
reviewed, not tested. First person with a reachable Windows target (WinRM
configured) should dry-run `site.yml --check --diff` against it and report
back.

## Devcontainer targets

This role does not special-case running *inside* a devcontainer. Its
normal per-OS-family dispatch already reproduces the #41-scoped parts of
legacy's `is_devcontainer()` block when applied to a devcontainer-like
target: `tasks/apt.yml` already installs `gh` (already in `packages/apt.txt`),
`tasks/delta.yml`'s apt-availability fallback covers the same gap
`git/ensure-delta.sh` was written for, and `tasks/ai_clis.yml` installs
claude/copilot/kilo/rtk regardless of container-ness. What legacy's
`is_devcontainer()` block does that this role does **not** yet reproduce is
the credential-forwarding checks and onboarding pre-configuration — that's
`secrets` (#44) territory, not `packages`.

The gap that remains: nothing currently *invokes* `provision/` against a
devcontainer target — there is no bootstrap layer or inventory entry that
runs `site.yml` from inside (or against) a devcontainer. That wiring is out
of scope for this role/issue; see this PR's retirement-proposal table.

## Not done here (by design)

- `bootstrap/` and `dotfiles/` layers.
- Wiring `provision/` to run against/inside a devcontainer target (see
  "Devcontainer targets" above).
- Credential-store seeding, credential-forwarding checks, Claude Code
  onboarding pre-configuration (`secrets`, #44).
- macOS defaults (`macos`, #42).
