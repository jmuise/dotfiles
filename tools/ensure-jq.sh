#!/usr/bin/env bash
# ensure-jq.sh - ensures `jq` is on PATH inside a devcontainer. The Claude
# PreToolUse guards (claude/hooks/block-pr-merge.sh, block-ai-attribution.sh,
# require-devcontainer.sh) parse their JSON input with jq and are fail-closed:
# with no jq every Bash/Edit/Write call is blocked. jq is only in the *host*
# package lists (packages/apt.txt, Brewfile, scoop, winget), and install.py runs
# in devcontainers without sudo, so stock images lacking jq need this.
#
# No-op if jq is already on PATH (or already sitting in ~/.local/bin).
# Otherwise installs a pinned static release binary from jqlang/jq into
# ~/.local/bin - no sudo, no curl|sh. The download goes to a temp file, its
# SHA256 is verified BEFORE it is made executable, and only then is it moved
# into place atomically (same-directory temp + mv), so a partial or tampered
# download can never appear as ~/.local/bin/jq.
#
# Deliberately not auto-updating: bump JQ_VERSION and both checksums by hand,
# mirroring git/ensure-gcm.sh. Checksums come from the release's published
# sha256sum.txt:
#   https://github.com/jqlang/jq/releases/download/jq-1.8.2/sha256sum.txt
# and were cross-checked by downloading both binaries and hashing them locally.
#
# Exit status (install.py branches on it, mirroring git/ensure-gcm.sh's policy):
#   0  jq is available afterwards (installed now, or already present).
#   1  jq could not be installed for an ordinary reason - unsupported arch, no
#      curl/sha256sum, failed download. install.py WARNS and carries on; the
#      hooks fail closed with a clear "jq not found" remedy anyway.
#   3  checksum mismatch. That is a tamper (or corruption) signal, so nothing
#      is installed and install.py ABORTS the whole install.

set -euo pipefail

JQ_VERSION="1.8.2"
JQ_SHA256_AMD64="b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f"
JQ_SHA256_ARM64="8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309"

BIN_DIR="$HOME/.local/bin"
readonly EXIT_CHECKSUM_MISMATCH=3

if command -v jq &>/dev/null; then
  echo "jq already on PATH ($(command -v jq)) - skipping jq install."
  exit 0
fi

if [[ -x "$BIN_DIR/jq" ]]; then
  echo "jq already present at $BIN_DIR/jq (not on PATH here; the Claude hooks look there too) - skipping jq install."
  exit 0
fi

case "$(uname -m)" in
  x86_64)        ARCH="amd64"; SHA256="$JQ_SHA256_AMD64" ;;
  aarch64|arm64) ARCH="arm64"; SHA256="$JQ_SHA256_ARM64" ;;
  *)
    echo "Unsupported architecture $(uname -m) for the pinned jq release (linux amd64/arm64 only) - install jq with your package manager." >&2
    exit 1
    ;;
esac

command -v curl &>/dev/null || { echo "curl not found - cannot download jq; install curl or jq." >&2; exit 1; }
command -v sha256sum &>/dev/null || { echo "sha256sum not found - refusing to install an unverified jq." >&2; exit 1; }

ASSET="jq-linux-${ARCH}"
URL="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${ASSET}"

mkdir -p "$BIN_DIR"
# Temp file lives in BIN_DIR so the final mv is a same-filesystem atomic rename.
TMP_FILE="$(mktemp "$BIN_DIR/.jq.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT

echo "Downloading jq ${JQ_VERSION} (${ARCH})..."
if ! curl -fsSL "$URL" -o "$TMP_FILE"; then
  echo "Download of $URL failed - jq not installed." >&2
  exit 1
fi

ACTUAL_SHA256="$(sha256sum "$TMP_FILE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$SHA256" ]]; then
  echo "Checksum mismatch for $ASSET (expected $SHA256, got $ACTUAL_SHA256) - aborting, nothing installed." >&2
  exit "$EXIT_CHECKSUM_MISMATCH"
fi
echo "Checksum verified for $ASSET ($ACTUAL_SHA256)."

chmod 755 "$TMP_FILE"
mv -f "$TMP_FILE" "$BIN_DIR/jq"
echo "Installed jq ${JQ_VERSION} to $BIN_DIR/jq"
