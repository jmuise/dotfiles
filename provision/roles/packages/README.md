# role: packages

Installs OS packages from the repo's existing manifests, plus profile-gated
AI CLIs. Keeps **no package list of its own** — the manifests at the repo root
stay the single source of truth.

## What it does

| OS family | Task file      | Reads               | Verified?                         |
| --------- | -------------- | ------------------- | --------------------------------- |
| Debian    | `tasks/apt.yml` | `packages/apt.txt`  | yes — `--check --diff` on WSL     |
| Darwin    | `tasks/homebrew.yml` | `packages/Brewfile` | **no** — written, never executed |
| (any)     | `tasks/ai_clis.yml` | pinned in `defaults/main.yml` | `claude` + `copilot`, WSL |

winget / `packages/winget.txt` is intentionally not consumed — Phase 3.

## Profile gating

`tasks/ai_clis.yml` is imported only when `want_ai_clis` is true, which
`inventory/group_vars/all.yml` defines as `profile_rank >= inline`. So:

- `profile=bare` → apt/brew only, no AI CLIs
- `profile=inline` / `profile=agentic` → apt/brew + `claude` + `copilot`

## Key variables (`defaults/main.yml`)

| Variable                       | Default | Purpose                                             |
| ------------------------------ | ------- | -------------------------------------------------- |
| `packages_apt_become`          | `true`  | set `false` to dry-run without passwordless sudo   |
| `packages_apt_update_cache`    | `true`  | set `false` to dry-run without root                |
| `packages_apt_exclude`         | `[]`    | apt.txt entries this host sources elsewhere (e.g. `nodejs`/`npm` via nvm) |
| `packages_copilot_cli_version` | pinned  | keep in lockstep with `install.py`                 |

`packages_apt_exclude` defaults to empty on purpose: drift between `apt.txt`
and what a machine actually has should be *visible* in `--check --diff`, not
silently masked. Only pin it per-host when a divergence is deliberate and
permanent.

## Manifest parsing

- `apt.txt`: strip `#` comments (inline + full-line), trim, drop blanks.
- `Brewfile`: `regex_findall` for `^tap "…"`, `^brew "…"`, `^cask "…"`;
  trailing `# comments` are ignored by the pattern.

Neither parser re-lists packages — they read the file byte-for-byte via
`slurp` at play time.
