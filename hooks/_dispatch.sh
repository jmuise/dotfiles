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

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
  MINGW*|MSYS*)
    command -v pwsh >/dev/null 2>&1 && pwsh -NoLogo -NoProfile -File "$DOTFILES_DIR/install.ps1" -SkipWSL
    ;;
  *)
    "$DOTFILES_DIR/install.sh"
    ;;
esac
