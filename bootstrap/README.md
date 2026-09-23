# bootstrap/ — Layer 0: get a bare box to "can run Ansible"

Part of the three-layer provisioning split:

| Layer | Dir              | What                                              | Tooling            |
| ----- | ---------------- | -------------------------------------------------- | ------------------ |
| **0** | **`bootstrap/`** | **Get a bare box to "can run Ansible"**             | **imperative script (this)** |
| 1     | `provision/`     | Machine state: packages, services, OS config      | Ansible             |
| 2     | `dotfiles/`      | Symlink farm for config files                     | no Ansible dep      |

## What it does

`bootstrap.sh` is deliberately small and imperative — it is the one thing in
this repo that has to work before anything declarative can run:

1. Installs `git`, `python3`, `pipx` (and `python3-apt` on Debian/Ubuntu, via
   apt) if they aren't already present.
2. Installs `ansible` via `pipx install --include-deps ansible` if it isn't
   already on `PATH`.
3. Clones this repo, or — if the destination is already a clean checkout on
   its tracked branch — fast-forwards it (`git pull --ff-only`; never force,
   never reset, never discards local work, exactly like `install.sh`'s
   self-update).
4. Runs `ansible-playbook provision/site.yml -e profile=<x>` from the clone,
   handing off to Layer 1.

It does **not** run `install.sh` / `install.py` (Layer 2) — wiring the full
chain (Layer 0 → 1 → 2) is Phase 5 (issue #47).

## Running it

Curl-able, exactly as it would be pulled down on a bare box:

```sh
curl -fsSL https://raw.githubusercontent.com/jmuise/dotfiles/main/bootstrap/bootstrap.sh \
  | bash -s -- --profile inline
```

Or from a checkout you already have:

```sh
bash bootstrap/bootstrap.sh --profile bare
```

Always safe to preview first:

```sh
bash bootstrap/bootstrap.sh --profile bare --dry-run
```

### Options

| Flag | Env var | Default | Meaning |
| --- | --- | --- | --- |
| `--profile <name>` | `DOTFILES_BOOTSTRAP_PROFILE` | resolved from `profile/profile.sh` once cloned | `bare` \| `inline` \| `agentic`. Unknown values are rejected immediately, before anything else runs. `bootstrap.sh` never writes the profile file — that's the `dotfiles profile` CLI (issue #40). |
| `--repo <url>` | `DOTFILES_BOOTSTRAP_REPO` | `https://github.com/jmuise/dotfiles.git` | Git URL to clone. |
| `--dest <path>` | `DOTFILES_BOOTSTRAP_DEST` | `$HOME/dotfiles` | Destination directory. |
| `--ref <ref>` | `DOTFILES_BOOTSTRAP_REF` | the repo's default branch | Branch or tag to clone/track. Mainly useful for testing against a feature branch. |
| `--dry-run`, `--check` | — | off | Prints the commands it would run instead of running them, and makes no changes of its own. Passed through to `ansible-playbook` as `--check --diff` when ansible is already installed and able to run it. |

## Idempotency

Every step checks before it acts: prerequisite installs are skipped if
already present, the repo sync is a fast-forward-only pull (never a fresh
clone over existing state), and the Ansible playbook it hands off to is
itself idempotent. Re-running `bootstrap.sh` on an already-bootstrapped
machine converges rather than repeating work.

## Platform support

| OS | Status |
| --- | --- |
| Debian / Ubuntu (incl. WSL) | Verified — see the PR that introduced this file for container-based verification output. |
| macOS | **Written but UNVERIFIED.** No Mac was reachable while writing this script (same caveat already recorded for `provision/roles/packages/tasks/homebrew.yml` in PR #55). Homebrew must already be installed; `bootstrap.sh` does not install it for you — piping the Homebrew installer through another `curl \| bash` was judged one indirection too many for a path nobody has run yet. |
| Windows (native) | Not applicable here — `install.ps1` brings up WSL + Debian + Python and then invokes this script inside WSL. |

## Not done here (by design)

- Writing the `profile` file — that's the `dotfiles profile` CLI (issue #40).
- Running `install.sh` / `install.py` (Layer 2) — Phase 5 (issue #47).
- The winget / Windows-native branch — Phase 3.
