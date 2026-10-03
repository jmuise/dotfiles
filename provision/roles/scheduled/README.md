# role: scheduled

Periodic/unattended machine-state jobs. Two independent branches, dispatched
by OS family exactly like `roles/packages/tasks/main.yml`:

| Branch                    | Task file             | Gated on                              | Verified?                                 |
| ------------------------- | ---------------------- | -------------------------------------- | ------------------------------------------ |
| Windows winget scheduling | `tasks/windows.yml`    | `ansible_facts['os_family'] == 'Windows'` | **no** — written, never executed, no Windows host reachable |
| WSL/Linux `ansible-pull`  | `tasks/ansible_pull.yml` | `ansible_facts['system'] == 'Linux'`  | yes — see "Verification" below            |

## Windows: winget weekly check + on-demand lock/apply loop

```
┌─────────────────────────────────────────────────────────────────────────┐
│  WRITTEN BUT UNVERIFIED ON WINDOWS.                                      │
│  No Windows host was reachable from the environment this role was       │
│  written in. Do not treat it as tested.                                 │
└─────────────────────────────────────────────────────────────────────────┘
```

Reproduces, unattended, what `packages/winget-check-updates.ps1` /
`winget-lock.ps1` / `winget-apply.ps1` already do by hand (see those files'
own headers) — this role schedules/orchestrates; it does not re-implement
any of the git-plumbing or winget logic living in those scripts. Nothing in
`install.ps1` or `packages/winget-*.ps1` is touched by this PR (additive
only — see the retirement table in the PR description).

- A weekly `community.windows.win_scheduled_task` runs
  `packages/winget-check-updates.ps1`, which proposes updates onto the
  `winget-updates` branch and never touches the working tree or the
  currently checked-out branch.
- `winget-lock.ps1` and `winget-apply.ps1` both mutate installed packages,
  so neither is scheduled. Instead "the loop becomes an Ansible run" for
  exactly those two on-demand, human-reviewed steps: both are tagged
  `never` (Ansible's "only when named explicitly" tag), so
  `ansible-playbook site.yml --tags scheduled_winget_lock` /
  `--tags scheduled_winget_apply` run one of them, logged through Ansible,
  in place of double-clicking the `.ps1` by hand. Neither runs on a plain
  `ansible-playbook site.yml` or `site.yml --tags scheduled`.
- Every Windows task is additionally guarded on `scheduled_windows_dotfiles_dir`
  being set (empty by default), so an unconfigured host skips rather than
  schedules a task pointing at an empty path.

### Why this could not be verified here

This host's inventory (`provision/inventory/hosts.yml`) is a single
`localhost` / `connection=local` entry, and that `localhost` is the WSL
Debian side, not Windows. `community.windows` / `ansible.windows` modules
need a connection to the Windows host to do anything — WinRM or PSRP — and
enabling either of those on this host's Windows side (the machine hosting
this WSL instance) was explicitly out of scope: it would open a
remote-management listener on a real, in-use development machine for the
sole purpose of letting an agent session test an Ansible role. That is a
disproportionate and persistent security cost for a one-off verification,
so it was not done. A GitHub issue tracks running this for real on a
Windows host before the matching `install.ps1` pieces are retired (linked
from the PR description).

There is also a concrete reason to expect friction even once a Windows host
*is* available, though it is worth being precise about which task it
actually concerns. `install.ps1` unregisters a `dotfiles-winget-check-updates`
scheduled task at every run (see its "Scheduled winget update check"
section), but its own comment says why: that task is a leftover from when
`winget.txt` covered all packages, and is now unnecessary because developer
tools moved to Scoop — **not** a policy denial. The endpoint-security denial
is real, but it concerns a *different*, never-actually-registered task:
`install.ps1`'s "Logon sync" section explains that it uses a Startup-folder
VBS launcher instead of a Scheduled Task specifically because
`Register-ScheduledTask` is **denied by endpoint-security policy** on at
least one real machine this repo is used on, even from an elevated prompt.
`community.windows.win_scheduled_task` calls the same underlying Task
Scheduler API, so it is reasonable to expect *that* policy denial could
affect this role's tasks too on that machine. This role does not work
around that (there is no legitimate Ansible-side workaround for an
endpoint-security policy), but the first real run against a Windows host
should check for it explicitly and report back — see the linked
verification issue.

## WSL/Linux: optional `ansible-pull` timer

OFF by default (`scheduled_ansible_pull_enabled: false`). When enabled:

1. Prefers a **systemd user timer**. Detected at run time by checking both
   that `ansible_facts['service_mgr'] == 'systemd'` *and* that a user
   systemd instance is actually reachable (`systemctl --user
   show-environment` succeeds) — a host can have systemd as its init system
   without a usable *user* instance (no active login session, no
   `loginctl enable-linger`), which is a real gap on some WSL
   configurations; see "Upstream-contribution candidates" below.
2. Falls back to **cron** (`ansible.builtin.cron`) on any host where that
   probe fails.
3. Whichever mechanism is *not* selected is torn down if it was left over
   from a previous run (e.g. a host that used to have a reachable user
   systemd and now doesn't, or vice versa).
4. Disabling the flag (`scheduled_ansible_pull_enabled: false`, the default)
   tears down **both** mechanisms unconditionally, whichever was present.

The pull itself: `ansible-pull -U <repo> -C <ref> -d <dest> -o <playbook>`,
plus `--verify-commit` and/or `--skip-tags <list>` when the matching
variables below are set. `-o` (`--only-if-changed`) makes most ticks a
no-op — the playbook only re-runs when `<ref>` has actually moved. No
`-i`/inventory flag: `ansible-pull` defaults to a local connection against
the host it runs on, matching `provision/inventory/hosts.yml`'s own
`connection=local` single-host model. Because the pulled command is exactly
`ansible-playbook provision/site.yml` (no `-e profile=` override), profile
resolution happens exactly as documented in `profile/README.md` — via the
shared reader (`profile/profile.py`), reading
`${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/profile` on the real machine,
independent of which checkout is doing the pulling.

Every variable component of this command line (`scheduled_ansible_pull_repo`,
`_ref`, `_dest`, `_extra_args`, `_skip_tags`, `_playbook`, and the
resolved `ansible-pull` path itself) is shell-quoted (Ansible's `quote`
filter) before being interpolated, because the same rendered string is used
both as the cron `job:` field (run through `/bin/sh -c`) and, verbatim, as a
systemd unit's `ExecStart=` (which does its own, different, shell-like
tokenising — see `tasks/ansible_pull.yml`'s "Build the ansible-pull command
line" for the full reasoning and why both interpreters agree on the
quoted result). `scheduled_ansible_pull_extra_args` and
`scheduled_ansible_pull_skip_tags` are lists, not single strings, so a flag
and its value stay two independently-quoted argv entries rather than
collapsing into one.

Verified concretely (security-review follow-up, same `debian:trixie`
systemd-as-PID-1 container approach as the rest of this README): with
`scheduled_ansible_pull_ref` set to `"a ref with space"` and
`scheduled_ansible_pull_dest` set to a path containing a space, both the
rendered systemd `ExecStart=` and the rendered cron `job:` line pass the
value through as a single argument (confirmed by pointing a throwaway
`ExecStart=`/cron job at an argv-dumping script instead of `ansible-pull` and
inspecting exactly what it received — `/bin/sh -c` and systemd's own
tokenizer agreed byte-for-byte); `systemd-analyze --user verify` passes on
the rendered unit; a rerun is idempotent (`changed=0`); and with
`scheduled_ansible_pull_verify_commit: true` and
`scheduled_ansible_pull_skip_tags: ["packages"]` set, both `--verify-commit`
and `--skip-tags packages` appear correctly in the rendered command, on both
the systemd and cron paths, and `systemd-analyze --user verify` still
passes.

Both units are **user** units (`~/.config/systemd/user`, `scope: user`
throughout `tasks/ansible_pull.yml`) — nothing here installs a system unit
or runs as root, and `ExecStart` is resolved to `ansible-pull`'s absolute
path at role-run time (see `tasks/ansible_pull.yml`) rather than left as a
live `/usr/bin/env ansible-pull` PATH lookup the unit repeats on every
timer fire. The service unit also sets a partial set of systemd sandboxing
directives (`LockPersonality`, `ProtectClock`, `ProtectHostname`,
`ProtectKernelLogs`, `ProtectKernelModules`, `ProtectKernelTunables`,
`RestrictNamespaces`, `RestrictSUIDSGID`) — **partial** because
`NoNewPrivileges=yes` and `ProtectHome=` are deliberately left out:
the pulled `provision/site.yml` can run `become: true` apt tasks that need
sudo's setuid escalation (which `NoNewPrivileges=yes` exists to block), and
both `ansible-pull` itself and whatever the pulled dotfiles-linking layer(s)
do write directly under `$HOME` (which `ProtectHome` would block). See the
template's own comment for the full reasoning.

### Security / trust model (relates to #58)

An `ansible-pull` timer re-clones `scheduled_ansible_pull_repo` at
`scheduled_ansible_pull_ref` on a fixed schedule and **runs whatever it
finds there, unattended, with no human review step in between.** That is a
materially bigger trust extension than #58's `curl | bash` install of
Claude Code:

- #58's installer script runs **once**, **interactively**, when a human
  explicitly invokes the `packages` role.
- This timer runs **repeatedly**, **unattended**, indefinitely, with no one
  watching each tick. Anyone who can land a commit on the pinned ref gets
  code execution on this machine on a schedule.

The mitigations built into this role:

- **OFF by default.** Nothing about enabling it is implicit.
- **Pinned to a ref, not a moving target used without thought.**
  `scheduled_ansible_pull_ref` defaults to `main` — spelled out explicitly in
  `defaults/main.yml` rather than left as "whatever the remote's default
  branch happens to be today" — precisely so that choice is visible to
  whoever reviews a change to it, and so it can be consciously overridden to
  a tag or commit SHA for a stronger guarantee (at the cost of needing a
  manual bump to pick up new commits). **Anyone who actually enables this
  timer should override `scheduled_ansible_pull_ref` away from `main` to a
  tag or a commit SHA.** `main` is a moving target by definition — every
  push to it is a new thing the timer will auto-execute on its next tick,
  with no per-commit human sign-off. A tag or SHA turns "auto-execute
  whatever `main` becomes" into "auto-execute the one specific tree I
  already reviewed and pinned," and makes each future update an explicit,
  reviewable bump instead of an implicit one.
- **No credential, ever.** `scheduled_ansible_pull_repo` is asserted to a
  plain HTTPS clone URL; nothing here supports embedding a token or an SSH
  deploy key. If this ever needs a private repo, that is a new decision
  requiring its own security review, not an assumed extension of this one.
- **Optional commit-signature verification.** `scheduled_ansible_pull_verify_commit`
  (default `false`) passes `--verify-commit` to `ansible-pull`, which asks
  git to verify the pulled commit's GPG signature before anything from it
  runs. This is opt-in, not on by default, because it has real prerequisites
  this role cannot set up for you: every commit the timer might pull must
  actually be signed, and the signer's public key must already be present in
  this machine's own trusted GPG keyring. Enabling it without both in place
  does not make the timer safer — it makes every tick fail outright, since
  `git verify-commit` (and therefore the whole `ansible-pull` invocation)
  errors on an unsigned commit or an untrusted signer exactly the same way.
- **Optional tag restriction.** `scheduled_ansible_pull_skip_tags` (default
  `[]`, i.e. unrestricted — the whole playbook runs, matching the historical
  behaviour of this role) passes `--skip-tags` to `ansible-pull`. Set it to
  `["packages"]` to skip the apt-install task and avoid the `become`
  requirement described below entirely, if this timer should only handle,
  e.g., the dotfiles-linking layer unattended.
- This is still, ultimately, **"trust your own repo's main branch to
  auto-execute on your own machine."** For a single-maintainer personal
  dotfiles repo that may be an acceptable baseline risk posture (it is
  already the implicit posture of running `ansible-playbook site.yml` by
  hand from a `git pull`ed checkout) — but making it run *unattended* and
  *on a schedule* changes the blast radius of a compromised commit from
  "the next time I happen to run this by hand" to "within one timer
  period, with nobody watching." Anyone enabling this variable should treat
  that trade-off as a deliberate decision, not a default to accept
  silently.

### `become` and passwordless sudo

The pulled `provision/site.yml` includes the `packages` role, whose apt-install
task escalates via `become: "{{ packages_apt_become | bool }}"` (see
`provision/roles/packages/tasks/apt.yml`) to run `apt-get install` as root.
`sudo` normally prompts for a password interactively — there is no terminal
attached to a timer-triggered `ansible-pull` run (neither the systemd
service nor the cron job has one), so an interactive prompt cannot be
answered and the `become` task simply fails, and the whole pulled playbook
run fails with it.

**Making this timer succeed unattended therefore requires passwordless
(`NOPASSWD`) sudo configured for the user this timer runs as, for whatever
commands the pulled playbook's `become` tasks need.** This role does **not**
configure `NOPASSWD` sudo itself, and does not treat needing it as
self-evident: granting `NOPASSWD` sudo is its own, separate, explicit
security decision — it means any process able to act as this user (not just
this timer) can run those commands as root without a password prompt — and
must be made deliberately, outside of this role, by whoever operates the
machine. Without it, the become tasks fail on every unattended tick, exactly
as designed: this role does not silently downgrade `become` or swallow the
failure, so an unattended run that hits an apt task without `NOPASSWD` sudo
configured reports the failure loudly rather than pretending to have
succeeded.

If unattended `become` is not something you want to grant, set
`scheduled_ansible_pull_skip_tags: ["packages"]` (above) to skip the
apt-install task entirely and let the timer handle only the tag-scoped
subset of the playbook that does not need root.

## Key variables (`defaults/main.yml`)

| Variable                              | Default                                   | Purpose                                                    |
| -------------------------------------- | ------------------------------------------ | ----------------------------------------------------------- |
| `scheduled_windows_dotfiles_dir`       | `""`                                       | Repo root as seen from the Windows host; empty skips every Windows task |
| `scheduled_ansible_pull_enabled`       | `false`                                    | Master on/off switch for the WSL/Linux timer                |
| `scheduled_ansible_pull_repo`          | this repo's HTTPS URL                      | Cloned by `ansible-pull`; must stay a plain HTTPS URL, no credential |
| `scheduled_ansible_pull_ref`           | `main`                                     | Pinned ref — **override to a tag/SHA if you enable the timer**, not left at `main` |
| `scheduled_ansible_pull_playbook`      | `provision/site.yml`                       | What `ansible-pull` runs after cloning                       |
| `scheduled_ansible_pull_extra_args`    | `[]`                                       | Extra ansible-playbook-style argv entries, e.g. `["-e", "profile=bare"]` |
| `scheduled_ansible_pull_skip_tags`     | `[]`                                       | Tags to pass via `--skip-tags`, e.g. `["packages"]` to avoid the `become`-requiring apt task |
| `scheduled_ansible_pull_verify_commit` | `false`                                    | Passes `--verify-commit`; requires signed commits + a trusted local GPG keyring |
| `scheduled_ansible_pull_oncalendar`    | `Mon *-*-* 09:00:00`                       | systemd `OnCalendar=` schedule                               |
| `scheduled_ansible_pull_cron_*`        | same cadence, cron fields                  | Used only on the cron-fallback path                          |

## Upstream-contribution candidates

Per the epic's standing "contribute the gap, don't shim it" preference:

- **No local-connection analogue for Windows modules.** Linux/macOS Ansible
  modules support `connection: local` for "manage the box I'm already
  running on"; `community.windows`/`ansible.windows` modules have no
  equivalent — they require WinRM or PSRP even to manage `localhost`, which
  means the only way to let Ansible manage the Windows side of a WSL dev
  box is to open a remote-management listener on it, for a connection that
  never leaves the machine. A local/loopback connection plugin (or a
  documented, narrowly-scoped alternative) for `ansible.windows` would
  remove that forced trade-off. This is the concrete blocker behind why
  `tasks/windows.yml` is unverified here.
- **`ansible-pull` + systemd user timers on WSL is not turnkey.** A host can
  report `ansible_facts['service_mgr'] == 'systemd'` while having no
  reachable *user* systemd instance (no active login session, `linger` not
  enabled) — this is common on exactly the kind of ephemeral/container
  verification environment this role was tested in, and is plausible on a
  real WSL distro too depending on how it was started. `ansible-pull`'s own
  docs and `ansible.builtin.systemd` give no first-class way to detect this
  short of shelling out to `systemctl --user show-environment` and checking
  the return code, which is what this role does. A documented pattern (or a
  fact) for "is a user systemd instance actually usable right now" would
  remove that shell-out. Confirmed concretely while verifying this role: a
  bare `debian:trixie` image with `systemd`/`systemd-sysv` installed and
  running as PID 1 still cannot start a user manager at all until
  `libpam-systemd` and `dbus-user-session` are *also* installed (neither is
  pulled in by `systemd-sysv`) and `loginctl enable-linger <user>` has been
  run — without both, `user@<uid>.service` fails outright with "PAM unable
  to dlopen(pam_systemd.so)". Once those two packages are present and
  linger is enabled, the probe this role runs succeeds and the systemd
  branch works exactly as designed (verified end to end: unit files
  written, timer enabled/started, next trigger computed correctly,
  idempotent re-run, clean `--check --diff`, clean removal on disable).

## Not done here (by design)

- Actually enabling/registering anything on a real Windows host — see
  "Why this could not be verified here" above.
- macOS scheduling (`launchd`) — out of scope for this role; #45 scopes the
  WSL/Linux timer branch to Linux specifically.
- Deleting or editing any part of `install.ps1`'s scheduled-task /
  logon-sync sections, or the `packages/winget-*.ps1` scripts. This PR is
  additive only; see the retirement table in the PR description.
