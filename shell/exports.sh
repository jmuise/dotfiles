# exports.sh — environment variables
# Sourced by .bashrc and .zshrc

# XDG base dirs
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"

# Editor
export EDITOR="code --wait"
export VISUAL="$EDITOR"

# Locale
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# History
export HISTSIZE=50000
export HISTFILESIZE=50000
export HISTCONTROL="ignoreboth:erasedups"
export HISTIGNORE="ls:ll:cd:pwd:exit:clear:history"

# Less / Man
export LESS="-RFX"
export MANPAGER="sh -c 'col -bx | bat -l man -p'" 2>/dev/null || export MANPAGER="less"

# Color for ls
export CLICOLOR=1
export LSCOLORS="ExFxCxDxBxegedabagacad"

# PATH — add common locations; dedup at the end
path_prepend() { [[ ":$PATH:" != *":$1:"* ]] && export PATH="$1:$PATH"; }

path_prepend "$HOME/.local/bin"
path_prepend "$HOME/bin"
path_prepend "/usr/local/bin"

# Homebrew (macOS + Linux)
if [[ -x "/opt/homebrew/bin/brew" ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

# Node version manager (nvm)
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
[[ -s "$NVM_DIR/bash_completion" ]] && source "$NVM_DIR/bash_completion"

# pyenv
if command -v pyenv &>/dev/null; then
  export PYENV_ROOT="$HOME/.pyenv"
  path_prepend "$PYENV_ROOT/bin"
  eval "$(pyenv init -)"
fi

# Go
if command -v go &>/dev/null; then
  export GOPATH="$HOME/go"
  path_prepend "$GOPATH/bin"
fi

# Rust
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"

# fzf defaults
export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"

# Secrets — see secrets/README.md. Claude Code's token is stored via
# git-credential-manager under a synthetic host (secrets/setup-claude-token.sh);
# GH_TOKEN is just reused from gh's own already-persisted session. Both are
# strictly no-ops if unconfigured/unauthenticated - never blocks shell startup.
#
# The sentinel-file gate matters: git-credential-fill against an unconfigured
# synthetic host isn't a fast local no-op - GCM tries (and fails) to network-
# probe the host first, adding several real seconds to every new shell until
# setup has run. The sentinel (created only by the setup script) skips that
# path entirely pre-setup, and the `-z` check means post-setup cost is paid
# once per login, not once per terminal tab (child shells inherit the export).
if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] \
   && [[ -f "$XDG_CACHE_HOME/dotfiles/claude-token.configured" ]] \
   && command -v git &>/dev/null; then
  _claude_token=$(printf 'protocol=https\nhost=dotfiles-secrets.local\nusername=claude-code\n' \
    | git credential fill 2>/dev/null | sed -n 's/^password=//p')
  [[ -n "$_claude_token" ]] && export CLAUDE_CODE_OAUTH_TOKEN="$_claude_token"
  unset _claude_token
fi

if [[ -z "${GH_TOKEN:-}" ]] && command -v gh &>/dev/null; then
  _gh_token=$(gh auth token 2>/dev/null)
  [[ -n "$_gh_token" ]] && export GH_TOKEN="$_gh_token"
  unset _gh_token
fi
