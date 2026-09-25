# role: wsl

WSL-distro-side machine state. Runs `hosts: all` / `connection: local` like
every other role in this play, but every task it contains is gated on WSL
detection (see below) -- on any other platform the whole role is a clean
no-op (one `set_fact`, one `debug`, nothing else).

## What it does

| Concern | Task file | Ports | Verified? |
| --- | --- | --- | --- |
| WSL-specific apt packages | `tasks/apt.yml` | n/a (new; empty by default) | yes — no-op on `--check --diff` (empty list) |
| gitconfig `[credential]` migration | `tasks/gitconfig_credential_migration.yml` | `wsl/migrate-gitconfig-credential.sh` | yes — WSL, real host |
| Windows Credential Manager bridge | `tasks/gcm_bridge.yml` | `wsl/bridge-gcm.sh` | yes — WSL, real host |
| `/etc/wsl.conf` (systemd) | `tasks/distro.yml` | n/a (new; no legacy equivalent) | yes — `--check --diff` only (root op; see "Verifying on a real WSL host") |

`wsl/install-apt-packages.sh`, `wsl/bootstrap.ps1`, `wsl/detect-state.ps1`,
`wsl/.wslconfig.template` and `wsl/.wslconfig.local.example` are **not**
ported by this role — see "Out of role scope" below.

## WSL detection

```yaml
wsl_is_wsl: >-
  {{
    wsl_detect_override
    if wsl_detect_override is not none
    else ('microsoft' in ansible_facts['kernel'] | lower)
  }}
```

Chosen over `/proc/sys/fs/binfmt_misc/WSLInterop` existence as the *gate*
because it's a fact already gathered by `site.yml`'s `gather_facts: true`
(no extra command, no extra file read, and it's inert under `--check`), and
because it's stable across both WSL generations: WSL2 ships a purpose-built
kernel whose release string is literally `*-microsoft-standard-WSL2`
(confirmed on the reference host: `6.6.114.1-microsoft-standard-WSL2`), and
WSL1 (which has no separate Linux kernel — syscalls are translated by the
Windows NT kernel directly) stamps its own build string with a trailing
`-Microsoft`. `| lower` makes the match case-insensitive across both.

`binfmt_misc/WSLInterop` is still read (`tasks/main.yml`, as
`wsl_interop_available`) and reported alongside the WSL gate, since interop
(running a Windows binary from Linux) can be turned off independently of the
distro still being WSL (`wsl.conf`'s `[interop] enabled=false`), and its
absence means "this WSL box can't currently exec Windows binaries", not
"this isn't WSL" — conflating the two would make the whole role, including
the parts that touch neither `/mnt/c` nor a Windows executable, skip on a box
that legitimately needs them. It is **not** currently used to gate any task:
`gcm_bridge.yml`'s `git.exe` discovery is a plain PATH lookup
(`command -v git.exe`) that works via the `/mnt/c` drvfs mount independently
of binfmt registration, and is itself content-gated on `~/.gitconfig.local`
rather than on interop. Confirmed live on a reference host with `[boot]
systemd=true`: `/proc/sys/fs/binfmt_misc/WSLInterop` did not exist at all
(no `WSLInterop` or `WSLInterop-late` entry), yet `command -v git.exe`
still resolved a real path via the drvfs mount — so gating discovery on this
fact would make it unreliable on a systemd-enabled host, exactly the
configuration `tasks/distro.yml` sets up. `wsl_interop_available` is kept as
a recorded, reported fact for future diagnostic use, not a behavioral gate.

### Testing off-WSL

`wsl_detect_override` (default `null`, i.e. not set) forces the gate either
way without a real WSL kernel to hand:

```sh
# Prove the role is a no-op on a plain Debian container:
ansible-playbook site.yml --tags wsl --check --diff

# Force the gate on to exercise the role's tasks on the same container:
ansible-playbook site.yml --tags wsl --check --diff -e wsl_detect_override=true
```

## Windows-side path discovery

Two tasks need a Windows-side path that nothing inside WSL can derive with
certainty (the Windows username isn't knowable from a role default). Both
default to auto-discovery, and both accept an explicit override that always
wins:

| Variable | Used by | Auto-discovery |
| --- | --- | --- |
| `wsl_windows_gcm_path` | `gcm_bridge.yml` | `git.exe` on PATH (WSL interop already maps it onto its `/mnt/c` drvfs path — confirmed live, `command -v git.exe` on the reference host returned `/mnt/c/Program Files/Git/cmd/git.exe` directly, no `wslpath` conversion needed), then two directories up + `mingw64/bin/git-credential-manager.exe` — the same derivation `wsl/bootstrap.ps1` uses. |
| `wsl_windows_gitconfig_local` | `gitconfig_credential_migration.yml` (only on a brand-new `~/.gitconfig.local`, for a `user.name`/`user.email` fallback) | A single unambiguous match of `/mnt/c/Users/*/.gitconfig.local`. Zero or more-than-one matches leave it unresolved and fall back to the same placeholder (`Your Name` / `you@example.com`) the bash version used. |

Both are read-only discovery (a `command -v` PATH probe and a controller-side
`fileglob` lookup); neither writes anything or requires `become`.

## Key variables (`defaults/main.yml`)

| Variable | Default | Purpose |
| --- | --- | --- |
| `wsl_detect_override` | `null` | force the WSL gate on/off for testing (see above) |
| `wsl_extra_apt_packages` | `[]` | WSL-only apt packages, if any ever exist — see `tasks/apt.yml` |
| `wsl_apt_become` / `wsl_apt_update_cache` | `true` / `true` | same become/cache-refresh knobs as `packages_apt_become` |
| `wsl_windows_gcm_path` | `""` (discover) | override for the Windows-side `git-credential-manager.exe` path |
| `wsl_windows_gitconfig_local` | `""` (discover) | override for the Windows-side `~/.gitconfig.local` path |
| `wsl_gcm_bin_dir` | `~/.local/bin` | where the no-spaces wrapper script is installed |
| `wsl_gcm_wrapper_name` | `dotfiles-gcm-bridge` | wrapper script filename |
| `wsl_manage_etc_wsl_conf` | `true` | master switch for `tasks/distro.yml` |
| `wsl_etc_wsl_conf_become` | `true` | set `false` to dry-run `/etc/wsl.conf` without root |
| `wsl_systemd_enabled` | `true` | desired value of `/etc/wsl.conf`'s `[boot] systemd` |

## Verifying on a real WSL host

```sh
# Read-only, no root, no changes:
ansible-playbook site.yml --tags wsl --check --diff \
  -e packages_apt_become=false -e wsl_apt_become=false -e wsl_etc_wsl_conf_become=false
```

`wsl_etc_wsl_conf_become=false` matters even under `--check`: without it,
`ansible.builtin.become` still attempts privilege escalation for that one
task (it only *skips the actual write*, not the `sudo` attempt), which
either prompts for a password or fails outright on a host without
passwordless sudo. Passing it keeps the whole run at the calling user's own
privilege level, matching the "never with become/sudo" verification
constraint for a real host.

## Out of role scope (stays in `wsl/*.ps1` / `install.ps1`)

Everything that only makes sense running as Windows, outside any WSL
distro, before one is even guaranteed to exist:

- **`wsl --install -d Debian`, the state machine in `wsl/detect-state.ps1`**
  — decides whether WSL/Debian exist at all and whether the human first-run
  wizard has been completed. Ansible's `connection: local` here assumes a
  running, provisioned Linux userspace to gather facts from in the first
  place; there's no "WSL isn't installed yet" state this role could
  meaningfully represent.
- **`~/.wslconfig` rendering (`wsl/.wslconfig.template`, `.wslconfig.local.example`)**
  — a Windows-host-wide file (`%UserProfile%\.wslconfig`) that applies to
  *every* WSL2 distro on the machine, not to any one distro's userspace.
  It's already installed by `install.ps1` (lines ~439-471) from Windows,
  where it has to run, and taking effect requires `wsl --shutdown` from
  Windows — nothing a role running inside one distro could do anyway.
- **`wsl/install-apt-packages.sh`** — superseded by `provision/roles/packages`
  (issue #41), not by this role; see the retirement proposal in the PR body
  for issue #68's disposition.
- **`wsl/bootstrap.ps1`'s own orchestration** (calling `migrate-gitconfig-credential.sh`
  and `bridge-gcm.sh` from PowerShell, then chaining into
  `bootstrap/bootstrap.sh` and `install.sh`) — the *logic* those two scripts
  contain is ported here (`gitconfig_credential_migration.yml`,
  `gcm_bridge.yml`); the PowerShell call sites that invoke them are not
  touched by this PR (additive only — see the PR body).

## Native-module choices

- `community.general.git_config_info` / `community.general.git_config` for
  all `~/.gitconfig` / `~/.gitconfig.local` reads and writes, in place of
  the original `awk`/`grep`/file-append pipeline: full check-mode + diff
  support, no raw text-block parsing, and reads a nonexistent file as "no
  settings" rather than erroring — confirmed against a scratch play.
- `community.general.ini_file` for `/etc/wsl.conf` (INI, not
  line-oriented) rather than `lineinfile`.
