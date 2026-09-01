#!/usr/bin/env bash
# ensure-gcm.sh - ensures a git credential.helper is active on Linux (native,
# WSL as a fallback, and devcontainers), since unlike Windows (bundled with
# Git for Windows) and macOS (Brewfile cask), there's no Linux package for
# git-credential-manager. This matters structurally, not just for git's own
# auth: secrets/README.md's synthetic-host token store depends on some
# credential.helper being active everywhere install.sh runs.
#
# Never overwrites an existing setup - checks the *effective* credential.helper
# (system+global+local) first and no-ops if anything is already configured,
# so a user's own apt-installed GCM, or WSL's bridge-gcm.sh (which runs before
# this in the WSL flow and takes priority), always wins.
#
# Installs a pinned, checksum-verified release into ~/.local/share/dotfiles
# and symlinks just the binary into ~/.local/bin (already on PATH via
# shell/exports.sh) - no sudo, works identically in native Linux, WSL, and
# devcontainers. The release tarball is flat (binary + two .so deps + a
# NOTICE file, verified by inspection) - extracting it straight into
# ~/.local/bin would scatter those .so files into a general PATH directory,
# so they're kept together in their own dir instead and only the binary is
# exposed via symlink.
#
# Deliberately not auto-updating: bump GCM_VERSION/GCM_SHA256_* by hand and
# re-run, mirroring packages/winget-lock.ps1's pinned-version philosophy
# instead of adding a second, silent update mechanism.
#
# Does NOT run `git-credential-manager configure` - that writes
# credential.helper into ~/.gitconfig directly via `git config --global`,
# which install.sh's render() would clobber on the next run. Writes to
# ~/.gitconfig.local instead, same as bridge-gcm.sh.

set -euo pipefail

GCM_VERSION="2.9.1"
GCM_SHA256_X64="31fc151c3b111ffe25616a4356bd9a50bdcdbd0922c5e11990fb220c6caf1ce1"
GCM_SHA256_ARM64="cf3806b7528b5a5af16bd4bd0683202fc432d9008dd91d20c4c6744b24a033b5"

LOCAL="$HOME/.gitconfig.local"
BIN_DIR="$HOME/.local/bin"
INSTALL_DIR="$HOME/.local/share/dotfiles/git-credential-manager"

wire_up() {
  local bin_path="$1"
  touch "$LOCAL"
  git config --file "$LOCAL" credential.helper "$bin_path"
  # GCM's first invocation picks an interactive credential-store backend
  # (secretservice/keychain/plaintext/cache) via a terminal wizard if none is
  # configured yet - confirmed live, this hangs headless `git credential fill`
  # calls waiting on /dev/tty even with credential.interactive=never (that
  # flag only suppresses username/password prompts, not GCM's own store-
  # selection setup). Pin a store explicitly so that wizard never runs.
  # `cache` needs no keyring/D-Bus and is sufficient for this repo's
  # synthetic-host token lookups (see secrets/README.md).
  git config --file "$LOCAL" credential.credentialStore cache
  chmod 600 "$LOCAL"
}

# Checked two ways, in order: ~/.gitconfig.local's raw content first, since
# wsl/bridge-gcm.sh may have just written to it earlier in this same
# install.sh run - that file isn't merged into the *effective* ~/.gitconfig
# until install.sh's own render step runs, later in this same script, so
# checking only the effective config here would miss it and redundantly
# install a second helper right after the bridge set one up. Then the
# effective config, for a helper that's active some other way (Windows-
# native's system config, a user's own pre-existing install, etc).
if [[ -f "$LOCAL" ]] && grep -q '^\[credential\]' "$LOCAL"; then
  echo "~/.gitconfig.local already has a [credential] block - skipping GCM install."
  exit 0
fi

if [[ -n "$(git config --get credential.helper 2>/dev/null || true)" ]]; then
  echo "credential.helper already configured - skipping GCM install."
  exit 0
fi

if command -v git-credential-manager &>/dev/null; then
  echo "git-credential-manager already on PATH - wiring it up in ~/.gitconfig.local."
  wire_up "git-credential-manager"
  exit 0
fi

case "$(uname -m)" in
  x86_64)  ARCH="x64";   SHA256="$GCM_SHA256_X64" ;;
  aarch64) ARCH="arm64"; SHA256="$GCM_SHA256_ARM64" ;;
  *)
    echo "Unsupported architecture $(uname -m) for git-credential-manager - skipping." >&2
    exit 0
    ;;
esac

command -v curl &>/dev/null || { echo "curl not found - skipping GCM install." >&2; exit 0; }

TARBALL="gcm-linux-${ARCH}-${GCM_VERSION}.tar.gz"
URL="https://github.com/git-ecosystem/git-credential-manager/releases/download/v${GCM_VERSION}/${TARBALL}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading git-credential-manager v${GCM_VERSION} (${ARCH})..."
if ! curl -fsSL "$URL" -o "$TMP_DIR/$TARBALL"; then
  echo "Download failed - skipping GCM install." >&2
  exit 0
fi

ACTUAL_SHA256="$(sha256sum "$TMP_DIR/$TARBALL" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$SHA256" ]]; then
  echo "Checksum mismatch for $TARBALL (expected $SHA256, got $ACTUAL_SHA256) - aborting, nothing installed." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$BIN_DIR"
tar -xzf "$TMP_DIR/$TARBALL" -C "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/git-credential-manager"
ln -sf "$INSTALL_DIR/git-credential-manager" "$BIN_DIR/git-credential-manager"

wire_up "git-credential-manager"
echo "Installed git-credential-manager v${GCM_VERSION} to $INSTALL_DIR (symlinked into $BIN_DIR) and wired it up in ~/.gitconfig.local"
