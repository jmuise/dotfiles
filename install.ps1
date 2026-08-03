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
    if ($DryRun)  { $reArgs += "-DryRun" }
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

# Thin helper used only for Windows-only links below (shared link logic lives
# in install.py, called further down).
function New-Link {
  param($Src, $Dst)
  $dstDir = Split-Path -Parent $Dst
  if (-not (Test-Path $dstDir)) {
    if (-not $DryRun) { New-Item -ItemType Directory -Force $dstDir | Out-Null }
  }
  if ($DryRun) { Write-Host "  link: $Src → $Dst"; return }
  if (Test-Path $Dst) {
    $item = Get-Item $Dst -Force
    if ($item.LinkType) { Remove-Item $Dst -Force }
    else { warn "Backing up existing $Dst → $Dst.bak"; Move-Item $Dst "$Dst.bak" -Force }
  }
  New-Item -ItemType SymbolicLink -Path $Dst -Target $Src -Force | Out-Null
  success "linked $Dst"
}

function Set-Rendered {
  param($Content, $Dst, $Marker)
  if ($DryRun) { Write-Host "  render: → $Dst"; return }
  $dstDir = Split-Path -Parent $Dst
  if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force $dstDir | Out-Null }
  if (Test-Path $Dst) {
    $item = Get-Item $Dst -Force
    if ($item.LinkType) { Remove-Item $Dst -Force }
    elseif (-not (Get-Content $Dst -Raw).StartsWith($Marker)) {
      warn "Backing up existing $Dst → $Dst.bak"; Move-Item $Dst "$Dst.bak" -Force
    }
  }
  Set-Content $Dst -Value $Content -Encoding UTF8 -NoNewline
  success "rendered $Dst"
}

if ($DryRun) { warn "DRY RUN — no changes will be made" }

log "Dotfiles: $DOTFILES"

# HOME — Windows doesn't set this env var natively (only $env:USERPROFILE).
# Devcontainers rely on ${localEnv:HOME} to bind-mount host dotfiles into the
# container; without a real HOME env var that resolves to an empty string and
# the mount fails. Set it once, persistently, before calling Python so that
# Path.home() and any child processes see the correct value.
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

# Scoop — bootstrapped here, early, so its Python can be used for install.py
# below. Scoop requires no admin and installs to ~/scoop. The full package list
# (buckets + remaining packages from scoop.txt) is applied further down after
# the PS profile and cmd.exe sections.
log "Scoop (bootstrap)..."
# Ensure ~/scoop/shims is on the current session's PATH. The Scoop installer
# updates the user PATH registry entry, but that doesn't retroactively update
# $env:PATH in an already-running shell — so Get-Command scoop fails on the
# second run in the same session even though Scoop is fully installed.
$scoopShims = "$HOME\scoop\shims"
if ((Test-Path $scoopShims) -and $env:PATH -notlike "*$scoopShims*") {
  $env:PATH = "$scoopShims;$env:PATH"
}
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
  if ($DryRun) {
    Write-Host "  would install Scoop to $HOME\scoop"
  } else {
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Invoke-RestMethod get.scoop.sh | Invoke-Expression
  }
}

# Python — resolved by explicit path, not Get-Command. The Microsoft Store App
# Execution Alias stub writes to the console via Win32 WriteConsole (bypassing
# PowerShell's *>$null redirect) and Get-Command can cache the stub even after
# Scoop's shim exists on PATH. Probe candidate paths in priority order so the
# stub is never in the picture.
function Find-ScoopPython {
  @(
    "$HOME\scoop\apps\python\current\python.exe",  # actual install (most reliable)
    "$scoopShims\python.exe",                       # shim (standard name)
    "$scoopShims\python3.exe"                       # shim (alternate name)
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}

$pyPath = Find-ScoopPython
if (-not $pyPath) {
  if ($DryRun) {
    Write-Host "  scoop install python"
    $pyPath = "$HOME\scoop\apps\python\current\python.exe"
  } elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
    log "Installing Python via Scoop..."
    scoop install python
    $pyPath = Find-ScoopPython
  }
}
if (-not $pyPath) {
  Write-Host "Could not find or install Python. Run 'scoop install python' and re-run install.ps1." -ForegroundColor Red
  exit 1
}

# ── cross-platform install (shared logic) ─────────────────────────────────────
$pyArgs = @("$DOTFILES\install.py")
if ($DryRun) { $pyArgs += "--dry-run" }
& $pyPath @pyArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# ── PowerShell profile ────────────────────────────────────────────────────────
log "PowerShell profile..."
New-Link "$DOTFILES\powershell\profile.ps1" $PROFILE

$profileFileName = Split-Path -Leaf $PROFILE
$docsDir         = Split-Path -Parent (Split-Path -Parent $PROFILE)
$legacyProfile   = Join-Path $docsDir "WindowsPowerShell\$profileFileName"
New-Link "$DOTFILES\powershell\profile.legacy.ps1" $legacyProfile

# cmd.exe — doskey macros + prompt via AutoRun, so cmd matches PowerShell/bash
log "cmd.exe..."
if (-not $DryRun) {
  [Environment]::SetEnvironmentVariable("DOTFILES_DIR", $DOTFILES, "User")
}
$cmdInit       = "$DOTFILES\cmd\init.cmd"
$autoRunKey    = "HKCU:\Software\Microsoft\Command Processor"
$autoRunEntry  = "call `"$cmdInit`""
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

# Scoop packages — Scoop was bootstrapped and Python installed earlier; now
# apply buckets and the full package list. See packages/scoop.txt.
log "Scoop packages..."
if (Get-Command scoop -ErrorAction SilentlyContinue) {
  $scoopEntries = Get-Content "$DOTFILES\packages\scoop.txt" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and $_ -notmatch '^#' }

  # Add any non-main buckets referenced in scoop.txt
  $bucketsDir = "$HOME\scoop\buckets"
  $installedBuckets = if (Test-Path $bucketsDir) {
    Get-ChildItem $bucketsDir -Directory | Select-Object -ExpandProperty Name
  } else { @() }
  $bucketsNeeded = $scoopEntries |
    Where-Object { $_ -match '/' } |
    ForEach-Object { ($_ -split '/')[0] } |
    Sort-Object -Unique |
    Where-Object { $_ -ne 'main' -and $installedBuckets -notcontains $_ }
  foreach ($bucket in $bucketsNeeded) {
    if ($DryRun) { Write-Host "  scoop bucket add $bucket" }
    else {
      scoop bucket add $bucket *>$null
      success "Scoop bucket added: $bucket"
    }
  }

  # Install packages (scoop is idempotent — exits 0 if already installed)
  foreach ($entry in $scoopEntries) {
    $pkgName = if ($entry -match '/') { ($entry -split '/')[1] } else { $entry }
    if ($DryRun) { Write-Host "  scoop install $entry" }
    else {
      scoop install $entry *>$null
      if ($LASTEXITCODE -eq 0) { success "Scoop: $pkgName" }
      else { warn "scoop install failed for $entry (exit $LASTEXITCODE)" }
    }
  }
} else {
  warn "scoop not available — skipping packages/scoop.txt"
}

# Winget packages — now just system-level installs that need OS integration
# (currently only Docker Desktop). Developer tools moved to Scoop above.
log "Winget packages..."
if (Get-Command winget -ErrorAction SilentlyContinue) {
  $wingetIds = Get-Content "$DOTFILES\packages\winget.txt" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and $_ -notmatch '^#' }
  foreach ($id in $wingetIds) {
    winget list --id $id -e --accept-source-agreements *>$null
    if ($LASTEXITCODE -eq 0) { continue }
    if ($DryRun) { Write-Host "  winget install --id $id -e" }
    else {
      winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
      if ($LASTEXITCODE -eq 0) { success "Installed $id" } else { warn "winget install failed for $id (exit $LASTEXITCODE)" }
    }
  }
} else {
  warn "winget not found — skipping packages/winget.txt install"
}

# Scheduled winget update check — was registered by earlier versions of this
# script when winget.txt covered all packages. Now that developer tools live
# in Scoop (updated via `scoop update *`), the task is unnecessary. Remove it
# if it's still registered from a previous run.
$wingetTaskName = "dotfiles-winget-check-updates"
if (-not $DryRun -and (Get-ScheduledTask -TaskName $wingetTaskName -ErrorAction SilentlyContinue)) {
  Unregister-ScheduledTask -TaskName $wingetTaskName -Confirm:$false
  success "Removed stale scheduled task: $wingetTaskName (winget update check retired — use 'scoop update *' instead)"
}

# Logon sync — safety net that re-applies this installer at every logon in
# case something drifted outside of a git pull. Uses a Startup-folder VBS
# launcher rather than a Scheduled Task because Register-ScheduledTask is
# denied by endpoint-security policy on this machine even from an elevated
# prompt. VBS in shell:startup needs no special privilege. -SkipWSL keeps it
# fast and non-interactive.
log "Logon sync..."
$startupDir    = [Environment]::GetFolderPath("Startup")
$startupScript = Join-Path $startupDir "dotfiles-install-at-logon.vbs"
$innerCmd      = 'pwsh.exe -NoLogo -NoProfile -File ""' + "$DOTFILES\install.ps1" + '"" -SkipWSL'
$vbsContent    = 'Set WshShell = CreateObject("WScript.Shell")' + "`r`n" +
                 'WshShell.Run "' + $innerCmd + '", 0, False' + "`r`n"
if ($DryRun) {
  Write-Host "  logon launcher: → $startupScript"
} else {
  Set-Content -Path $startupScript -Value $vbsContent -Encoding ASCII -NoNewline
  success "Logon sync launcher: $startupScript"
}

# SSH — icacls permissions (mirrors install.py's chmod 700/600 for Unix;
# OpenSSH refuses to use a config/key it considers world/group-readable).
# Best-effort — never blocks the rest of the install if icacls fails.
if (-not $DryRun) {
  try {
    icacls "$HOME\.ssh" /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" /grant:r "SYSTEM:(OI)(CI)F" *>$null
    icacls "$HOME\.ssh\config" /inheritance:r /grant:r "$($env:USERNAME):F" /grant:r "SYSTEM:F" *>$null
  } catch {
    warn "Could not lock down ~/.ssh permissions via icacls"
  }
}

# ~/.wslconfig — rendered (template + ~/.wslconfig.local merged). Applies
# machine-wide to every WSL2 distro so rendered unconditionally, even under
# -SkipWSL. Durable defaults live in the tracked template; per-machine tuning
# (memory/processors) lives in ~/.wslconfig.local.
log "WSL config (.wslconfig)..."
$wslconfigLocal = "$HOME\.wslconfig.local"
if (-not (Test-Path $wslconfigLocal)) {
  if (Test-Path "$HOME\.wslconfig") {
    # Carry forward everything except any existing [experimental] block, which
    # the template now owns — keeping both would leave two [experimental]
    # sections with unpredictable last-wins-per-parser behavior.
    $lines = (Get-Content "$HOME\.wslconfig" -Raw) -split "`r?`n"
    $carried = New-Object System.Collections.Generic.List[string]
    $inExperimental = $false
    foreach ($line in $lines) {
      if ($line -match '^\s*\[(.+?)\]\s*$') { $inExperimental = ($matches[1] -eq "experimental") }
      if (-not $inExperimental) { $carried.Add($line) }
    }
    if (-not $DryRun) { Set-Content $wslconfigLocal -Value ($carried -join "`n").Trim() -Encoding UTF8 }
    success "Carried forward existing ~/.wslconfig into ~/.wslconfig.local (dropped its [experimental] block, now managed by wsl/.wslconfig.template)"
  } else {
    if (-not $DryRun) { Copy-Item "$DOTFILES\wsl\.wslconfig.local.example" $wslconfigLocal }
    warn "Created ~/.wslconfig.local — add machine-specific memory/processors there if needed"
  }
}
$wslconfigMarker       = "# Managed by dotfiles install.ps1 — do not edit directly.`n# Edit wsl\.wslconfig.template or ~\.wslconfig.local, then re-run install.ps1.`n`n"
$wslconfigLocalContent = if (Test-Path $wslconfigLocal) { (Get-Content $wslconfigLocal -Raw).Trim() } else { "" }
$wslconfigRendered     = $wslconfigMarker + $wslconfigLocalContent + "`n`n" + (Get-Content "$DOTFILES\wsl\.wslconfig.template" -Raw)
$wslconfigChanged      = (-not (Test-Path "$HOME\.wslconfig")) -or ((Get-Content "$HOME\.wslconfig" -Raw) -ne $wslconfigRendered)
Set-Rendered $wslconfigRendered "$HOME\.wslconfig" $wslconfigMarker
if ($wslconfigChanged -and -not $DryRun) {
  warn "~/.wslconfig changed — run 'wsl --shutdown' once to apply it (stops every running WSL distro, so this is never run for you automatically)"
}

# WSL (Debian) + Windows Terminal
if (-not $SkipWSL) {
  log "WSL (Debian)..."
  if ($DryRun) { & "$DOTFILES\wsl\bootstrap.ps1" -DotfilesDir $DOTFILES -DryRun }
  else         { & "$DOTFILES\wsl\bootstrap.ps1" -DotfilesDir $DOTFILES }

  log "Windows Terminal..."
  if ($DryRun) { & "$DOTFILES\windows-terminal\configure.ps1" -DryRun }
  else         { & "$DOTFILES\windows-terminal\configure.ps1" }
} else {
  warn "Skipping WSL/Windows Terminal setup (-SkipWSL)"
}

success "Done! Restart your shell."
