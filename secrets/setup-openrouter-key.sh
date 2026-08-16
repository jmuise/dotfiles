#!/usr/bin/env bash
# setup-openrouter-key.sh - one-time: stores an OpenRouter API key via
# git-credential-manager under a synthetic host, so shell init
# (../shell/exports.sh) can export OPENROUTER_API_KEY + routing vars in
# every new shell without the key ever being written into this repo.
# See ./README.md.
#
# Interactive - run this yourself, it's not called by install.sh.

set -euo pipefail

HOST="dotfiles-openrouter.local"
USERNAME="openrouter"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles"
SENTINEL="$CACHE_DIR/openrouter-token.configured"

command -v git &>/dev/null || { echo "git not found." >&2; exit 1; }

echo "Paste your OpenRouter API key (blank to abort):"
read -rsp "> " TOKEN
echo
if [[ -z "$TOKEN" ]]; then
  echo "Aborted - nothing stored."
  exit 1
fi

echo
echo "About to store this value under git-credential-manager (host=$HOST):"
echo "  ${TOKEN:0:12}...${TOKEN: -4} (${#TOKEN} chars)"
read -rp "Store it? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted - nothing stored."
  exit 1
fi

printf 'protocol=https\nhost=%s\nusername=%s\npassword=%s\n' "$HOST" "$USERNAME" "$TOKEN" \
  | git credential approve

READBACK="$(printf 'protocol=https\nhost=%s\nusername=%s\n' "$HOST" "$USERNAME" \
  | git credential fill 2>/dev/null | sed -n 's/^password=//p')"
if [[ "$READBACK" != "$TOKEN" ]]; then
  echo "Stored, but reading it back didn't return the same value - something's" >&2
  echo "wrong with your credential.helper. Not writing the sentinel file; see" >&2
  echo "secrets/README.md. Run 'git config --get credential.helper' to check." >&2
  exit 1
fi

mkdir -p "$CACHE_DIR"
touch "$SENTINEL"
echo "Stored and verified. Open a new shell - OPENROUTER_API_KEY will be set automatically."
