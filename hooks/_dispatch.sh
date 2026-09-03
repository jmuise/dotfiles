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

# ── NORMALIZE:BEGIN ─────────────────────────────────────────────────────────
# _dotfiles_normalize_win_path <path>
#
# Normalizes a receipt path for comparison. On native Windows the two sides
# of the receipt check come from different toolchains and render the *same*
# physical directory two different ways:
#   - install.py runs under native Windows Python and writes the Win32 form,
#     e.g. C:\Users\you\dotfiles
#   - this hook runs under Git-for-Windows' MSYS sh and computes DOTFILES_DIR
#     with `pwd -P`, giving the POSIX/MSYS form, e.g. /c/Users/you/dotfiles
# A raw string compare of those two can never match, so the receipt guard
# would fail closed forever on Windows -- safe, but it permanently disables
# the sync this guard exists to allow. This function maps either form to one
# canonical, case-folded representation (Windows paths are case-insensitive)
# so both sides can be compared after going through it.
#
# Prefers `cygpath -u` (ships alongside this very sh.exe on Git for Windows,
# and correctly handles UNC paths, subst'd drives, 8.3 names, etc.). Falls
# back to a pure-shell translation of the common "C:\foo\bar" shape if
# cygpath isn't on PATH, so the guard still works in a minimal MSYS
# environment. On any unrecognized shape, or a cygpath failure, this prints
# nothing and returns non-zero -- callers MUST treat that as "could not
# verify" and fail closed (skip), never as "matches".
#
# Deliberately NOT invoked at all outside the MINGW/MSYS branch below: on
# Linux/macOS/WSL both sides already come from the same POSIX toolchain, so
# the existing case-sensitive raw compare is left untouched.
_dotfiles_normalize_win_path() {
  in=$1
  [ -n "$in" ] || return 1

  case "$in" in
    [A-Za-z]:\\* | [A-Za-z]:/*)
      # Win32 drive-letter form.
      if command -v cygpath >/dev/null 2>&1; then
        out=$(cygpath -u -- "$in" 2>/dev/null) || return 1
        case "$out" in /*) ;; *) return 1;; esac
      else
        drive=$(printf '%s' "$in" | cut -c1 | tr '[:upper:]' '[:lower:]')
        rest=$(printf '%s' "$in" | cut -c3- | tr '\\' '/')
        out="/${drive}${rest}"
      fi
      ;;
    /*)
      # Already POSIX/MSYS form.
      out=$in
      ;;
    *)
      return 1
      ;;
  esac

  [ -n "$out" ] || return 1
  printf '%s' "$out" | tr '[:upper:]' '[:lower:]'
}
# ── NORMALIZE:END ───────────────────────────────────────────────────────────

UNAME_S="$(uname -s)"

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

# See _dotfiles_normalize_win_path above: on Windows, normalize both sides to
# one canonical, case-folded form before comparing so a receipt written by
# native Windows Python (Win32 form) still matches this MSYS shell's own
# POSIX-form DOTFILES_DIR. Fail closed (skip) if normalization can't be done
# for either side -- never fall through and run the installer on an
# unverified match. Elsewhere, compare the raw strings exactly as before.
case "$UNAME_S" in
  MINGW*|MSYS*)
    if ! CMP_RECORDED="$(_dotfiles_normalize_win_path "$RECORDED_DIR")"; then
      echo "dotfiles: could not normalize install receipt path '$RECORDED_DIR' for comparison — skipping hook-triggered install (fail closed; run 'bash install.sh' here by hand to re-arm)"
      exit 0
    fi
    if ! CMP_DOTFILES="$(_dotfiles_normalize_win_path "$DOTFILES_DIR")"; then
      echo "dotfiles: could not normalize checkout path '$DOTFILES_DIR' for comparison — skipping hook-triggered install (fail closed)"
      exit 0
    fi
    ;;
  *)
    CMP_RECORDED="$RECORDED_DIR"
    CMP_DOTFILES="$DOTFILES_DIR"
    ;;
esac

if [ "$CMP_RECORDED" != "$CMP_DOTFILES" ]; then
  echo "dotfiles: install receipt points at '$RECORDED_DIR', this checkout is '$DOTFILES_DIR' — skipping hook-triggered install (run 'bash install.sh' here by hand to re-arm)"
  exit 0
fi

case "$UNAME_S" in
  MINGW*|MSYS*)
    command -v pwsh >/dev/null 2>&1 && pwsh -NoLogo -NoProfile -File "$DOTFILES_DIR/install.ps1" -SkipWSL
    ;;
  *)
    "$DOTFILES_DIR/install.sh"
    ;;
esac
