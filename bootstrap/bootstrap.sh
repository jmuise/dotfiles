#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Layer 0 of the provisioning split (dotfiles issue #38)
#
# Imperative and minimal: get a bare box to "can run Ansible", then hand off.
# Curl-able:
#
#   curl -fsSL <raw-url>/bootstrap/bootstrap.sh | bash -s -- --profile inline
#
# so it must not assume it is running from inside a checkout — it clones one.
#
# What it does, in order:
#   1. Installs git, python3, pipx (+ python3-apt on Debian/Ubuntu) via apt,
#      and ansible via pipx (`pipx install --include-deps ansible`).
#   2. Clones this repo (or fast-forwards an existing, clean, on-branch
#      checkout at the destination — never force, never reset, never
#      discards local work).
#   3. Runs `ansible-playbook provision/site.yml -e profile=<x>` from the
#      clone, handing off to Layer 1.
#
# Does NOT run install.sh / install.py (Layer 2) — that wiring is Phase 5
# (dotfiles issue #47).
#
# Safe to re-run. --dry-run/--check makes no changes of its own (it prints
# the commands it would run instead) and passes --check --diff through to
# ansible-playbook when ansible is already available to run it.
#
# The whole script is one function invoked on the last line, so a curl
# download truncated mid-transfer fails to parse instead of executing a
# partial script.
# =============================================================================

set -euo pipefail

DOTFILES_BOOTSTRAP_DEFAULT_REPO="https://github.com/jmuise/dotfiles.git"

log()  { printf 'bootstrap: %s\n' "$*"; }
warn() { printf 'bootstrap: warning: %s\n' "$*" >&2; }
die()  { printf 'bootstrap: error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: bootstrap.sh --profile <bare|inline|agentic> [options]

Layer 0 of the dotfiles provisioning split: installs the minimal
prerequisites (git, python3, pipx, ansible), clones or fast-forwards this
repo, then runs 'ansible-playbook provision/site.yml' to hand off to Layer 1.

Options:
  --profile <name>    bare | inline | agentic. If omitted, resolved from the
                       shared profile/profile.sh reader once the repo is
                       cloned (absent profile file -> agentic; invalid file
                       -> error, never falls back).
  --repo <url>         git URL to clone. Default: $DOTFILES_BOOTSTRAP_DEFAULT_REPO
                       (env: DOTFILES_BOOTSTRAP_REPO)
  --dest <path>        destination directory. Default: \$HOME/dotfiles
                       (env: DOTFILES_BOOTSTRAP_DEST)
  --ref <ref>          branch or tag to clone/track. Default: the repo's
                       default branch (env: DOTFILES_BOOTSTRAP_REF)
  --dry-run, --check   print what would be installed/run; make no changes of
                       its own. Passed through to ansible-playbook as
                       '--check --diff' when ansible is already available.
  -h, --help           show this help

Does NOT run install.sh / install.py (Layer 2) — see bootstrap/README.md.
EOF
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 \
      || die "not running as root and 'sudo' is not on PATH — re-run as root, or install sudo first"
    sudo "$@"
  fi
}

detect_os_family() {
  case "$(uname -s)" in
    Linux)
      if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
      fi
      case "${ID:-}${ID_LIKE:-}" in
        *debian*|*ubuntu*) echo debian ;;
        *) die "unsupported Linux distro (ID=${ID:-unknown}) — bootstrap.sh supports Debian/Ubuntu only" ;;
      esac
      ;;
    Darwin) echo macos ;;
    *) die "unsupported OS: $(uname -s)" ;;
  esac
}

# --- prerequisites: git, python3, pipx (+ python3-apt), ansible -------------

install_prereqs_debian() {
  local dry_run="$1" pkgs="git python3 python3-apt pipx" p missing=()
  for p in $pkgs; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    log "apt prerequisites already present ($pkgs)"
    return 0
  fi
  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] would run: apt-get update && apt-get install -y ${missing[*]}"
    return 0
  fi
  log "installing apt prerequisites: ${missing[*]}"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

# UNVERIFIED — no Mac was reachable while writing this script (mirrors the
# same caveat already recorded for provision/roles/packages/tasks/homebrew.yml
# in PR #55). Homebrew is required rather than auto-installed: piping the
# Homebrew installer through another curl|bash is one indirection too many
# for an unverified path.
install_prereqs_macos() {
  local dry_run="$1" pkgs="git python3 pipx" p missing=()
  warn "macOS support in bootstrap.sh is UNVERIFIED — see bootstrap/README.md"
  command -v brew >/dev/null 2>&1 \
    || die "Homebrew not found. Install it from https://brew.sh, then re-run bootstrap.sh."
  for p in $pkgs; do
    brew list --formula "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    log "brew prerequisites already present ($pkgs)"
    return 0
  fi
  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] would run: brew install ${missing[*]}"
    return 0
  fi
  log "installing brew prerequisites: ${missing[*]}"
  brew install "${missing[@]}"
}

install_ansible_via_pipx() {
  local dry_run="$1"
  export PATH="$HOME/.local/bin:$PATH"
  if command -v ansible-playbook >/dev/null 2>&1; then
    log "ansible already present ($(command -v ansible-playbook))"
    return 0
  fi
  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] would run: pipx install --include-deps ansible"
    return 0
  fi
  command -v pipx >/dev/null 2>&1 || die "pipx not found on PATH after prerequisite install"
  log "installing ansible (pipx install --include-deps ansible)"
  pipx install --include-deps ansible
}

# --- clone / fast-forward the repo ------------------------------------------

clone_into() {
  local dry_run="$1" repo="$2" ref="$3" dest="$4"
  if [ "$dry_run" -eq 1 ]; then
    if [ -n "$ref" ]; then
      log "[dry-run] would run: git clone --branch $ref -- $repo $dest"
    else
      log "[dry-run] would run: git clone -- $repo $dest"
    fi
    return 0
  fi
  log "cloning $repo -> $dest"
  if [ -n "$ref" ]; then
    git clone --branch "$ref" -- "$repo" "$dest"
  else
    git clone -- "$repo" "$dest"
  fi
}

# Fast-forward an existing checkout. Deliberately as conservative as
# install.sh's self-update: never force, never reset, never merge, never
# discard local work. Any doubt at all -> warn and leave the checkout as-is.
sync_existing_clone() {
  local dry_run="$1" repo="$2" ref="$3" dest="$4"
  local origin_url current_branch expected_branch

  git -C "$dest" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "$dest exists but is not a usable git work tree"

  origin_url=$(git -C "$dest" remote get-url origin 2>/dev/null || true)
  if [ -z "$origin_url" ]; then
    warn "$dest has no 'origin' remote — leaving it as-is, not pulling"
    return 0
  fi
  if [ "$origin_url" != "$repo" ]; then
    warn "$dest's origin ($origin_url) differs from --repo ($repo) — leaving it as-is, not pulling"
    return 0
  fi
  if ! current_branch=$(git -C "$dest" symbolic-ref --quiet --short HEAD 2>/dev/null); then
    warn "$dest HEAD is detached — skipping self-update, using checkout as-is"
    return 0
  fi

  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] would fetch origin and, only if $dest is on its tracked branch and clean, run: git -C $dest pull --ff-only origin <branch>"
    return 0
  fi

  if ! git -C "$dest" fetch --quiet origin; then
    warn "could not fetch origin for $dest — using checkout as-is"
    return 0
  fi

  if [ -n "$ref" ]; then
    expected_branch="$ref"
  else
    git -C "$dest" remote set-head origin --auto >/dev/null 2>&1 || true
    expected_branch=$(git -C "$dest" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') || true
  fi
  if [ -z "$expected_branch" ]; then
    warn "could not determine which branch to track for $dest — using checkout as-is"
    return 0
  fi
  if [ "$current_branch" != "$expected_branch" ]; then
    warn "$dest is on branch '$current_branch', not '$expected_branch' — skipping self-update, using checkout as-is"
    return 0
  fi
  if [ -n "$(git -C "$dest" status --porcelain)" ]; then
    warn "$dest has local changes — skipping self-update (never force, never reset), using checkout as-is"
    return 0
  fi

  log "fast-forwarding existing checkout at $dest"
  git -C "$dest" pull --ff-only origin "$expected_branch"
}

# Refuse to touch $dest if it, or any ancestor between it and $HOME
# (inclusive), is a symlink. This is a *write* path -- cloning an entire repo
# through an attacker-controlled symlinked ancestor is worse than the
# inconvenience of refusing to run, so unlike profile.sh's read-only symlink
# check (issue #29, warn-and-continue), this errors instead of warning and
# carrying on. Only walks the ancestry when $dest is actually under $HOME;
# outside $HOME there is no fixed stopping point to assert without more
# context, so it is left alone.
check_dest_symlinks() {
  local dest="$1" home dir parent
  home="${HOME%/}"
  dest="${dest%/}"

  case "$dest" in
    "$home"|"$home"/*) : ;;
    *) return 0 ;;
  esac

  dir="$dest"
  while : ; do
    if [ -L "$dir" ]; then
      die "$dir is a symlink -- refusing to clone into a symlinked destination or through a symlinked ancestor (it could redirect where the clone actually lands)"
    fi
    [ "$dir" = "$home" ] && break
    parent=$(dirname -- "$dir")
    [ "$parent" = "$dir" ] && break
    dir="$parent"
  done
}

sync_repo() {
  local dry_run="$1" repo="$2" ref="$3" dest="$4"
  check_dest_symlinks "$dest"
  if [ -d "$dest/.git" ]; then
    sync_existing_clone "$dry_run" "$repo" "$ref" "$dest"
  elif [ -e "$dest" ]; then
    if [ -d "$dest" ] && [ -z "$(ls -A "$dest" 2>/dev/null)" ]; then
      clone_into "$dry_run" "$repo" "$ref" "$dest"
    else
      die "$dest already exists and is neither an empty directory nor a git checkout — refusing to touch it. Pass --dest to choose another location."
    fi
  else
    clone_into "$dry_run" "$repo" "$ref" "$dest"
  fi
}

# --- hand off to Layer 1 -----------------------------------------------------

resolve_profile() {
  local dest="$1"
  if [ ! -f "$dest/profile/profile.sh" ]; then
    die "profile/profile.sh not found under $dest — cannot resolve the active profile"
  fi
  # shellcheck source=/dev/null
  . "$dest/profile/profile.sh"
  dotfiles_profile
}

run_ansible() {
  local dry_run="$1" dest="$2" profile="$3" resolved

  if [ -n "$profile" ]; then
    resolved="$profile"
  elif [ -f "$dest/profile/profile.sh" ]; then
    resolved=$(resolve_profile "$dest") \
      || die "could not resolve the active profile from $dest/profile/profile.sh (see message above)"
  elif [ "$dry_run" -eq 1 ]; then
    log "[dry-run] --profile not given and $dest/profile/profile.sh isn't available yet — profile would be resolved from it once the repo is cloned"
    resolved=""
  else
    die "profile/profile.sh not found under $dest — cannot resolve the active profile"
  fi

  export PATH="$HOME/.local/bin:$PATH"
  if ! command -v ansible-playbook >/dev/null 2>&1; then
    if [ "$dry_run" -eq 1 ]; then
      log "[dry-run] would run: (cd $dest/provision && ansible-playbook site.yml -e profile=${resolved:-<resolved-profile>} --check --diff)"
      return 0
    fi
    die "ansible-playbook not found on PATH after the prerequisite install step"
  fi

  local args=(site.yml -e "profile=$resolved")
  [ "$dry_run" -eq 1 ] && args+=(--check --diff)
  log "running: ansible-playbook ${args[*]} (in $dest/provision)"
  (cd "$dest/provision" && ansible-playbook "${args[@]}")
}

main() {
  local profile="${DOTFILES_BOOTSTRAP_PROFILE:-}"
  local repo="${DOTFILES_BOOTSTRAP_REPO:-$DOTFILES_BOOTSTRAP_DEFAULT_REPO}"
  local dest="${DOTFILES_BOOTSTRAP_DEST:-$HOME/dotfiles}"
  local ref="${DOTFILES_BOOTSTRAP_REF:-}"
  local dry_run=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) [ $# -ge 2 ] || die "--profile needs a value"; profile="$2"; shift 2 ;;
      --profile=*) profile="${1#*=}"; shift ;;
      --repo) [ $# -ge 2 ] || die "--repo needs a value"; repo="$2"; shift 2 ;;
      --repo=*) repo="${1#*=}"; shift ;;
      --dest) [ $# -ge 2 ] || die "--dest needs a value"; dest="$2"; shift 2 ;;
      --dest=*) dest="${1#*=}"; shift ;;
      --ref) [ $# -ge 2 ] || die "--ref needs a value"; ref="$2"; shift 2 ;;
      --ref=*) ref="${1#*=}"; shift ;;
      --dry-run|--check) dry_run=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done

  if [ -n "$profile" ]; then
    case "$profile" in
      bare|inline|agentic) ;;
      *) die "invalid --profile '$profile' — must be one of: bare, inline, agentic" ;;
    esac
  fi

  # A value starting with '-' looks like an option, not a value (e.g.
  # --repo --upload-pack=x, or --dest -x), and a downstream `git clone` / `ls`
  # / `cd` could otherwise parse it as a flag instead of a plain argument.
  # Reject up front rather than relying on every callsite to defend itself.
  case "$repo" in
    -*) die "--repo value must not start with '-' (looks like an option, not a value): '$repo'" ;;
  esac
  case "$dest" in
    -*) die "--dest value must not start with '-' (looks like an option, not a value): '$dest'" ;;
  esac
  case "$ref" in
    -*) die "--ref value must not start with '-' (looks like an option, not a value): '$ref'" ;;
  esac

  if [ "$dry_run" -eq 1 ]; then
    log "DRY RUN — no changes will be made; ansible will still run --check --diff if it is already installed"
  fi

  local family
  family=$(detect_os_family)

  case "$family" in
    debian) install_prereqs_debian "$dry_run" ;;
    macos)  install_prereqs_macos "$dry_run" ;;
  esac

  install_ansible_via_pipx "$dry_run"
  sync_repo "$dry_run" "$repo" "$ref" "$dest"
  run_ansible "$dry_run" "$dest" "$profile"

  log "done"
}

main "$@"
