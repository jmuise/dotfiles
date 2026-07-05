# .zprofile — zsh login shell config
# Runs before .zshrc for login shells (SSH, macOS Terminal)

# Homebrew needs to be in PATH before anything else
if [[ -x "/opt/homebrew/bin/brew" ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

[[ -f "$HOME/.zshrc" ]] && source "$HOME/.zshrc"
