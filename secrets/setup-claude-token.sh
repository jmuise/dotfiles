#!/usr/bin/env bash
# setup-claude-token.sh - one-time: generates a long-lived Claude Code OAuth
# token and stores it via git-credential-manager under a synthetic host, so
# shell init (../shell/exports.sh) can export CLAUDE_CODE_OAUTH_TOKEN in
# every new shell without the token ever being written into this repo.
# See ./README.md.
#
# Interactive - run this yourself, it's not called by install.sh. Not piped
# through `claude setup-token`: its exact stdout format (token-only vs mixed
# with prompts) isn't documented, so this lets it run against a real TTY and
# has you paste the printed token back, rather than risk silently storing the
# wrong thing.

set -euo pipefail

HOST="dotfiles-secrets.local"
USERNAME="claude-code"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles"
SENTINEL="$CACHE_DIR/claude-token.configured"

command -v claude &>/dev/null || { echo "claude CLI not found - install Claude Code first." >&2; exit 1; }
command -v git    &>/dev/null || { echo "git not found." >&2; exit 1; }

echo "Running 'claude setup-token' - complete the browser/code flow, then copy the token it prints."
echo
claude setup-token
echo
read -rsp "Paste the token printed above to store it (blank to abort): " TOKEN
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

# `approve` reports success even when nothing was actually persisted (e.g.
# no credential.helper configured, or a broken one) - confirmed live, it
# exits 0 regardless. Read it straight back before trusting it worked.
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
echo "Stored and verified. Open a new shell - CLAUDE_CODE_OAUTH_TOKEN will be set automatically."
