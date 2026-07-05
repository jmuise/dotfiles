#!/usr/bin/env bash
# macos/defaults.sh — sensible macOS system defaults
# Run manually or via install.sh on macOS

set -euo pipefail

echo "Applying macOS defaults..."

# Close System Preferences first to prevent override
osascript -e 'tell application "System Preferences" to quit' 2>/dev/null || true

# ── Finder ────────────────────────────────────────────────────────────────────
defaults write com.apple.finder ShowPathbar        -bool true
defaults write com.apple.finder ShowStatusBar      -bool true
defaults write com.apple.finder AppleShowAllFiles  -bool true  # show hidden files
defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"  # list view
defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"  # search current folder
defaults write NSGlobalDomain  AppleShowAllExtensions -bool true
# Disable .DS_Store on network/USB
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores     -bool true

# ── Dock ──────────────────────────────────────────────────────────────────────
defaults write com.apple.dock autohide       -bool true
defaults write com.apple.dock autohide-delay -float 0.1
defaults write com.apple.dock tilesize       -int 48
defaults write com.apple.dock show-recents   -bool false

# ── Keyboard ──────────────────────────────────────────────────────────────────
defaults write NSGlobalDomain KeyRepeat         -int 2
defaults write NSGlobalDomain InitialKeyRepeat  -int 15
defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false  # key repeat > accent popup

# ── Trackpad ──────────────────────────────────────────────────────────────────
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false  # natural scroll off

# ── Screenshots ───────────────────────────────────────────────────────────────
defaults write com.apple.screencapture location -string "$HOME/Desktop"
defaults write com.apple.screencapture type     -string "png"
defaults write com.apple.screencapture disable-shadow -bool true

# ── Safari (dev) ──────────────────────────────────────────────────────────────
defaults write com.apple.Safari IncludeDevelopMenu -bool true

# ── Activity Monitor ──────────────────────────────────────────────────────────
defaults write com.apple.ActivityMonitor OpenMainWindow    -bool true
defaults write com.apple.ActivityMonitor ShowCategory      -int 0  # all processes

# Restart affected apps
for app in Finder Dock SystemUIServer; do
  killall "$app" 2>/dev/null || true
done

echo "Done. Some changes require a logout/restart."
