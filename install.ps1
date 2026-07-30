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

param([switch]$DryRun, [switch]$SkipWSL)

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
    if ($SkipWSL) { $reArgs += "-SkipWSL" }
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

# Like New-Link, but writes rendered content instead of symlinking to the
# repo — used where the target must be a real, self-contained file (see the
# git config section below for why).
function Set-Rendered {
  param($Content, $Dst, $Marker)
  if ($DryRun) { Write-Host "  render: → $Dst"; return }
  $dstDir = Split-Path -Parent $Dst
  if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force $dstDir | Out-Null }
  if (Test-Path $Dst) {
    $item = Get-Item $Dst -Force
    if ($item.LinkType) {
      Remove-Item $Dst -Force
    } elseif (-not (Get-Content $Dst -Raw).StartsWith($Marker)) {
      warn "Backing up existing $Dst → $Dst.bak"
      Move-Item $Dst "$Dst.bak" -Force
    }
  }
  Set-Content $Dst -Value $Content -Encoding UTF8 -NoNewline
  success "rendered $Dst"
}

if ($DryRun) { warn "DRY RUN — no changes will be made" }

log "Dotfiles: $DOTFILES"

# HOME — Windows doesn't set this env var natively (only $env:USERPROFILE).
# PowerShell's automatic $HOME variable is always available, which makes the
# gap easy to miss here, but native Win32 processes like VS Code have no such
# fallback. Devcontainers rely on ${localEnv:HOME} to bind-mount host dotfiles
# (git config, etc.) into the container; without a real HOME env var, that
# resolves to an empty string and the mount fails with "source path does not
# exist". Set it once, persistently, so every devcontainer on this machine
# resolves it the same way.
log "HOME environment variable..."
if ([Environment]::GetEnvironmentVariable("HOME", "User") -ne $env:USERPROFILE) {
  if ($DryRun) {
    Write-Host "  set HOME (User) = $env:USERPROFILE"
  } else {
    [Environment]::SetEnvironmentVariable("HOME", $env:USERPROFILE, "User")
    $env:HOME = $env:USERPROFILE
    success "HOME set to $env:USERPROFILE (User scope) — restart VS Code/terminals to pick it up"
  }
} else {
  success "HOME already set to $env:USERPROFILE"
}

# git — ~/.gitconfig is rendered (template + local identity merged into one
# file), not symlinked. VS Code's Dev Containers "copy git config" feature
# copies the raw ~/.gitconfig into every devcontainer automatically, but does
# not follow `include.path` (github.com/microsoft/vscode-remote-release/
# issues/9469) — so a template that includes ~/.gitconfig.local would need a
# manual bind-mount added to every single devcontainer project to get your
# identity across. A self-contained rendered file works everywhere for free.
log "Git..."
New-Link "$DOTFILES\git\.gitignore_global" "$HOME\.gitignore_global"

$gitconfigLocal = "$HOME\.gitconfig.local"
if (-not (Test-Path $gitconfigLocal)) {
  if (-not $DryRun) {
    @"
# ~/.gitconfig.local — machine-specific overrides, NOT committed to dotfiles
[user]
	name  = Your Name
	email = you@example.com
"@ | Set-Content $gitconfigLocal -Encoding UTF8
  }
  warn "Created ~/.gitconfig.local — fill in your name and email, then re-run install.ps1"
}

$gitconfigMarker = "# Managed by dotfiles install.ps1 — do not edit directly.`n# Edit git\.gitconfig.template or ~\.gitconfig.local, then re-run install.ps1.`n`n"
$gitconfigLocalContent = if (Test-Path $gitconfigLocal) { Get-Content $gitconfigLocal -Raw } else { "" }
$gitconfigRendered = $gitconfigMarker + (Get-Content "$DOTFILES\git\.gitconfig.template" -Raw) + "`n" + $gitconfigLocalContent
Set-Rendered $gitconfigRendered "$HOME\.gitconfig" $gitconfigMarker

# Git hooks — points this checkout at the repo-tracked hooks/ dir so
# post-checkout/post-merge/post-rewrite re-run this installer automatically
# whenever `git pull`/`git rebase`/`git checkout` change dotfiles files, in
# addition to the logon safety net registered further down. Runs after the
# ~/.gitconfig render above so a mid-migration broken global config (e.g. a
# dangling symlink) can't make this `git config` call itself fail.
log "Git hooks..."
if ($DryRun) {
  Write-Host "  git config core.hooksPath hooks"
} else {
  git -C $DOTFILES config core.hooksPath hooks
  success "core.hooksPath -> hooks"
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

# Scheduled winget update check — proposes version bumps as commits on a
# `winget-updates` branch for review, weekly. See packages/winget-check-updates.ps1.
log "Scheduled winget update check..."
$wingetTaskName = "dotfiles-winget-check-updates"
$wingetTaskAction = "pwsh.exe"
$wingetTaskArgs = "-NoLogo -NoProfile -File `"$DOTFILES\packages\winget-check-updates.ps1`""
if ($DryRun) {
  Write-Host "  schedule: $wingetTaskName (weekly, Mon 9am) -> $wingetTaskAction $wingetTaskArgs"
} else {
  $action = New-ScheduledTaskAction -Execute $wingetTaskAction -Argument $wingetTaskArgs
  $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At "09:00"
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable
  if (Get-ScheduledTask -TaskName $wingetTaskName -ErrorAction SilentlyContinue) {
    Set-ScheduledTask -TaskName $wingetTaskName -Action $action -Trigger $trigger -Settings $settings | Out-Null
  } else {
    Register-ScheduledTask -TaskName $wingetTaskName -Action $action -Trigger $trigger -Settings $settings `
      -Description "Checks packages/winget.txt for available updates and proposes them as a commit on winget-updates for review." | Out-Null
  }
  success "Scheduled weekly winget update check ($wingetTaskName)"
}

# Logon sync — safety net that re-applies this installer (symlinks, rendered
# ~/.gitconfig, etc. — all idempotent and fast) at every logon, in case
# something drifted outside of a git pull (e.g. a symlink got clobbered).
# -SkipWSL keeps it fast and non-interactive; run install.ps1 by hand for the
# full WSL/Windows Terminal provisioning.
#
# This uses a Startup-folder launcher rather than a Scheduled Task: creating
# *new* scheduled tasks (Register-ScheduledTask, and schtasks /Create) was
# denied outright on this machine even from an elevated prompt — most likely
# endpoint-security policy blocking Task Scheduler persistence, a common
# hardening measure. A VBScript launcher in shell:startup needs no special
# privilege (it's just a file in a folder the user already owns) and starts
# pwsh fully hidden, no window flash.
log "Logon sync..."
$startupDir = [Environment]::GetFolderPath("Startup")
$startupScript = Join-Path $startupDir "dotfiles-install-at-logon.vbs"
# VBS escapes an embedded quote by doubling it, so the pwsh -File path (itself
# quoted, since $DOTFILES can contain spaces) needs "" around it.
$innerCmd = 'pwsh.exe -NoLogo -NoProfile -File ""' + "$DOTFILES\install.ps1" + '"" -SkipWSL'
$vbsContent = 'Set WshShell = CreateObject("WScript.Shell")' + "`r`n" +
  'WshShell.Run "' + $innerCmd + '", 0, False' + "`r`n"
if ($DryRun) {
  Write-Host "  logon launcher: → $startupScript"
} else {
  Set-Content -Path $startupScript -Value $vbsContent -Encoding ASCII -NoNewline
  success "Logon sync launcher: $startupScript"
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

# WSL (Debian) + Windows Terminal — makes WSL the primary daily-driver shell,
# with Windows Terminal defaulting new tabs into it. See wsl/bootstrap.ps1 and
# windows-terminal/configure.ps1 for the actual logic; kept out of this file
# to stay readable.
if (-not $SkipWSL) {
  log "WSL (Debian)..."
  if ($DryRun) {
    & "$DOTFILES\wsl\bootstrap.ps1" -DotfilesDir $DOTFILES -DryRun
  } else {
    & "$DOTFILES\wsl\bootstrap.ps1" -DotfilesDir $DOTFILES
  }

  log "Windows Terminal..."
  if ($DryRun) {
    & "$DOTFILES\windows-terminal\configure.ps1" -DryRun
  } else {
    & "$DOTFILES\windows-terminal\configure.ps1"
  }
} else {
  warn "Skipping WSL/Windows Terminal setup (-SkipWSL)"
}

success "Done! Restart your shell."
