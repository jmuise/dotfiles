# .zshrc — interactive zsh config

# Detect dotfiles dir even through symlinks
DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "$(readlink -f "${(%):-%x}")")" 2>/dev/null && pwd)}"

# Shared config
[[ -f "$HOME/.exports" ]] && source "$HOME/.exports"
[[ -f "$HOME/.aliases" ]] && source "$HOME/.aliases"
[[ -f "$HOME/.doctor" ]]  && source "$HOME/.doctor"

# ── zsh options ───────────────────────────────────────────────────────────────
setopt AUTO_CD              # type a dir name to cd into it
setopt CDABLE_VARS          # cd into vars holding paths
setopt CORRECT              # suggest corrections for mistyped commands
setopt HIST_IGNORE_ALL_DUPS # don't record duplicates
setopt HIST_IGNORE_SPACE    # don't record commands starting with a space
setopt HIST_VERIFY          # show expanded history before running
setopt INC_APPEND_HISTORY   # write history incrementally
setopt SHARE_HISTORY        # share history across sessions
setopt INTERACTIVE_COMMENTS # allow # comments in interactive shell
setopt EXTENDED_GLOB        # extended glob patterns
setopt NO_BEEP

HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000

# ── completion ────────────────────────────────────────────────────────────────
autoload -Uz compinit
# Only rebuild compdump once a day; use cached otherwise
_zcompdump="${ZDOTDIR:-~}/.zcompdump"
if [[ ! -f "$_zcompdump" ]] || [[ "$(date +%j)" != "$(date -r "$_zcompdump" +%j 2>/dev/null)" ]]; then
  compinit
else
  compinit -C
fi
unset _zcompdump

zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'  # case-insensitive
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*:*:kill:*' menu yes select
zstyle ':completion:*:descriptions' format '%B%d%b'

# ── key bindings ──────────────────────────────────────────────────────────────
bindkey -e  # emacs key bindings (Ctrl-A/E, Ctrl-R, etc.)
bindkey '^[[A' history-search-backward
bindkey '^[[B' history-search-forward
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[3~' delete-char

# ── plugins (lightweight, no framework required) ──────────────────────────────
# zsh-autosuggestions
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=8"
for p in \
  /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
  /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
  "$HOME/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh"; do
  [[ -f "$p" ]] && source "$p" && break
done

# zsh-syntax-highlighting (must be last)
for p in \
  /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
  /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
  "$HOME/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"; do
  [[ -f "$p" ]] && source "$p" && break
done

# ── fzf ──────────────────────────────────────────────────────────────────────
[[ -f ~/.fzf.zsh ]] && source ~/.fzf.zsh

# ── prompt ────────────────────────────────────────────────────────────────────
if command -v starship &>/dev/null; then
  eval "$(starship init zsh)"
fi

# ── local overrides ───────────────────────────────────────────────────────────
[[ -f "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"
