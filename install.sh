#!/usr/bin/env bash
# =============================================================================
# install.sh — dotfiles installer for macOS, Linux, and devcontainers
#
# Usage:
#   ./install.sh           — full install
#   ./install.sh --dry-run — preview what would be linked
#
# Devcontainers: VS Code clones this repo and runs this script automatically
# when you set dotfiles.repository in your VS Code settings.
# =============================================================================

set -euo pipefail
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PY=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
if [[ -z "$PY" ]]; then
  echo "python3 not found — install Python 3 and retry" >&2
  exit 1
fi

exec "$PY" "$DOTFILES_DIR/install.py" "$@"
