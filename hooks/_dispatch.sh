#!/bin/sh
# Shared logic for the git hooks in this directory. Activated once by
# install.ps1/install.sh via `git config core.hooksPath hooks`, then keeps
# this machine's dotfiles in sync automatically after any git operation
# (pull, rebase, merge, branch checkout) that changes tracked files —
# without a manual re-run of the installer.
set -e

# Re-entrancy guard — this is NOT dead code, deleting it reintroduces a nested
# duplicate install on every run that pulls anything.
#
# The cycle: install.ps1/install.sh now fast-forward their own checkout from
# origin before relinking. A pull that actually lands commits fires
# post-merge/post-rewrite (and post-checkout), which exec into this script,
# which runs the installer — from inside the installer. Left unguarded, every
# installer run that pulls does the whole install twice.
#
# The break: both installers export DOTFILES_INSTALL_ACTIVE=1 for the duration
# of that one git pull, so the hook git spawns inherits it and we bail out here.
# There is nothing to do anyway — the outer installer relinks everything a
# moment later. Outside an installer run the variable is unset, so a `git pull`
# typed by hand still triggers the normal sync.
if [ -n "${DOTFILES_INSTALL_ACTIVE:-}" ]; then
  echo "dotfiles: installer already running — skipping nested hook sync"
  exit 0
fi

# pwd -P (not plain pwd) so a symlinked path to this checkout doesn't cause a
# false mismatch against the physically-resolved path install.py recorded.
DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"

# Canonical-install-receipt guard — must run before the uname case below so it
# covers Windows/MINGW too, not just the Unix branch.
#
# A `git worktree add` shares the primary checkout's .git/config, including
# core.hooksPath=hooks; since `hooks` is a relative path, it resolves inside
# whichever checkout this hook actually fires from. Left unguarded, a branch
# switch inside a brand-new, possibly-unreviewed worktree installs that
# worktree's content into the real $HOME. Same story for
# `git clone -c core.hooksPath=hooks <repo> <dir>`, which persists the setting
# into a fresh clone and fires on its own first checkout.
#
# The guard: only run when $HOME already holds a receipt (written by a
# deliberate install.sh/install.py run — see install.py) naming *this*
# checkout as the one it was installed from. No receipt, or a receipt naming
# a different checkout, is a silent no-op: a machine that has never had a
# deliberate install must never get one from an incidental git operation. A
# checkout that's been legitimately relocated re-arms itself by re-running
# `bash install.sh` by hand, which rewrites the receipt to the new path.
RECEIPT="$HOME/.local/state/dotfiles/install-root"
if [ ! -f "$RECEIPT" ]; then
  echo "dotfiles: no install receipt at $RECEIPT for checkout $DOTFILES_DIR — skipping hook-triggered install (this \$HOME has never had a deliberate install)"
  exit 0
fi
RECORDED_DIR="$(cat "$RECEIPT" 2>/dev/null || true)"
if [ "$RECORDED_DIR" != "$DOTFILES_DIR" ]; then
  echo "dotfiles: install receipt points at '$RECORDED_DIR', this checkout is '$DOTFILES_DIR' — skipping hook-triggered install (run 'bash install.sh' here by hand to re-arm)"
  exit 0
fi

case "$(uname -s)" in
  MINGW*|MSYS*)
    command -v pwsh >/dev/null 2>&1 && pwsh -NoLogo -NoProfile -File "$DOTFILES_DIR/install.ps1" -SkipWSL
    ;;
  *)
    "$DOTFILES_DIR/install.sh"
    ;;
esac
