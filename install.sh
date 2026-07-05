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
DRY_RUN=false

# ── helpers ───────────────────────────────────────────────────────────────────
log()     { printf '\033[0;34m▶\033[0m %s\n' "$*"; }
success() { printf '\033[0;32m✔\033[0m %s\n' "$*"; }
warn()    { printf '\033[0;33m⚠\033[0m %s\n' "$*"; }
error()   { printf '\033[0;31m✖\033[0m %s\n' "$*" >&2; }

link() {
  local src="$1" dst="$2"
  local dst_dir; dst_dir="$(dirname "$dst")"
  $DRY_RUN || mkdir -p "$dst_dir"
  if [[ "$DRY_RUN" == true ]]; then
    printf '  link: %s → %s\n' "$src" "$dst"; return
  fi
  if [[ -L "$dst" ]]; then
    rm "$dst"
  elif [[ -e "$dst" ]]; then
    warn "Backing up $dst → $dst.bak"; mv "$dst" "$dst.bak"
  fi
  ln -sf "$src" "$dst"
  success "linked $dst"
}

# ── context detection ─────────────────────────────────────────────────────────
is_devcontainer() {
  [[ -n "${REMOTE_CONTAINERS:-}" ]] || [[ -n "${CODESPACES:-}" ]] \
    || [[ -f "/.dockerenv" ]] || [[ -n "${DEVCONTAINER:-}" ]]
}
is_macos() { [[ "$(uname)" == "Darwin" ]]; }
is_linux() { [[ "$(uname)" == "Linux" ]]; }

# ── args ──────────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    *) error "Unknown argument: $arg"; exit 1 ;;
  esac
done
$DRY_RUN && warn "DRY RUN — no changes will be made"

# ── main ──────────────────────────────────────────────────────────────────────
log "Dotfiles dir: $DOTFILES_DIR"
is_devcontainer && log "Context: devcontainer"
is_macos && log "Context: macOS"
is_linux && log "Context: Linux"

# git
log "Git..."
link "$DOTFILES_DIR/git/.gitconfig"        "$HOME/.gitconfig"
link "$DOTFILES_DIR/git/.gitignore_global" "$HOME/.gitignore_global"

if [[ ! -f "$HOME/.gitconfig.local" ]]; then
  $DRY_RUN || cat > "$HOME/.gitconfig.local" <<'EOF'
# ~/.gitconfig.local — machine-specific overrides, NOT committed to dotfiles
[user]
	name  = Your Name
	email = you@example.com
EOF
  warn "Created ~/.gitconfig.local — fill in your name and email"
fi

# shell
log "Shell..."
link "$DOTFILES_DIR/shell/aliases.sh"  "$HOME/.aliases"
link "$DOTFILES_DIR/shell/exports.sh"  "$HOME/.exports"
link "$DOTFILES_DIR/shell/.bashrc"     "$HOME/.bashrc"
link "$DOTFILES_DIR/shell/.bash_profile" "$HOME/.bash_profile"
link "$DOTFILES_DIR/shell/.zshrc"      "$HOME/.zshrc"
link "$DOTFILES_DIR/shell/.zprofile"   "$HOME/.zprofile"

# starship
link "$DOTFILES_DIR/starship/starship.toml" "$HOME/.config/starship.toml"

# tmux
link "$DOTFILES_DIR/tmux/.tmux.conf" "$HOME/.tmux.conf"

# SSH — copy template if no config exists, never overwrite
if [[ ! -f "$HOME/.ssh/config" ]]; then
  if ! $DRY_RUN; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    cp "$DOTFILES_DIR/ssh/config.example" "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
    warn "Copied SSH config template to ~/.ssh/config — customize it"
  fi
else
  warn "~/.ssh/config already exists — skipping (see ssh/config.example)"
fi

# VS Code — skip inside devcontainer (settings sync handles it there)
if ! is_devcontainer; then
  log "VS Code..."
  if is_macos; then
    VSCODE_DIR="$HOME/Library/Application Support/Code/User"
  else
    VSCODE_DIR="$HOME/.config/Code/User"
  fi
  link "$DOTFILES_DIR/vscode/settings.json"    "$VSCODE_DIR/settings.json"
  link "$DOTFILES_DIR/vscode/keybindings.json" "$VSCODE_DIR/keybindings.json"
fi

# devcontainer extras
if is_devcontainer; then
  log "Devcontainer extras..."
  if ! command -v starship &>/dev/null && ! $DRY_RUN; then
    log "Installing starship in container..."
    curl -fsSL https://starship.rs/install.sh | sh -s -- --yes 2>/dev/null \
      || warn "starship install skipped (no curl or offline)"
  fi
fi

# macOS system defaults
if is_macos && ! is_devcontainer && [[ -f "$DOTFILES_DIR/macos/defaults.sh" ]]; then
  log "macOS defaults..."
  bash "$DOTFILES_DIR/macos/defaults.sh"
fi

success "Done! Open a new shell or: source ~/.zshrc (or ~/.bashrc)"
