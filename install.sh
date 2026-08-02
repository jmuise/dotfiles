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

# Like link, but writes rendered content instead of symlinking to the repo —
# used where the target must be a real, self-contained file (see the git
# config section below for why).
render() {
  local content="$1" dst="$2" marker="$3"
  local dst_dir; dst_dir="$(dirname "$dst")"
  if [[ "$DRY_RUN" == true ]]; then
    printf '  render: → %s\n' "$dst"; return
  fi
  mkdir -p "$dst_dir"
  if [[ -L "$dst" ]]; then
    rm "$dst"
  elif [[ -e "$dst" ]] && [[ "$(head -c "${#marker}" "$dst" 2>/dev/null)" != "$marker" ]]; then
    warn "Backing up $dst → $dst.bak"; mv "$dst" "$dst.bak"
  fi
  printf '%s' "$content" > "$dst"
  success "rendered $dst"
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

# git — ~/.gitconfig is rendered (template + local identity merged into one
# file), not symlinked. VS Code's Dev Containers "copy git config" feature
# copies the raw ~/.gitconfig into every devcontainer automatically, but does
# not follow `include.path` (github.com/microsoft/vscode-remote-release/
# issues/9469) — so a template that includes ~/.gitconfig.local would need a
# manual bind-mount added to every single devcontainer project to get your
# identity across. A self-contained rendered file works everywhere for free.
log "Git..."
link "$DOTFILES_DIR/git/.gitignore_global" "$HOME/.gitignore_global"

# Windows gets a credential.helper for free (Git for Windows' system config)
# and macOS via packages/Brewfile's cask - Linux has no package for it, so
# ensure one is present before rendering ~/.gitconfig below. Also covers WSL
# as a fallback if wsl/bridge-gcm.sh didn't run or couldn't find the Windows
# binary, and devcontainers as a backstop alongside VS Code's own credential
# forwarding. Content-gated - never overwrites an existing credential.helper.
if is_linux; then
  if $DRY_RUN; then
    printf '  would check/install git-credential-manager (git/ensure-gcm.sh)\n'
  else
    bash "$DOTFILES_DIR/git/ensure-gcm.sh"
  fi
fi

if [[ ! -f "$HOME/.gitconfig.local" ]]; then
  $DRY_RUN || cat > "$HOME/.gitconfig.local" <<'EOF'
# ~/.gitconfig.local — machine-specific overrides, NOT committed to dotfiles
[user]
	name  = Your Name
	email = you@example.com
EOF
  warn "Created ~/.gitconfig.local — fill in your name and email, then re-run install.sh"
fi

gitconfig_marker="# Managed by dotfiles install.sh — do not edit directly.
# Edit git/.gitconfig.template or ~/.gitconfig.local, then re-run install.sh.

"
gitconfig_local_content=""
[[ -f "$HOME/.gitconfig.local" ]] && gitconfig_local_content="$(cat "$HOME/.gitconfig.local")"
gitconfig_rendered="${gitconfig_marker}$(cat "$DOTFILES_DIR/git/.gitconfig.template")
${gitconfig_local_content}"
render "$gitconfig_rendered" "$HOME/.gitconfig" "$gitconfig_marker"

# Re-checked every run (not just the first, when the block above already
# warns) since a ~/.gitconfig.local created on a prior run and never filled
# in would otherwise render silently. The identity guard hooks below turn
# this into a hard block at commit/push time - this is just an earlier heads
# up.
if grep -qE 'name[[:space:]]*=[[:space:]]*Your Name|email[[:space:]]*=[[:space:]]*you@example\.com' "$HOME/.gitconfig.local" 2>/dev/null; then
  warn "~/.gitconfig.local still has placeholder identity — fill in your name and email, then re-run install.sh. Commits/pushes will be blocked until then."
fi

# git hooks — points this checkout at the repo-tracked hooks/ dir so
# post-checkout/post-merge/post-rewrite re-run this installer automatically
# whenever git pull/rebase/checkout change dotfiles files, and pre-commit/
# pre-push (git/identity-guard.sh) block a placeholder identity. Runs after
# the ~/.gitconfig render above so a mid-migration broken global config
# (e.g. a dangling symlink) can't make this git config call itself fail.
log "Git hooks..."
if $DRY_RUN; then
  printf '  git config core.hooksPath hooks\n'
else
  git -C "$DOTFILES_DIR" config core.hooksPath hooks
  chmod +x "$DOTFILES_DIR"/hooks/* 2>/dev/null || true
  success "core.hooksPath -> hooks"
fi

# Global identity guard — same pre-commit/pre-push check
# (git/identity-guard.sh), but wired up as core.hooksPath's *global* config
# so it fires in every other repo on this machine too (WSL, devcontainers,
# whatever), not just this one. Content-gated like git/ensure-gcm.sh: never
# overwrites an existing global core.hooksPath (e.g. a user's own hook
# manager) since that would silently disable it.
log "Global git identity guard..."
existing_global_hooks="$(git config --global --get core.hooksPath 2>/dev/null || true)"
global_hooks_dir="$DOTFILES_DIR/git/global-hooks"
if [[ -n "$existing_global_hooks" && "$existing_global_hooks" != "$global_hooks_dir" ]]; then
  warn "core.hooksPath already set globally to '$existing_global_hooks' — skipping identity guard wiring (add git/identity-guard.sh to it yourself if you want the check)."
elif $DRY_RUN; then
  printf '  git config --global core.hooksPath %s\n' "$global_hooks_dir"
else
  chmod +x "$global_hooks_dir"/* "$DOTFILES_DIR/git/identity-guard.sh" 2>/dev/null || true
  git config --global core.hooksPath "$global_hooks_dir"
  success "core.hooksPath (global) -> git/global-hooks"
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

# SSH — rendered (template + ~/.ssh/config.local merged) like ~/.gitconfig,
# instead of copy-once. Copy-once meant a bug in the shipped template (e.g. a
# macOS-only option that isn't valid on Linux OpenSSH) got permanently baked
# into every machine that had already bootstrapped, with no way for a later
# `git pull` to ever fix it. Rendering on every run means the post-merge hook
# above re-applies template fixes automatically. User hosts/overrides go in
# ~/.ssh/config.local, included before the managed defaults so they take
# precedence (ssh_config is first-obtained-value-wins) - install.sh creates
# that file once and never touches it again after that.
log "SSH..."
$DRY_RUN || { mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"; }
if [[ ! -f "$HOME/.ssh/config.local" ]]; then
  $DRY_RUN || cp "$DOTFILES_DIR/ssh/config.local.example" "$HOME/.ssh/config.local"
  warn "Created ~/.ssh/config.local — add machine-specific hosts there"
fi
ssh_marker="# Managed by dotfiles install.sh — do not edit directly.
# Edit ssh/config.template or ~/.ssh/config.local, then re-run install.sh.

"
ssh_rendered="${ssh_marker}Include ~/.ssh/config.local

$(cat "$DOTFILES_DIR/ssh/config.template")"
render "$ssh_rendered" "$HOME/.ssh/config" "$ssh_marker"
$DRY_RUN || chmod 600 "$HOME/.ssh/config"

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
  if ! command -v claude &>/dev/null && ! $DRY_RUN; then
    log "Installing Claude Code in container..."
    curl -fsSL https://claude.ai/install.sh | bash 2>/dev/null \
      || warn "Claude Code install skipped (no curl or offline)"
  fi
  if ! command -v gh &>/dev/null && ! $DRY_RUN; then
    log "Installing gh in container..."
    sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends gh \
      || warn "gh install skipped (no sudo/network, offline, or not in this image's apt sources)"
  fi
  # delta: not installed via apt - many minimal/slim devcontainer base images
  # don't have git-delta in their default sources.list at all (confirmed
  # live: "Unable to locate package" with working sudo and apt network
  # access). git/ensure-delta.sh downloads a pinned, checksum-verified
  # release instead, same approach as ensure-gcm.sh.
  if ! $DRY_RUN; then
    bash "$DOTFILES_DIR/git/ensure-delta.sh"
  else
    printf '  would check/install delta (git/ensure-delta.sh)\n'
  fi

  # Claude Code token via VS Code's git-credential forwarding - confirmed
  # live to work even for the synthetic host in secrets/README.md, not just
  # real hosts like github.com. shell/exports.sh already knows how to pull
  # the token through that forward, but only attempts it once the sentinel
  # file below exists (see exports.sh's comment - an unconfigured/unreachable
  # host makes `git credential fill` slow, so the gate exists to avoid
  # eating that cost on every new shell). That sentinel is normally written
  # by secrets/setup-claude-token.sh, which runs on the host, never inside a
  # container - so a fresh devcontainer filesystem never has it even when
  # forwarding works fine. Detect that here, once, with a timeout so a
  # container where forwarding *doesn't* work fails fast instead of hanging
  # every future shell.
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles"
  SENTINEL="$CACHE_DIR/claude-token.configured"
  if [[ ! -f "$SENTINEL" ]] && command -v git &>/dev/null && command -v timeout &>/dev/null && ! $DRY_RUN; then
    log "Checking Claude Code credential forwarding..."
    # `git credential fill` is fatal (exit 128), not just empty-output, when
    # no helper can supply a password and there's no TTY to prompt on -
    # confirmed live. Under this script's `set -euo pipefail`, that would
    # abort the entire install run on any devcontainer where forwarding
    # isn't set up, so the failure must be caught here, not just ignored via
    # 2>/dev/null.
    FORWARDED="$(timeout 5 git credential fill 2>/dev/null <<< $'protocol=https\nhost=dotfiles-secrets.local\nusername=claude-code' \
      | sed -n 's/^password=//p')" || true
    if [[ -n "$FORWARDED" ]]; then
      mkdir -p "$CACHE_DIR"
      touch "$SENTINEL"
      log "Credential forwarding confirmed - CLAUDE_CODE_OAUTH_TOKEN will be exported automatically in new shells."

      # The interactive `claude` TUI's onboarding wizard doesn't check for a
      # valid CLAUDE_CODE_OAUTH_TOKEN before showing the login-method picker
      # and opening a real browser OAuth flow - confirmed live, and it's a
      # known, accepted Anthropic limitation (GitHub issue #46259, closed
      # not-planned), not something fixable by having a valid token present.
      # Documented workaround from that issue, live-tested here: pre-set
      # hasCompletedOnboarding in ~/.claude.json. Only do this once
      # forwarding is confirmed above - completing onboarding without a
      # working token behind it would just trade one confusing failure for
      # another. Deliberately does NOT touch the separate workspace
      # folder-trust prompt - that's legitimate per-workspace friction, not
      # onboarding.
      if command -v jq &>/dev/null; then
        CLAUDE_JSON="$HOME/.claude.json"
        [[ -f "$CLAUDE_JSON" ]] || echo '{}' > "$CLAUDE_JSON"
        jq '.hasCompletedOnboarding = true' "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" \
          && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"

        # Theme lives separately in ~/.claude/settings.json, not
        # ~/.claude.json. "light-daltonized" is the literal value Claude
        # Code itself writes for the "Light mode (colorblind-friendly)"
        # picker option - confirmed live rather than guessed, since the
        # picker's on-screen labels don't map predictably to their stored
        # values (e.g. "auto" for "Auto (match terminal)" is a simple
        # lowercase word, but colorblind-friendly turned out to be
        # "daltonized", not "colorblind"). This is a fixed choice, not
        # auto-switching with the OS - the picker doesn't offer a combined
        # "auto + colorblind-friendly" option, so this user picked the fixed
        # colorblind-friendly variant over auto-switching.
        mkdir -p "$HOME/.claude"
        SETTINGS_JSON="$HOME/.claude/settings.json"
        [[ -f "$SETTINGS_JSON" ]] || echo '{}' > "$SETTINGS_JSON"
        jq '.theme = "light-daltonized"' "$SETTINGS_JSON" > "$SETTINGS_JSON.tmp" \
          && mv "$SETTINGS_JSON.tmp" "$SETTINGS_JSON"

        log "Claude Code onboarding (login picker + theme) pre-configured."
      else
        warn "jq not found - skipping Claude Code onboarding pre-configuration."
      fi
    else
      warn "Credential forwarding not confirmed for Claude Code token - new shells won't export it automatically. See secrets/README.md."
    fi
  fi
fi

# macOS system defaults
if is_macos && ! is_devcontainer && [[ -f "$DOTFILES_DIR/macos/defaults.sh" ]]; then
  log "macOS defaults..."
  bash "$DOTFILES_DIR/macos/defaults.sh"
fi

success "Done! Open a new shell or: source ~/.zshrc (or ~/.bashrc)"
