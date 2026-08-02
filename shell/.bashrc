# .bashrc — interactive bash config
# Sourced for interactive non-login shells
# (login shells source .bash_profile which sources this)

# Not interactive? Bail early.
[[ $- != *i* ]] && return

# Load shared config
DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)}"
[[ -f "$HOME/.exports" ]] && source "$HOME/.exports"
[[ -f "$HOME/.aliases" ]] && source "$HOME/.aliases"
[[ -f "$HOME/.doctor" ]]  && source "$HOME/.doctor"

# Bash options
shopt -s checkwinsize  # update LINES/COLUMNS after each command
shopt -s histappend    # append to history, don't overwrite
shopt -s cdspell       # correct minor cd typos
shopt -s cmdhist       # save multi-line commands as one history entry

# History — write immediately so all terminals share it
PROMPT_COMMAND="history -a; history -c; history -r; ${PROMPT_COMMAND:-}"

# Completion
if [[ -f /usr/share/bash-completion/bash_completion ]]; then
  source /usr/share/bash-completion/bash_completion
elif [[ -f /etc/bash_completion ]]; then
  source /etc/bash_completion
fi

# Homebrew completions (macOS)
if command -v brew &>/dev/null && [[ -d "$(brew --prefix)/etc/bash_completion.d" ]]; then
  for f in "$(brew --prefix)/etc/bash_completion.d"/*; do
    source "$f"
  done
fi

# fzf key bindings
[[ -f ~/.fzf.bash ]] && source ~/.fzf.bash

# Prompt — use starship if available, else a minimal fallback
if command -v starship &>/dev/null; then
  eval "$(starship init bash)"
else
  # minimal two-line prompt: user@host path (git branch)
  _git_branch() { git branch 2>/dev/null | grep '^\*' | cut -c3-; }
  PS1='\[\033[0;32m\]\u@\h\[\033[0m\]:\[\033[0;34m\]\w\[\033[0;33m\]$([[ -n "$(_git_branch)" ]] && echo " ($(_git_branch))")\[\033[0m\]\n\$ '
fi

# Local overrides (machine-specific, not committed)
[[ -f "$HOME/.bashrc.local" ]] && source "$HOME/.bashrc.local"
