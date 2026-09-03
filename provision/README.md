# provision/ — Layer 1: machine state (Ansible)

Part of the three-layer provisioning split:

| Layer | Dir          | What                                             | Tooling            |
| ----- | ------------ | ------------------------------------------------ | ------------------ |
| 0     | `bootstrap/` | Get a bare box to "can run Ansible"              | imperative script  |
| **1** | `provision/` | **Machine state: packages, services, OS config** | **Ansible (this)** |
| 2     | `dotfiles/`  | Symlink farm for config files                   | no Ansible dep     |

Ansible (not Nix) is the locked choice for Layer 1.

This directory is currently a **spike**: it wires up exactly one role,
`packages`, end to end so the shape of Layer 1 is proven before the rest of
`install.py` is ported.

## Layout

```
provision/
├── ansible.cfg              # local-only, single host, no vault yet
├── inventory/
│   ├── hosts.yml            # one host: localhost, connection=local
│   └── group_vars/all.yml   # profile definitions (bare ⊂ inline ⊂ agentic)
├── site.yml                 # entry point; -e profile=<tier>
└── roles/
    └── packages/            # the spiked role
```

## Running it

```sh
# Dry run (always do this first):
ansible-playbook site.yml -e profile=inline --check --diff

# For real:
ansible-playbook site.yml -e profile=agentic
```

`profile` is required-ish: it defaults to `bare`, and an unknown value fails
the play in `pre_tasks` before any package work happens.

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

| Manifest             | OS family | Status in this spike           |
| -------------------- | --------- | ------------------------------ |
| `packages/apt.txt`   | Debian    | **verified on WSL** (`--check --diff`) |
| `packages/Brewfile`  | macOS     | **written but UNVERIFIED** — no Mac was reachable; never executed |
| `packages/winget.txt` | Windows   | **deferred to Phase 3** — not consumed here |

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

## Not done here (by design)

- winget / Windows branch — Phase 3.
- Any role other than `packages`.
- `bootstrap/` and `dotfiles/` layers.
- Porting the rest of `install.py`.
