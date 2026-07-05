# =============================================================================
# install.ps1 — dotfiles installer for Windows (PowerShell)
#
# Run from an elevated PowerShell prompt, or enable Developer Mode in
# Windows Settings → System → Developer Mode (allows symlinks without elevation)
#
# Usage:
#   .\install.ps1
#   .\install.ps1 -DryRun
# =============================================================================

param([switch]$DryRun)

$ErrorActionPreference = "Stop"
$DOTFILES = Split-Path -Parent $MyInvocation.MyCommand.Path

function log     { param($m) Write-Host "▶ $m" -ForegroundColor Blue }
function success { param($m) Write-Host "✔ $m" -ForegroundColor Green }
function warn    { param($m) Write-Host "⚠ $m" -ForegroundColor Yellow }

function New-Link {
  param($Src, $Dst)
  $dstDir = Split-Path -Parent $Dst
  if (-not (Test-Path $dstDir)) {
    if (-not $DryRun) { New-Item -ItemType Directory -Force $dstDir | Out-Null }
  }
  if ($DryRun) { Write-Host "  link: $Src → $Dst"; return }
  if (Test-Path $Dst) {
    warn "Backing up existing $Dst → $Dst.bak"
    Move-Item $Dst "$Dst.bak" -Force
  }
  New-Item -ItemType SymbolicLink -Path $Dst -Target $Src -Force | Out-Null
  success "linked $Dst"
}

if ($DryRun) { warn "DRY RUN — no changes will be made" }

log "Dotfiles: $DOTFILES"

# git
log "Git..."
New-Link "$DOTFILES\git\.gitconfig"        "$HOME\.gitconfig"
New-Link "$DOTFILES\git\.gitignore_global" "$HOME\.gitignore_global"

if (-not (Test-Path "$HOME\.gitconfig.local")) {
  if (-not $DryRun) {
    @"
# ~/.gitconfig.local — machine-specific overrides, NOT committed to dotfiles
[user]
	name  = Your Name
	email = you@example.com
"@ | Set-Content "$HOME\.gitconfig.local" -Encoding UTF8
  }
  warn "Created ~/.gitconfig.local — fill in your name and email"
}

# shell
log "Shell..."
New-Link "$DOTFILES\shell\aliases.sh"  "$HOME\.aliases"
New-Link "$DOTFILES\shell\exports.sh"  "$HOME\.exports"

# PowerShell profile
log "PowerShell profile..."
$psProfileDir = Split-Path -Parent $PROFILE
New-Link "$DOTFILES\powershell\profile.ps1" $PROFILE

# VS Code
log "VS Code..."
$vsDir = "$env:APPDATA\Code\User"
New-Link "$DOTFILES\vscode\settings.json"    "$vsDir\settings.json"
New-Link "$DOTFILES\vscode\keybindings.json" "$vsDir\keybindings.json"

# starship
log "Starship..."
$starshipConfig = "$env:USERPROFILE\.config\starship.toml"
New-Link "$DOTFILES\starship\starship.toml" $starshipConfig

# SSH config (template only, never overwrite)
$sshConfig = "$HOME\.ssh\config"
if (-not (Test-Path $sshConfig)) {
  if (-not $DryRun) {
    New-Item -ItemType Directory -Force "$HOME\.ssh" | Out-Null
    Copy-Item "$DOTFILES\ssh\config.example" $sshConfig
    warn "Copied SSH config template to ~/.ssh/config — customize it"
  }
} else {
  warn "~/.ssh/config already exists — skipping (see ssh\config.example)"
}

success "Done! Restart your shell."
