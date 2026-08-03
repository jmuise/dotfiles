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
    $item = Get-Item $Dst -Force
    if ($item.LinkType) {
      Remove-Item $Dst -Force
    } else {
      warn "Backing up existing $Dst → $Dst.bak"
      Move-Item $Dst "$Dst.bak" -Force
    }
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
  # Carry forward a real identity already present in ~/.gitconfig (e.g. a
  # devcontainer-style pre-copy, or .gitconfig.local having been deleted
  # while ~/.gitconfig itself was left alone) instead of stomping it with a
  # placeholder - mirrors install.sh's equivalent check.
  $existingName = if (Test-Path "$HOME\.gitconfig") { git config --file "$HOME\.gitconfig" --get user.name 2>$null } else { $null }
  $existingEmail = if (Test-Path "$HOME\.gitconfig") { git config --file "$HOME\.gitconfig" --get user.email 2>$null } else { $null }
  if ($existingName -and ($existingName -ne "Your Name") -and $existingEmail -and ($existingEmail -ne "you@example.com")) {
    if (-not $DryRun) {
      @"
# ~/.gitconfig.local — machine-specific overrides, NOT committed to dotfiles
[user]
	name  = $existingName
	email = $existingEmail
"@ | Set-Content $gitconfigLocal -Encoding UTF8
    }
    success "Carried forward existing git identity ($existingName <$existingEmail>) into ~/.gitconfig.local"
  } else {
    # No identity to carry forward (e.g. VS Code's devcontainer "copy git
    # config" hasn't run yet at this point in the lifecycle, or never will -
    # see README's Devcontainers section). Leave [user] unset rather than
    # scaffolding a fake-looking "Your Name" - a value that LOOKS like a real
    # identity is worse than none, since the guard hooks below only catch
    # placeholders they know about, but always catch empty.
    if (-not $DryRun) {
      @"
# ~/.gitconfig.local — machine-specific overrides, NOT committed to dotfiles
# No identity could be auto-detected. Fill in your name and email, e.g.:
#[user]
#	name  = Your Name
#	email = you@example.com
"@ | Set-Content $gitconfigLocal -Encoding UTF8
    }
    warn "Created ~/.gitconfig.local with no git identity set — run: git config user.name `"Your Name`" && git config user.email you@example.com (then re-run install.ps1, or edit ~/.gitconfig.local directly). Commits/pushes are blocked until then."
  }
}

$gitconfigMarker = "# Managed by dotfiles install.ps1 — do not edit directly.`n# Edit git\.gitconfig.template or ~\.gitconfig.local, then re-run install.ps1.`n`n"
$gitconfigLocalContent = if (Test-Path $gitconfigLocal) { Get-Content $gitconfigLocal -Raw } else { "" }
$gitconfigRendered = $gitconfigMarker + (Get-Content "$DOTFILES\git\.gitconfig.template" -Raw) + "`n" + $gitconfigLocalContent
Set-Rendered $gitconfigRendered "$HOME\.gitconfig" $gitconfigMarker

# Re-checked every run (not just the block above, which only fires the first
# time the file is created) against the *rendered* ~/.gitconfig - not just
# .gitconfig.local's raw text - so this also catches a literal legacy
# "Your Name" placeholder left over from before this script stopped
# scaffolding one. Placeholder *quality* (as opposed to plain emptiness)
# isn't judged here anymore - powershell/profile.ps1's doctor function flags
# that at shell startup instead of this installer hard-blocking commits on
# it (see memory/project_dotfiles_identity_guard.md for why the old
# hook-based guard was retired).
$effectiveName = git config --file "$HOME\.gitconfig" --get user.name 2>$null
$effectiveEmail = git config --file "$HOME\.gitconfig" --get user.email 2>$null
if ((-not $effectiveName) -or (-not $effectiveEmail)) {
  warn "No git identity set — run: git config user.name `"Your Name`" && git config user.email you@example.com (or edit ~/.gitconfig.local and re-run install.ps1). See powershell/profile.ps1's doctor function for an ongoing reminder."
} else {
  # Push the confirmed-set identity into the same credential-forwarding
  # channel used for the Claude Code token (secrets/README.md), so any
  # devcontainer opened from this Windows host can pull it (install.sh's
  # IDENTITY_HOST check) instead of depending on VS Code's own git-config
  # copy, which doesn't reliably fire - see
  # memory/project_dotfiles_identity_guard.md.
  "protocol=https`nhost=dotfiles-identity.local`nusername=$effectiveName`npassword=$effectiveEmail`n" | git credential approve 2>$null
}

# gh's own token, pushed through the same forwarding channel so a
# devcontainer opened from this Windows host can pull it (install.sh's
# GH_HOST check) - a devcontainer has no persisted `gh auth login` session of
# its own (secrets/README.md's "already handled by OS keyring" claim only
# holds on a machine gh was actually logged into). No-op if gh isn't
# installed/authenticated here yet.
if (Get-Command gh -ErrorAction SilentlyContinue) {
  $ghTokenToPush = gh auth token 2>$null
  if ($ghTokenToPush) {
    "protocol=https`nhost=dotfiles-gh.local`nusername=gh-cli`npassword=$ghTokenToPush`n" | git credential approve 2>$null
    # `approve` reports success even when nothing was actually persisted -
    # confirmed before for the Claude Code token (see
    # memory/project_dotfiles_secrets.md). Read it straight back rather than
    # trusting the exit code.
    $ghCredOutput = "protocol=https`nhost=dotfiles-gh.local`nusername=gh-cli`n" | git credential fill 2>$null
    $ghPasswordLine = $ghCredOutput | Where-Object { $_ -like "password=*" } | Select-Object -First 1
    $ghReadback = if ($ghPasswordLine) { $ghPasswordLine.Substring(9) } else { $null }
    if ($ghReadback -ne $ghTokenToPush) {
      warn "gh token approve reported success but reading it back from credential.helper didn't match - it likely wasn't actually persisted. Run 'git config --get credential.helper' to check. See secrets/README.md."
    }
  }
}

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

# Global identity guard hooks (git/global-hooks/) were retired in favor of
# powershell/profile.ps1's non-blocking doctor function - clean up global
# core.hooksPath if *this* installer was the one who set it, so a machine
# that ran an older version of this script doesn't keep pointing at a
# now-empty directory. Only touches it when the value is exactly ours, same
# never-clobber-a-stranger's-config caution as ensure-gcm.sh.
$existingGlobalHooks = git config --global --get core.hooksPath 2>$null
$globalHooksDir = "$DOTFILES\git\global-hooks"
if ($existingGlobalHooks -eq $globalHooksDir) {
  if ($DryRun) {
    Write-Host "  git config --global --unset core.hooksPath"
  } else {
    git config --global --unset core.hooksPath
    success "Removed global core.hooksPath (identity guard retired in favor of doctor function)"
  }
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

# Winget packages — packages/winget.txt was previously just documentation
# (a comment telling you to run the one-liner yourself) and the scheduled
# check below only proposes *version bumps* for packages already installed,
# so on a fresh machine nothing in the list — including Starship — ever
# actually got installed. Pins to packages/winget.lock.json when an entry
# exists there, so a fresh machine matches the last version
# packages/winget-lock.ps1 captured rather than whatever's newest today;
# unlocked entries (or the file being absent) fall back to latest.
log "Winget packages..."
if (Get-Command winget -ErrorAction SilentlyContinue) {
  $wingetIds = Get-Content "$DOTFILES\packages\winget.txt" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and $_ -notmatch '^#' }
  $wingetLockPath = "$DOTFILES\packages\winget.lock.json"
  $wingetLocked = @{}
  if (Test-Path $wingetLockPath) {
    (Get-Content $wingetLockPath -Raw | ConvertFrom-Json) | ForEach-Object { $wingetLocked[$_.id] = $_.version }
  }
  foreach ($id in $wingetIds) {
    winget list --id $id -e --accept-source-agreements *>$null
    if ($LASTEXITCODE -eq 0) { continue }
    $versionArgs = @()
    if ($wingetLocked.ContainsKey($id)) { $versionArgs = @("-v", $wingetLocked[$id]) }
    if ($DryRun) {
      Write-Host "  winget install --id $id -e $($versionArgs -join ' ')"
    } else {
      winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements @versionArgs | Out-Null
      if ($LASTEXITCODE -eq 0) { success "Installed $id" } else { warn "winget install failed for $id (exit $LASTEXITCODE)" }
    }
  }
} else {
  warn "winget not found — skipping packages/winget.txt install"
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

# Claude Code — global CLAUDE.md, settings, and statusline (behavior
# preferences, not project config). settings.json's statusLine command uses
# a literal "$HOME" in the command string (expanded by whatever shell Claude
# Code spawns it with, not by this script), so the same tracked file works
# unmodified on every machine/user - see install.sh's matching comment.
log "Claude Code global config..."
New-Link "$DOTFILES\claude\CLAUDE.md" "$env:USERPROFILE\.claude\CLAUDE.md"
New-Link "$DOTFILES\claude\settings.json" "$env:USERPROFILE\.claude\settings.json"
New-Link "$DOTFILES\claude\statusline-command.sh" "$env:USERPROFILE\.claude\statusline-command.sh"

# starship
log "Starship..."
$starshipConfig = "$env:USERPROFILE\.config\starship.toml"
New-Link "$DOTFILES\starship\starship.toml" $starshipConfig

# SSH — rendered (template + ~/.ssh/config.local merged), same reasoning as
# ~/.gitconfig above: copy-once meant a bug in the shipped template stayed
# permanently baked into every machine that had already bootstrapped, with
# no way for a later `git pull` to fix it. User hosts/overrides go in
# ~/.ssh/config.local, included before the managed defaults so they take
# precedence (ssh_config is first-obtained-value-wins) - created once here
# and never touched again after that.
log "SSH..."
if (-not $DryRun) { New-Item -ItemType Directory -Force "$HOME\.ssh" | Out-Null }
$sshConfigLocal = "$HOME\.ssh\config.local"
if (-not (Test-Path $sshConfigLocal)) {
  if (-not $DryRun) { Copy-Item "$DOTFILES\ssh\config.local.example" $sshConfigLocal }
  warn "Created ~/.ssh/config.local — add machine-specific hosts there"
}
$sshMarker = "# Managed by dotfiles install.ps1 — do not edit directly.`n# Edit ssh\config.template or ~\.ssh\config.local, then re-run install.ps1.`n`n"
$sshRendered = $sshMarker + "Include ~/.ssh/config.local`n`n" + (Get-Content "$DOTFILES\ssh\config.template" -Raw)
Set-Rendered $sshRendered "$HOME\.ssh\config" $sshMarker

# Lock ~/.ssh down to the current user (+ SYSTEM) only - mirrors install.sh's
# chmod 700/600 (OpenSSH refuses to use a config/key it considers
# world/group-readable). (OI)(CI) on the directory means anything created
# under it later inherits the same restriction; the explicit call on config
# itself covers the file that already existed before inheritance was reset.
# Best-effort - never blocks the rest of the install if icacls fails (e.g. a
# filesystem that doesn't support ACL inheritance removal).
if (-not $DryRun) {
  try {
    icacls "$HOME\.ssh" /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" /grant:r "SYSTEM:(OI)(CI)F" *>$null
    icacls "$HOME\.ssh\config" /inheritance:r /grant:r "$($env:USERNAME):F" /grant:r "SYSTEM:F" *>$null
  } catch {
    warn "Could not lock down ~/.ssh permissions via icacls"
  }
}

# ~/.wslconfig — rendered (template + ~/.wslconfig.local merged), same
# reasoning as ~/.gitconfig/~/.ssh/config above. Applies machine-wide to every
# WSL2 distro (not just Debian), so it's rendered unconditionally, even under
# -SkipWSL. Durable defaults (currently: autoMemoryReclaim, see
# wsl/.wslconfig.template for why) live in the tracked template; per-machine
# tuning (memory/processors, which vary by hardware) lives in
# ~/.wslconfig.local, created once and never touched again after that.
log "WSL config (.wslconfig)..."
$wslconfigLocal = "$HOME\.wslconfig.local"
if (-not (Test-Path $wslconfigLocal)) {
  if (Test-Path "$HOME\.wslconfig") {
    # Carry forward everything except any existing [experimental] block,
    # which the template now owns - keeping both would leave two
    # [experimental] sections in the rendered file with unpredictable
    # last-wins-per-parser behavior between the old and new autoMemoryReclaim
    # values.
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
$wslconfigMarker = "# Managed by dotfiles install.ps1 — do not edit directly.`n# Edit wsl\.wslconfig.template or ~\.wslconfig.local, then re-run install.ps1.`n`n"
$wslconfigLocalContent = if (Test-Path $wslconfigLocal) { (Get-Content $wslconfigLocal -Raw).Trim() } else { "" }
$wslconfigRendered = $wslconfigMarker + $wslconfigLocalContent + "`n`n" + (Get-Content "$DOTFILES\wsl\.wslconfig.template" -Raw)
$wslconfigChanged = (-not (Test-Path "$HOME\.wslconfig")) -or ((Get-Content "$HOME\.wslconfig" -Raw) -ne $wslconfigRendered)
Set-Rendered $wslconfigRendered "$HOME\.wslconfig" $wslconfigMarker
if ($wslconfigChanged -and -not $DryRun) {
  warn "~/.wslconfig changed — run 'wsl --shutdown' once to apply it (stops every running WSL distro, so this is never run for you automatically)"
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
