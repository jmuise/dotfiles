#!/usr/bin/env bash
# =============================================================================
# install.sh — dotfiles installer for macOS, Linux, and devcontainers
#
# Usage:
#   ./install.sh           — full install
#   ./install.sh --dry-run — preview what would be linked
#
# Devcontainers: VS Code clones this repo and runs this script automatically
# when you set dotfiles.repository in your VS Code settings.
# =============================================================================

set -euo pipefail
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── self-update (fast-forward only) ───────────────────────────────────────────
# Any checkout is treated as derived: fast-forward it from origin before
# relinking, so a machine that only ever *runs* the installer still converges on
# whatever was last pushed. Deliberately --ff-only and deliberately
# non-destructive — no reset, merge, rebase, stash or checkout, ever. If this
# checkout has commits origin doesn't, we refuse to pull, warn loudly, and carry
# on with the install rather than touching a byte of that work. Every other
# failure mode (no git, not a work tree, no origin, detached/shallow clone, no
# network) is a silent-ish skip: devcontainers hit all of those routinely and
# none of them should fail an install.
#
# Re-entrancy — do NOT delete the DOTFILES_INSTALL_ACTIVE assignment below, it
# is not dead code. install.py points this checkout at the repo-tracked hooks/
# dir (`git config core.hooksPath hooks`), and post-merge / post-rewrite /
# post-checkout all exec hooks/_dispatch.sh, which runs this installer. So a
# pull that actually lands commits makes git re-enter install.sh from inside
# install.sh: a full nested duplicate install on every run that pulls anything.
# The sentinel breaks that cycle — _dispatch.sh sees it in the environment it
# inherits (installer → git → sh → hook) and exits immediately. It is exported
# for that one git command only, so a `git pull` you type by hand afterwards
# still gets its hooks. The same name appears in install.ps1 and
# hooks/_dispatch.sh; change it in one place and you must change it in all three.
DRY_RUN=0
for arg in "$@"; do
  if [[ "$arg" == "--dry-run" ]]; then DRY_RUN=1; fi
done

self_update() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  git -c fetch.pruneTags=false -C $DOTFILES_DIR pull --ff-only origin" >&2
    return 0
  fi
  skip() { echo "install.sh: skipping self-update — $1" >&2; }

  command -v git >/dev/null 2>&1 || { skip "git not found"; return 0; }
  [[ "$(git -C "$DOTFILES_DIR" rev-parse --is-inside-work-tree 2>/dev/null || true)" == "true" ]] \
    || { skip "not a git work tree"; return 0; }
  # Existence probe only — the URL is discarded and never interpolated into
  # anything. The remote below is the hardcoded literal 'origin'.
  git -C "$DOTFILES_DIR" remote get-url origin >/dev/null 2>&1 \
    || { skip "no 'origin' remote"; return 0; }
  git -C "$DOTFILES_DIR" symbolic-ref --quiet HEAD >/dev/null 2>&1 \
    || { skip "HEAD is detached"; return 0; }
  git -C "$DOTFILES_DIR" rev-parse --verify --quiet '@{upstream}' >/dev/null 2>&1 \
    || { skip "no upstream branch"; return 0; }

  # fetch.pruneTags=false overrides the Captain's global fetch.pruneTags=true
  # for this one pull: that global setting makes an ordinary --ff-only pull
  # silently delete every local tag not on origin, even on a no-op
  # "Already up to date" pull. fetch.prune (remote-tracking branches) is left
  # alone — only tag deletion is destructive to state a pull has no business
  # touching.
  if DOTFILES_INSTALL_ACTIVE=1 git -c fetch.pruneTags=false -C "$DOTFILES_DIR" pull --ff-only origin >/dev/null 2>&1; then
    return 0
  fi

  echo "" >&2
  echo "==================================================================" >&2
  echo "WARNING: could not fast-forward this checkout from origin" >&2
  echo "==================================================================" >&2
  echo "Nothing was discarded, reset, merged, rebased or stashed. Your" >&2
  echo "working tree and every local commit are exactly as you left them." >&2
  echo "" >&2
  echo "If this checkout has diverged, it holds commits origin does not." >&2
  echo "A checkout like this is meant to be a derived, pull-only mirror:" >&2
  echo "make edits in your primary checkout and push them from there." >&2
  echo "A human has to resolve this by hand — the installer will not." >&2
  echo "" >&2
  echo "(An unreachable remote lands here too. In that case the checkout" >&2
  echo "is merely stale and there is nothing to resolve.)" >&2
  echo "==================================================================" >&2
  echo "Continuing with the install — relinking is still worth doing." >&2
  echo "" >&2
  return 0
}
self_update

PY=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
if [[ -z "$PY" ]]; then
  echo "python3 not found — install Python 3 and retry" >&2
  exit 1
fi

exec "$PY" "$DOTFILES_DIR/install.py" "$@"
