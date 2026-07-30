#!/bin/sh
# Shared logic for the git hooks in this directory. Activated once by
# install.ps1/install.sh via `git config core.hooksPath hooks`, then keeps
# this machine's dotfiles in sync automatically after any git operation
# (pull, rebase, merge, branch checkout) that changes tracked files —
# without a manual re-run of the installer.
set -e
DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
  MINGW*|MSYS*)
    command -v pwsh >/dev/null 2>&1 && pwsh -NoLogo -NoProfile -File "$DOTFILES_DIR/install.ps1" -SkipWSL
    ;;
  *)
    "$DOTFILES_DIR/install.sh"
    ;;
esac
