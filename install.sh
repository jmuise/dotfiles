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

# Devcontainers: VS Code's own "copy git config" feature is not reliable
# enough to depend on - confirmed empirically across several rebuilds that
# it simply doesn't fire in this setup at all (no [user] section ever
# appears, even though VS Code's own credential-forwarding proxy DOES get
# wired up, so the container is clearly reachable - see
# memory/project_dotfiles_identity_guard.md for the full trail, including a
# dead-end attempt at deferring our own render to "get out of the way" of a
# copy that was never coming). Instead, devcontainers pull the real identity
# through the same git-credential-forwarding channel already proven reliable
# for the Claude Code token (secrets/README.md): the host/WSL side pushes it
# in further down (search IDENTITY_HOST below), independent of VS Code.
IDENTITY_HOST="dotfiles-identity.local"

if [[ ! -f "$HOME/.gitconfig.local" ]]; then
  existing_name="$(git config --file "$HOME/.gitconfig" --get user.name 2>/dev/null || true)"
  existing_email="$(git config --file "$HOME/.gitconfig" --get user.email 2>/dev/null || true)"

  if is_devcontainer && { [[ -z "$existing_name" ]] || [[ "$existing_name" == "Your Name" ]] \
     || [[ -z "$existing_email" ]] || [[ "$existing_email" == "you@example.com" ]]; }; then
    # No local identity yet - try pulling one through credential forwarding
    # before giving up. `-c credential.interactive=false` is load-bearing,
    # not optional: without it, GCM pops an actual interactive (GUI, if a
    # display is reachable - confirmed live, X11 is forwarded into this
    # project's devcontainer) credential prompt when nothing is stored yet
    # for this host, instead of just failing - caught only by live-testing
    # the empty-host case, see memory/project_dotfiles_identity_guard.md.
    # Timeout-guarded and `|| true`'d on top of that: `git credential fill`
    # is fatal (exit 128), not just empty output, when no helper can supply
    # a value and there's no TTY to prompt on - bit us before in the secrets
    # work (memory/project_dotfiles_secrets.md), same failure mode.
    forwarded="$(printf 'protocol=https\nhost=%s\n' "$IDENTITY_HOST" | timeout 5 git -c credential.interactive=false credential fill 2>/dev/null || true)"
    forwarded_name="$(printf '%s\n' "$forwarded" | sed -n 's/^username=//p')"
    forwarded_email="$(printf '%s\n' "$forwarded" | sed -n 's/^password=//p')"
    if [[ -n "$forwarded_name" && -n "$forwarded_email" ]]; then
      existing_name="$forwarded_name"
      existing_email="$forwarded_email"
      success "Pulled real git identity ($existing_name <$existing_email>) via credential forwarding"
    fi
  fi

  if [[ -n "$existing_name" && "$existing_name" != "Your Name" \
     && -n "$existing_email" && "$existing_email" != "you@example.com" ]]; then
    $DRY_RUN || cat > "$HOME/.gitconfig.local" <<EOF
# ~/.gitconfig.local — machine-specific overrides, NOT committed to dotfiles
[user]
	name  = $existing_name
	email = $existing_email
EOF
    success "Carried forward existing git identity ($existing_name <$existing_email>) into ~/.gitconfig.local"
  else
    # No identity to carry forward (e.g. VS Code's devcontainer "copy git
    # config" hasn't run yet at this point in the lifecycle, or never will -
    # see README's Devcontainers section). Leave [user] unset rather than
    # scaffolding a fake-looking "Your Name" - a value that LOOKS like a real
    # identity is worse than none, since the guard hooks below only catch
    # placeholders they know about, but always catch empty.
    $DRY_RUN || cat > "$HOME/.gitconfig.local" <<'EOF'
# ~/.gitconfig.local — machine-specific overrides, NOT committed to dotfiles
# No identity could be auto-detected. Fill in your name and email, e.g.:
#[user]
#	name  = Your Name
#	email = you@example.com
EOF
    warn "Created ~/.gitconfig.local with no git identity set — run: git config user.name \"Your Name\" && git config user.email you@example.com (then re-run install.sh, or edit ~/.gitconfig.local directly). Commits/pushes are blocked until then."
  fi
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
# warns) against the *rendered* ~/.gitconfig - not just .gitconfig.local's
# raw text - so this also catches a literal legacy "Your Name" placeholder
# left over from before this script stopped scaffolding one. Placeholder
# *quality* (as opposed to plain emptiness) isn't judged here anymore -
# shell/doctor.sh flags that at shell startup instead of this installer
# hard-blocking commits/pushes on it (see memory/project_dotfiles_identity_guard.md
# for why the old hook-based guard was retired).
effective_name="$(git config --file "$HOME/.gitconfig" --get user.name 2>/dev/null || true)"
effective_email="$(git config --file "$HOME/.gitconfig" --get user.email 2>/dev/null || true)"
if [[ -z "$effective_name" || -z "$effective_email" ]]; then
  warn "No git identity set — run: git config user.name \"Your Name\" && git config user.email you@example.com (or edit ~/.gitconfig.local and re-run install.sh). See shell/doctor.sh for an ongoing reminder."
elif ! is_devcontainer; then
  # Push a confirmed-set identity into the forwarding channel so any
  # devcontainer opened from this machine can pull it (see IDENTITY_HOST
  # above) instead of depending on VS Code's own git-config copy. Host/WSL
  # only - a devcontainer has no identity of its own worth propagating
  # further, and this would just be a same-value round-trip there anyway.
  printf 'protocol=https\nhost=%s\nusername=%s\npassword=%s\n' "$IDENTITY_HOST" "$effective_name" "$effective_email" \
    | git credential approve 2>/dev/null || true
fi

# gh's own token, pushed through the same forwarding channel so a
# devcontainer opened from this machine can pull it - see GH_HOST's use
# below and secrets/README.md. Host/WSL only: this is a local, non-network
# read of gh's already-persisted session (same call shell/exports.sh and
# shell/doctor.sh already make), a no-op if gh isn't installed/authenticated
# here yet.
GH_HOST="dotfiles-gh.local"
if ! is_devcontainer && command -v gh &>/dev/null; then
  gh_token_to_push="$(gh auth token 2>/dev/null || true)"
  if [[ -n "$gh_token_to_push" ]]; then
    printf 'protocol=https\nhost=%s\nusername=%s\npassword=%s\n' "$GH_HOST" "gh-cli" "$gh_token_to_push" \
      | git credential approve 2>/dev/null || true
  fi
  unset gh_token_to_push
fi

# git hooks — points this checkout at the repo-tracked hooks/ dir so
# post-checkout/post-merge/post-rewrite re-run this installer automatically
# whenever git pull/rebase/checkout change dotfiles files. Runs after the
# ~/.gitconfig render above so a mid-migration broken global config (e.g. a
# dangling symlink) can't make this git config call itself fail.
log "Git hooks..."
if $DRY_RUN; then
  printf '  git config core.hooksPath hooks\n'
else
  git -C "$DOTFILES_DIR" config core.hooksPath hooks
  chmod +x "$DOTFILES_DIR"/hooks/* 2>/dev/null || true
  success "core.hooksPath -> hooks"
fi

# Global identity guard hooks (git/global-hooks/) were retired in favor of
# shell/doctor.sh's non-blocking startup warning - clean up global
# core.hooksPath if *this* installer was the one who set it, so a machine
# that ran an older version of this script doesn't keep pointing at a
# now-empty directory. Only touches it when the value is exactly ours, same
# never-clobber-a-stranger's-config caution as git/ensure-gcm.sh.
existing_global_hooks="$(git config --global --get core.hooksPath 2>/dev/null || true)"
if [[ "$existing_global_hooks" == "$DOTFILES_DIR/git/global-hooks" ]]; then
  if $DRY_RUN; then
    printf '  git config --global --unset core.hooksPath\n'
  else
    git config --global --unset core.hooksPath
    success "Removed global core.hooksPath (identity guard retired in favor of shell/doctor.sh)"
  fi
fi

# shell
log "Shell..."
link "$DOTFILES_DIR/shell/aliases.sh"  "$HOME/.aliases"
link "$DOTFILES_DIR/shell/exports.sh"  "$HOME/.exports"
link "$DOTFILES_DIR/shell/doctor.sh"   "$HOME/.doctor"
link "$DOTFILES_DIR/shell/self-heal.sh" "$HOME/.self-heal"
link "$DOTFILES_DIR/shell/.bashrc"     "$HOME/.bashrc"
link "$DOTFILES_DIR/shell/.bash_profile" "$HOME/.bash_profile"
link "$DOTFILES_DIR/shell/.zshrc"      "$HOME/.zshrc"
link "$DOTFILES_DIR/shell/.zprofile"   "$HOME/.zprofile"

# starship — packages/Brewfile installs the binary on macOS; Linux has no
# apt package for it at all (confirmed: not in Debian/Ubuntu's default
# sources), so install it the same pinned-nothing, official-installer way
# the devcontainer path already relied on, just no longer gated to
# devcontainers only - native Linux was linking starship.toml with no binary
# to go with it.
log "Starship..."
if is_linux && ! command -v starship &>/dev/null; then
  if $DRY_RUN; then
    printf '  would install starship to ~/.local/bin (curl https://starship.rs/install.sh)\n'
  else
    # -b installs into ~/.local/bin (already on PATH via exports.sh) so this
    # never needs sudo/root - the installer's default /usr/local/bin does.
    mkdir -p "$HOME/.local/bin"
    curl -fsSL https://starship.rs/install.sh | sh -s -- --yes -b "$HOME/.local/bin" 2>/dev/null \
      || warn "starship install skipped (no curl or offline)"
  fi
fi
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

# Claude Code — global CLAUDE.md, settings, and statusline (behavior
# preferences, not project config). Not gated by is_devcontainer: Claude Code
# runs on the host and inside containers alike, and this should follow it
# everywhere. settings.json's statusLine command uses a literal "$HOME" in
# the command string (expanded by whatever shell Claude Code spawns it with,
# not by this script) instead of a baked-in absolute path, so the same
# tracked file works unmodified on every machine/user.
log "Claude Code global config..."
link "$DOTFILES_DIR/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
link "$DOTFILES_DIR/claude/settings.json" "$HOME/.claude/settings.json"
link "$DOTFILES_DIR/claude/statusline-command.sh" "$HOME/.claude/statusline-command.sh"

# devcontainer extras
if is_devcontainer; then
  log "Devcontainer extras..."
  # starship itself is installed above (now covers any Linux, not just
  # devcontainers) - this block is just the extras still specific to
  # devcontainers.
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
        # settings.json is now a symlink into the dotfiles checkout (see the
        # link() call above) - mv'ing a tmp file straight onto it would
        # delete the symlink and replace it with a plain file, silently
        # un-tracking it on every future install.sh run. Resolve to the real
        # underlying file first so only its *content* changes, same as this
        # devcontainer's own disposable clone of the repo.
        SETTINGS_JSON_REAL="$(readlink -f "$SETTINGS_JSON" 2>/dev/null || echo "$SETTINGS_JSON")"
        jq '.theme = "light-daltonized"' "$SETTINGS_JSON_REAL" > "$SETTINGS_JSON_REAL.tmp" \
          && mv "$SETTINGS_JSON_REAL.tmp" "$SETTINGS_JSON_REAL"

        log "Claude Code onboarding (login picker + theme) pre-configured."
      else
        warn "jq not found - skipping Claude Code onboarding pre-configuration."
      fi
    else
      warn "Credential forwarding not confirmed for Claude Code token - new shells won't export it automatically. See secrets/README.md."
    fi
  fi

  # gh token, same forwarding channel and same reason as the Claude Code
  # block above: `gh auth login`'s persisted session lives on the host that
  # ran it, never inside a fresh devcontainer filesystem, so nothing else
  # would ever populate GH_TOKEN in here. Confirmed live: both `gh auth
  # token` and `gh auth status` honor a GH_TOKEN env var directly (no `gh
  # auth login` needed inside the container), so exporting it in
  # shell/exports.sh is sufficient once this sentinel confirms forwarding
  # works.
  GH_SENTINEL="$CACHE_DIR/gh-token.configured"
  if [[ ! -f "$GH_SENTINEL" ]] && command -v git &>/dev/null && command -v timeout &>/dev/null && ! $DRY_RUN; then
    log "Checking gh credential forwarding..."
    GH_FORWARDED="$(timeout 5 git credential fill 2>/dev/null <<< "protocol=https"$'\n'"host=$GH_HOST"$'\n'"username=gh-cli" \
      | sed -n 's/^password=//p')" || true
    if [[ -n "$GH_FORWARDED" ]]; then
      mkdir -p "$CACHE_DIR"
      touch "$GH_SENTINEL"
      log "gh credential forwarding confirmed - GH_TOKEN will be exported automatically in new shells."
    else
      warn "Credential forwarding not confirmed for gh token - new shells won't export GH_TOKEN automatically. Run 'gh auth login' on the host and rebuild, or inside this container directly. See secrets/README.md."
    fi
  fi
fi

# macOS system defaults
if is_macos && ! is_devcontainer && [[ -f "$DOTFILES_DIR/macos/defaults.sh" ]]; then
  log "macOS defaults..."
  bash "$DOTFILES_DIR/macos/defaults.sh"
fi

success "Done! Open a new shell or: source ~/.zshrc (or ~/.bashrc)"
