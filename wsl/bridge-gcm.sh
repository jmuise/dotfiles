#!/usr/bin/env bash
# bridge-gcm.sh - points WSL git at the Windows-side Git Credential Manager
# so credentials are shared with native Windows instead of WSL having no
# credential helper at all (a fresh Debian install has none - confirmed live,
# `git config --get-all credential.helper` returns nothing until this runs).
# This is what makes secrets/setup-claude-token.sh's synthetic-host secret
# (see ../secrets/README.md) readable from WSL, not just native PowerShell.
#
# Usage: bridge-gcm.sh <path-to-a-file-whose-content-is-the-gcm.exe-path>
#
# Takes the GCM path via a FILE'S CONTENT, not as an argument: that path
# contains a space ("Program Files"), and wsl.exe re-joins and re-parses its
# arguments through the Linux shell internally, which mangles embedded
# spaces - confirmed live, it corrupted this into an unparseable git-config
# value when first passed as a plain argument. Reading it from a file's
# content instead sidesteps wsl.exe's argument reparsing entirely.
#
# Content-gated like migrate-gitconfig-credential.sh: skipped if
# ~/.gitconfig.local already has a [credential] block (migrated from a
# pre-existing setup, or hand-configured) so this never overwrites a real
# customization. Must run before install.sh renders ~/.gitconfig.
#
# Does NOT store the (spacy, "Program Files") exe path directly as the
# credential.helper *value* - confirmed live that this fights git-config's
# own value serializer no matter how it's quoted (`!"<path>"` round-tripped
# through `git config --file` came out corrupted, and `git config --get`
# couldn't read it back). Instead writes a tiny no-spaces wrapper script into
# ~/.local/bin (already on PATH) that execs the real Windows binary using
# normal shell quoting - and points credential.helper at that plain, bare,
# space-free name instead, sidestepping git-config's serialization entirely.

set -euo pipefail

GCM_PATH_FILE="${1:-}"
LOCAL="$HOME/.gitconfig.local"
BIN_DIR="$HOME/.local/bin"
WRAPPER="$BIN_DIR/dotfiles-gcm-bridge"

if [[ -z "$GCM_PATH_FILE" || ! -f "$GCM_PATH_FILE" ]]; then
  echo "No Windows-side git-credential-manager.exe path file given - skipping bridge."
  exit 0
fi

GCM_EXE="$(cat "$GCM_PATH_FILE")"

if [[ -f "$LOCAL" ]] && grep -q '^\[credential\]' "$LOCAL"; then
  echo "~/.gitconfig.local already has a [credential] block - skipping bridge."
  exit 0
fi

if [[ ! -f "$GCM_EXE" ]]; then
  echo "Windows git-credential-manager.exe not found at $GCM_EXE - skipping bridge."
  exit 0
fi

mkdir -p "$BIN_DIR"
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$GCM_EXE" > "$WRAPPER"
chmod +x "$WRAPPER"

touch "$LOCAL"
# `!<cmd>` form (not a bare name) - a bare `credential.helper = X` makes git
# look for an executable literally named `git-credential-X` (its subcommand
# convention), not `X` itself - confirmed live, a bare "dotfiles-gcm-bridge"
# value made git report 'credential-dotfiles-gcm-bridge' is not a git
# command. `!<absolute path>` runs the literal command via `sh -c` instead,
# no renaming needed - and no quoting needed either, since $WRAPPER (under
# $HOME/.local/bin) has no spaces, unlike $GCM_EXE.
git config --file "$LOCAL" credential.helper "!$WRAPPER"
chmod 600 "$LOCAL"
echo "WSL git now bridges credentials to Windows Credential Manager via $WRAPPER -> $GCM_EXE"
