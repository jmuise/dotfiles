#!/usr/bin/env bash
# migrate-gitconfig-credential.sh - preserves an existing ~/.gitconfig's
# [credential] block (if any) by moving it into ~/.gitconfig.local before
# install.sh overwrites ~/.gitconfig with its rendered version (template +
# ~/.gitconfig.local merged into one file).
#
# Usage: migrate-gitconfig-credential.sh [path-to-windows-side-gitconfig.local]
#
# Content-gated, not file-existence-gated: install.sh itself creates a stub
# ~/.gitconfig.local (with placeholder user/email) if one is absent, so a
# naive "does .gitconfig.local exist" check would see that stub and skip the
# real migration if this ever ran out of order. Must run BEFORE install.sh.

set -euo pipefail

WINDOWS_LOCAL="${1:-}"
GITCONFIG="$HOME/.gitconfig"
LOCAL="$HOME/.gitconfig.local"

if [[ ! -f "$GITCONFIG" ]]; then
  echo "No existing ~/.gitconfig - nothing to migrate."
  exit 0
fi

CREDENTIAL_BLOCK=$(awk '
  /^\[credential\]/ { printing=1 }
  printing && /^\[/ && !/^\[credential\]/ { printing=0 }
  printing { print }
' "$GITCONFIG")

if [[ -z "$CREDENTIAL_BLOCK" ]]; then
  echo "No [credential] block in ~/.gitconfig - nothing to migrate."
  exit 0
fi

if [[ -f "$LOCAL" ]] && grep -q '^\[credential\]' "$LOCAL"; then
  echo "Already migrated - skipping."
  exit 0
fi

if [[ ! -f "$LOCAL" ]]; then
  NAME=""
  EMAIL=""
  if [[ -n "$WINDOWS_LOCAL" && -f "$WINDOWS_LOCAL" ]]; then
    NAME=$(git config -f "$WINDOWS_LOCAL" user.name 2>/dev/null || true)
    EMAIL=$(git config -f "$WINDOWS_LOCAL" user.email 2>/dev/null || true)
  fi
  {
    echo "# ~/.gitconfig.local - machine-specific overrides, NOT committed to dotfiles"
    echo "[user]"
    printf '\tname  = %s\n' "${NAME:-Your Name}"
    printf '\temail = %s\n' "${EMAIL:-you@example.com}"
    echo
  } > "$LOCAL"
fi

echo "$CREDENTIAL_BLOCK" >> "$LOCAL"
chmod 600 "$LOCAL"
echo "Migrated [credential] block from ~/.gitconfig to ~/.gitconfig.local"
