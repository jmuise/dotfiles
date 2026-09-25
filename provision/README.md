# provision/ — Layer 1: machine state (Ansible)

Part of the three-layer provisioning split:

| Layer | Dir          | What                                             | Tooling            |
| ----- | ------------ | ------------------------------------------------ | ------------------ |
| 0     | `bootstrap/` | Get a bare box to "can run Ansible"              | imperative script  |
| **1** | `provision/` | **Machine state: packages, services, OS config** | **Ansible (this)** |
| 2     | `dotfiles/`  | Symlink farm for config files                   | no Ansible dep     |

Ansible (not Nix) is the locked choice for Layer 1.

This directory started as a **spike** wiring up exactly one role,
`packages`, end to end (issue #36) so the shape of Layer 1 would be proven
before the rest of `install.py`/`legacy/provision_legacy.py` was ported.
`packages` has since grown to full parity with every legacy section tagged
`Retires with: #41` (issue #41, epic #35) — see
`roles/packages/README.md` for what it covers and its verification status
per OS family.

## Layout

```
provision/
├── ansible.cfg              # local-only, single host, no vault yet
├── inventory/
│   ├── hosts.yml            # one host: localhost, connection=local
│   └── group_vars/all.yml   # doc stub — the profile model lives in profile/
├── site.yml                 # entry point; reads profile/, -e profile=<tier> overrides
└── roles/
    └── packages/            # the spiked role
```

## Running it

```sh
# Dry run (always do this first):
ansible-playbook site.yml --check --diff

# Override the on-disk profile for a run:
ansible-playbook site.yml -e profile=inline --check --diff

# For real:
ansible-playbook site.yml -e profile=agentic
```

### Tags

Every task in the `packages` role is tagged `packages`; the profile-gated AI
CLI install task (`roles/packages/tasks/ai_clis.yml`) additionally carries
`ai_clis`. `site.yml`'s `pre_tasks` (profile resolution, `want_ai_clis`) are
tagged `always` so they still run even when `--tags` narrows everything else
— they're read-only and every other task depends on the facts they set.

```sh
# Everything a profile switch needs, skipping the (slow, sudo-needing) OS
# package sweep -- this is what `dotfiles profile <name>` (tools/dotfiles.py,
# #40) runs after re-linking:
ansible-playbook site.yml -e profile=bare --tags ai_clis
```

Added for #40's `dotfiles profile <name>` CLI: switching between
`bare`/`inline`/`agentic` never changes the OS package manifests, only
`want_ai_clis`, so re-running the whole `apt`/`brew` install on every profile
switch would be slow and need privileges for no reason.

`profile` is **not** defined in this tree. With no `-e profile=`, `site.yml`
shells out to the shared reader (`profile/profile.py`, PR #53), which reads
`${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/profile` and resolves an **absent
file to `agentic`** per `profile/README.md`. `-e profile=<tier>` overrides the
file for that run. An unknown value — in the file or passed with `-e` — fails
the play in `pre_tasks`, loudly, before any package work happens; the reader
is the only validator (this play does not re-implement the rules).

### Profiles

Strictly nested — each tier is a superset of the one before:

| Profile   | Adds                                          |
| --------- | -------------------------------------------- |
| `bare`    | shell + CLI toolchain from `packages/apt.txt` (no AI tooling) |
| `inline`  | `bare` + AI CLIs (`claude`, `copilot`)       |
| `agentic` | `inline` + (future: local agent runtime bits) |

## Source of truth

The `packages` role does **not** keep its own package lists. It reads the
manifests that already exist at the repo root:

| Manifest              | OS family | Status                                                         |
| --------------------- | --------- | ---------------------------------------------------------------- |
| `packages/apt.txt`    | Debian    | **verified** — real run + idempotent re-run, trixie & bookworm containers |
| `packages/Brewfile`   | macOS     | **written but UNVERIFIED** — no Mac was reachable; never executed |
| `packages/scoop.txt`  | Windows   | **written but UNVERIFIED** — no Windows host reachable; never executed |
| `packages/winget.txt` | Windows   | **written but UNVERIFIED** — no Windows host reachable; never executed |

## Verifying on WSL

`ansible-playbook ... --check --diff` needs two things the reference WSL box
did not have out of the box:

1. **`python3-apt`** — the `ansible.builtin.apt` module refuses to run in check
   mode without it. It is not pip-installable; on a normal machine
   `sudo apt-get install python3-apt` (or Ansible's own
   `auto_install_module_deps` on a non-check run) covers it.
2. **Privilege for the apt task** — a real run needs root. For a dry run on a
   box without passwordless sudo, override:

   ```sh
   ansible-playbook site.yml -e profile=inline --check --diff \
     -e packages_apt_become=false -e packages_apt_update_cache=false
   ```

## Upstream-contribution candidates

Per the standing "contribute the gap, don't shim it" preference:

- **`community.general` has no Brewfile-native module.** `homebrew`,
  `homebrew_cask`, `homebrew_tap` exist; there is no `homebrew_bundle`. The
  role parses `packages/Brewfile` itself as a result. A first-class
  `community.general.homebrew_bundle` (wrapping `brew bundle` with proper
  check-mode / diff support) would remove that parsing and is worth proposing
  upstream.
- **`ansible.builtin.apt` check-mode hard-depends on `python3-apt`** with only
  a runtime error to guide you. Not a bug exactly, but the ergonomics on a
  fresh WSL/Debian box (where the package is absent and sudo may be
  password-gated) are poor. Worth a docs/UX issue upstream.
- **Neither `ansible.windows` nor `community.windows` has a native winget
  module.** `win_package` installs local `.msi`/`.exe` payloads, not
  by-ID packages from a Windows Package Manager source; there is no
  `win_winget` wrapping `winget install/list --id` with real
  check-mode/idempotency support. `roles/packages/tasks/windows.yml` falls
  back to `ansible.windows.win_command` for exactly this reason. A
  first-class `community.windows.win_winget` would remove that fallback.

## Not done here (by design)

- Any role other than `packages`.
- `bootstrap/` and `dotfiles/` layers.
- Porting the rest of `install.py` / `legacy/provision_legacy.py`.
- Wiring `provision/` to run against/inside a devcontainer target — see
  `roles/packages/README.md`'s "Devcontainer targets" section.
