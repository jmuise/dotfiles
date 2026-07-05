# aliases.sh — shared aliases
# Sourced by .bashrc and .zshrc

# ── navigation ────────────────────────────────────────────────────────────────
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'
alias -- -='cd -'

# ── listing ───────────────────────────────────────────────────────────────────
if command -v eza &>/dev/null; then
  alias ls='eza --icons --group-directories-first'
  alias ll='eza -la --icons --group-directories-first --git'
  alias lt='eza --tree --icons -L 2'
elif ls --color=auto &>/dev/null 2>&1; then
  alias ls='ls --color=auto'
  alias ll='ls -lAh --color=auto'
else
  alias ll='ls -lAh'
fi

alias la='ll'

# ── git ───────────────────────────────────────────────────────────────────────
alias g='git'
alias gs='git status -sb'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit -m'
alias gca='git commit --amend --no-edit'
alias gp='git push'
alias gpf='git push --force-with-lease'
alias gl='git pull'
alias gco='git checkout'
alias gcob='git checkout -b'
alias glog='git log --oneline --graph --decorate -20'
alias gdiff='git diff'
alias gstash='git stash push -m'
alias gpop='git stash pop'

# ── devcontainers / docker ────────────────────────────────────────────────────
alias dc='docker compose'
alias dcu='docker compose up -d'
alias dcd='docker compose down'
alias dcl='docker compose logs -f'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dprune='docker system prune -af --volumes'

# ── editor ────────────────────────────────────────────────────────────────────
alias c='code'
alias c.='code .'

# ── network ───────────────────────────────────────────────────────────────────
alias ip='curl -fsSL https://api.ipify.org && echo'
alias localip="ipconfig getifaddr en0 2>/dev/null || hostname -I | awk '{print \$1}'"
alias ports='ss -tulnp 2>/dev/null || netstat -tulnp'

# ── utils ─────────────────────────────────────────────────────────────────────
alias path='echo $PATH | tr ":" "\n"'
alias reload='exec $SHELL -l'
alias dotfiles='cd $DOTFILES_DIR && code .'
alias hosts='sudo $EDITOR /etc/hosts'

# use bat instead of cat if available
if command -v bat &>/dev/null; then
  alias cat='bat --style=plain'
  alias less='bat --style=plain --paging=always'
fi

# use ripgrep if available
if command -v rg &>/dev/null; then
  alias grep='rg'
fi

# ── platform shims ────────────────────────────────────────────────────────────
# macOS clipboard
if command -v pbcopy &>/dev/null; then
  alias copy='pbcopy'
  alias paste='pbpaste'
elif command -v xclip &>/dev/null; then
  alias copy='xclip -selection clipboard'
  alias paste='xclip -selection clipboard -o'
elif command -v wl-copy &>/dev/null; then
  alias copy='wl-copy'
  alias paste='wl-paste'
fi

# open
if ! command -v open &>/dev/null; then
  if command -v xdg-open &>/dev/null; then
    alias open='xdg-open'
  fi
fi
