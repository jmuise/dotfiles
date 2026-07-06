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

# This repo's profile targets PowerShell 7+. Windows PowerShell 5.1 (built
# into every Windows install) can't run it, so hand off to pwsh instead of
# silently half-working. Installs pwsh via winget if it isn't present yet.
if ($PSVersionTable.PSVersion.Major -lt 7) {
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if (-not $pwsh) {
    Write-Host "PowerShell 7 not found — installing via winget..." -ForegroundColor Blue
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      winget install --id Microsoft.PowerShell -e --silent
      $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    }
  }
  if ($pwsh) {
    $reArgs = @()
    if ($DryRun) { $reArgs += "-DryRun" }
    & $pwsh.Source -NoLogo -NoProfile -File $PSCommandPath @reArgs
    exit $LASTEXITCODE
  }
  Write-Host "Could not install PowerShell 7 automatically. Install it manually (winget install --id Microsoft.PowerShell -e) and re-run this script." -ForegroundColor Red
  exit 1
}

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

# PowerShell profile — linked for pwsh (the real profile) and for Windows
# PowerShell 5.1 (a shim that hands off to pwsh), so either shortcut lands
# in the same place.
log "PowerShell profile..."
New-Link "$DOTFILES\powershell\profile.ps1" $PROFILE

$profileFileName = Split-Path -Leaf $PROFILE
$docsDir = Split-Path -Parent (Split-Path -Parent $PROFILE)
$legacyProfile = Join-Path $docsDir "WindowsPowerShell\$profileFileName"
New-Link "$DOTFILES\powershell\profile.legacy.ps1" $legacyProfile

# cmd.exe — doskey macros + prompt via AutoRun, so cmd matches PowerShell/bash
log "cmd.exe..."
if (-not $DryRun) {
  [Environment]::SetEnvironmentVariable("DOTFILES_DIR", $DOTFILES, "User")
}
$cmdInit = "$DOTFILES\cmd\init.cmd"
$autoRunKey = "HKCU:\Software\Microsoft\Command Processor"
$autoRunEntry = "call `"$cmdInit`""
$existingAutoRun = (Get-ItemProperty -Path $autoRunKey -Name AutoRun -ErrorAction SilentlyContinue).AutoRun
if ($existingAutoRun -and $existingAutoRun -notmatch [regex]::Escape($cmdInit)) {
  warn "Existing cmd.exe AutoRun found — appending dotfiles init rather than overwriting"
  $newAutoRun = "$existingAutoRun & $autoRunEntry"
} elseif ($existingAutoRun) {
  $newAutoRun = $existingAutoRun
} else {
  $newAutoRun = $autoRunEntry
}
if ($DryRun) {
  Write-Host "  AutoRun: $newAutoRun"
} else {
  if (-not (Test-Path $autoRunKey)) { New-Item -Path $autoRunKey -Force | Out-Null }
  New-ItemProperty -Path $autoRunKey -Name AutoRun -Value $newAutoRun -PropertyType String -Force | Out-Null
  success "cmd.exe AutoRun configured"
}

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
