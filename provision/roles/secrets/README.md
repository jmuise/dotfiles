# role: secrets

Seeds `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`, the git identity and (when
configured) the OpenRouter API key into the OS-native git credential store
(GCM / libsecret / Keychain), under the exact synthetic hosts
`secrets/README.md` and `git/.gitconfig.template` already define. It writes
to the **same store** `shell/exports.sh`, devcontainer credential forwarding,
and `secrets/setup-claude-token.sh` / `setup-openrouter-key.sh` already read
from and write to -- this role is an additional way to seed that store, not
a new one.

## What it does

| Task file | Secret | Synthetic host | Source of the value |
| --- | --- | --- | --- |
| `tasks/git_identity.yml` | git identity (name/email) | `dotfiles-identity.local` | derived from `~/.gitconfig` (already configured -- no external input) |
| `tasks/gh_token.yml` | `GH_TOKEN` | `dotfiles-gh.local` | derived from `gh auth token` (already-authenticated `gh` session -- no external input), with `secrets_gh_token_override` as an escape hatch |
| `tasks/claude_token.yml` | `CLAUDE_CODE_OAUTH_TOKEN` | `dotfiles-secrets.local` | `secrets_claude_code_oauth_token` (env var / `-e`, sourced externally -- there is no host-local place to derive this from) |
| `tasks/openrouter_key.yml` | `OPENROUTER_API_KEY` | `dotfiles-openrouter.local` | `secrets_openrouter_api_key` (env var / `-e`, sourced externally) |

Each is independently toggleable (`secrets_seed_identity`,
`secrets_seed_gh_token`, `secrets_seed_claude_token`,
`secrets_seed_openrouter_key`, all default `true`).

## What this role does that legacy did not

`legacy/provision_legacy.py` only ever *derives and re-stores* the git
identity and the gh token -- both come from state already present on the
host (a configured `~/.gitconfig`, an already-authenticated `gh` CLI). It
never seeds `CLAUDE_CODE_OAUTH_TOKEN` or `OPENROUTER_API_KEY` itself; those
are only ever written by the interactive `secrets/setup-claude-token.sh` /
`setup-openrouter-key.sh` scripts, because the value has to come from a
browser OAuth flow or a dashboard, not from anything already on the machine.

This role adds `tasks/claude_token.yml` and `tasks/openrouter_key.yml` as a
**second, automatable way** to seed those same two hosts -- for an operator
who already has the token (e.g. ran `claude setup-token` once, by hand, and
now wants Ansible to place it rather than re-running the interactive
script). It does not replace or retire the interactive scripts -- see
"Retirement" below.

## Vault vs. env-var lookup

Issue #44 asks to choose between ansible-vault and a credential-store
lookup for the secret *inputs*. This role uses **env-var lookup**
(`lookup('ansible.builtin.env', ...)` in `defaults/main.yml`), not
ansible-vault, for all four secrets:

- **The destination is always the same OS-native credential store**
  (GCM/libsecret/Keychain) under a synthetic host, for every consumer this
  repo already has (`shell/exports.sh`, devcontainer forwarding, the two
  interactive setup scripts). Whatever mechanism feeds this role, the value
  ends up there. An ansible-vault-encrypted copy would only be a *second*
  at-rest copy of the same secret that has to be kept in sync and rotated
  independently -- another thing to leak from, not a security improvement.
- **Two of the four secrets have no value to vault at all.** The git
  identity and `GH_TOKEN` are *derived* from already-authenticated host
  state (`git config`, `gh auth token`) -- there is nothing to encrypt into
  a vars file for these; vaulting them would mean hand-copying a live token
  into a vault file, which is strictly worse than deriving it live.
- **The other two (`CLAUDE_CODE_OAUTH_TOKEN`, `OPENROUTER_API_KEY`) already
  require a human to type/paste the raw value once**, exactly as they do
  today via the interactive scripts -- a browser OAuth flow and a
  dashboard-issued key respectively. Vault's usual value proposition (many
  operators run the same playbook without each holding the raw secret)
  doesn't apply to a single-operator dev machine: the value must reach this
  role from *somewhere* the operator controls regardless. An env var at
  invocation time carries it exactly once, in memory, for the duration of
  the run; a vault file requires the value to be encrypted to disk *and* the
  vault password to be available on that same box to decrypt it back --
  two things to protect instead of one, and per `secrets/README.md`'s own
  "no tokens are ever written into this repo" invariant, an encrypted copy
  of a live token is not something this repo should hold either, committed
  or not.
- **Env-var lookup keeps `--check` trivially safe.** An unset env var
  resolves to an empty string, which structurally gates the whole
  seed-this-secret block off (see `tasks/claude_token.yml` /
  `tasks/openrouter_key.yml`'s `when:`) -- there is no vault password prompt
  that could ever fire during a dry run or from CI.

`vault-example.yml` documents the shape these variables would take if you
still prefer an encrypted vars file for your own private inventory (e.g.
`ansible-vault encrypt_string`) -- it contains **placeholder values only**
and is not loaded by this role or by `site.yml`.

## `--check`-safety, by construction

Every task that can touch a real secret -- `git credential
approve`/`fill`, `gh auth token` -- lives inside a `block:` gated
`when: not ansible_check_mode`, in `tasks/git_identity.yml`,
`tasks/gh_token.yml`, `tasks/claude_token.yml`, `tasks/openrouter_key.yml`
and `tasks/_store_credential.yml`. This is structural, not a
`changed_when` trick: in `--check` mode those tasks are skipped entirely,
so `ansible-playbook --check` cannot call `git credential
approve`/`store`/`erase`, cannot call `gh auth token`, cannot call `git
credential fill`, and writes no file. The only tasks that run
unconditionally are read-only context detection (`stat /.dockerenv`,
`which git`) -- neither touches secret material or the filesystem beyond a
`stat`.

Every task that handles a secret value (or a value read back from the
credential store) carries `no_log: true`. Secrets are passed to `git
credential approve`/`fill` via the `command` module's `stdin:` parameter,
never as a command-line argument -- they never appear in argv or a process
listing, and `no_log: true` keeps them out of `-v`/`--diff` output too.

## Key variables (`defaults/main.yml`)

| Variable | Default | Purpose |
| --- | --- | --- |
| `secrets_identity_host` / `secrets_gh_host` / `secrets_claude_host` / `secrets_openrouter_host` | the four synthetic hosts | must match `git/.gitconfig.template` and `secrets/README.md` exactly |
| `secrets_claude_code_oauth_token` | `$CLAUDE_CODE_OAUTH_TOKEN` | value to seed; empty skips the task |
| `secrets_openrouter_api_key` | `$OPENROUTER_API_KEY` | value to seed; empty skips the task |
| `secrets_gh_token_override` | `$GH_TOKEN` | escape hatch when `gh auth token` can't derive one locally |
| `secrets_seed_identity` / `secrets_seed_gh_token` / `secrets_seed_claude_token` / `secrets_seed_openrouter_key` | `true` | per-secret on/off switch |

## Running it

```sh
# Dry run first, always:
ansible-playbook site.yml --check --diff --tags secrets

# For real:
CLAUDE_CODE_OAUTH_TOKEN="$(...)" OPENROUTER_API_KEY="$(...)" \
  ansible-playbook site.yml --tags secrets
```

`gh` and the git identity need no environment variables for the common
case -- they're derived live from already-authenticated host state, exactly
like `legacy/provision_legacy.py`.

## Retirement

See the PR description for the full legacy-piece -> role-task -> evidence
table. In short: the git-identity and gh-token *credential-store writes* in
`legacy/provision_legacy.py` (both tagged `Retires with: #44` there) are
superseded by `tasks/git_identity.yml` / `tasks/gh_token.yml`. The
credential-forwarding *checks* in `legacy/provision_legacy.py`'s
"devcontainer extras" section, and the onboarding pre-configuration next to
them, are **not** covered by this role (they run from inside a
devcontainer, checking whether forwarding *from the host* landed --
different execution context than this role, which seeds the host's own
store). Nothing in `legacy/provision_legacy.py`, `install.py`,
`install.ps1`, or `secrets/*.sh`/`*.ps1` is deleted or edited by this PR --
see the module docstring's retirement gate: removal happens only once this
role is verified against a real, running credential store, which requires
the Captain to run it by hand (see the PR description for the exact
command).
