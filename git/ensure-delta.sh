#!/usr/bin/env bash
# ensure-delta.sh - ensures `delta` (git-delta, used as core.pager in the
# rendered ~/.gitconfig) is on PATH in devcontainers, where `apt-get install
# git-delta` is not reliable - minimal/slim base images often don't have it
# in their default sources.list at all (confirmed live: "E: Unable to locate
# package git-delta" on a devcontainer with working sudo and apt network
# access - not a permissions/network problem, a package-availability one).
#
# Mirrors git/ensure-gcm.sh's approach instead: skip apt, download a pinned,
# checksum-verified release straight from GitHub into
# ~/.local/share/dotfiles and symlink just the binary into ~/.local/bin
# (already on PATH via shell/exports.sh). Unlike GCM's tarball, delta's is
# already flat (binary + LICENSE + README, verified by inspection) - no .so
# deps to keep out of a general PATH dir, but installed the same way anyway
# for a consistent, easily-removable layout.
#
# Deliberately not auto-updating: bump DELTA_VERSION/DELTA_SHA256_* by hand
# and re-run, same pinned-version philosophy as ensure-gcm.sh and
# packages/winget-lock.ps1.

set -euo pipefail

DELTA_VERSION="0.19.2"
DELTA_SHA256_X64="8e695c5f586a8c53d6c3b01be0b4a422ed218bfed2a56191caebe373a1c18ab2"
DELTA_SHA256_ARM64="0bfce159a5cddd5feb3d6db4a616d883ff51253ce08ac7ec11cb1d208cfaab9e"

BIN_DIR="$HOME/.local/bin"
INSTALL_DIR="$HOME/.local/share/dotfiles/delta"

command -v delta &>/dev/null && { echo "delta already on PATH - skipping."; exit 0; }

case "$(uname -m)" in
  x86_64)  ARCH="x86_64-unknown-linux-gnu";  SHA256="$DELTA_SHA256_X64" ;;
  aarch64) ARCH="aarch64-unknown-linux-gnu"; SHA256="$DELTA_SHA256_ARM64" ;;
  *)
    echo "Unsupported architecture $(uname -m) for delta - skipping." >&2
    exit 0
    ;;
esac

command -v curl &>/dev/null || { echo "curl not found - skipping delta install." >&2; exit 0; }

DIRNAME="delta-${DELTA_VERSION}-${ARCH}"
TARBALL="${DIRNAME}.tar.gz"
URL="https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/${TARBALL}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading delta v${DELTA_VERSION} (${ARCH})..."
if ! curl -fsSL "$URL" -o "$TMP_DIR/$TARBALL"; then
  echo "Download failed - skipping delta install." >&2
  exit 0
fi

ACTUAL_SHA256="$(sha256sum "$TMP_DIR/$TARBALL" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$SHA256" ]]; then
  echo "Checksum mismatch for $TARBALL (expected $SHA256, got $ACTUAL_SHA256) - aborting, nothing installed." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$BIN_DIR"
tar -xzf "$TMP_DIR/$TARBALL" -C "$TMP_DIR"
install -m 755 "$TMP_DIR/$DIRNAME/delta" "$INSTALL_DIR/delta"
ln -sf "$INSTALL_DIR/delta" "$BIN_DIR/delta"

echo "Installed delta v${DELTA_VERSION} to $INSTALL_DIR (symlinked into $BIN_DIR)"
