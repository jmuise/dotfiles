# bootstrap.ps1 - provisions WSL Debian as the primary Windows dev shell.
# Called from install.ps1 unless -SkipWSL is passed.
#
# State machine (see detect-state.ps1): root-level provisioning never needs
# the human-facing first-run wizard, but bootstrap/bootstrap.sh and the
# gitconfig migration need the real default user's $HOME, so those only run
# once the distro is fully Ready.
#
# Package installs (packages/apt.txt) and the Layer 2 dotfiles symlinking
# (install.sh) used to happen from here directly. They are now Layer 0/1's
# job: bootstrap/bootstrap.sh installs its own prerequisites and hands off to
# `ansible-playbook provision/site.yml`, which reads packages/apt.txt itself
# (provision/roles/packages). bootstrap.sh deliberately does not run
# install.sh (Layer 2) — see bootstrap/README.md; that wiring is a later
# phase (dotfiles issue #47), so a WSL/Windows box bootstrapped via this path
# does not get its dotfiles symlinked automatically yet. Run `./install.sh`
# by hand inside the WSL checkout bootstrap.sh creates until then.

param([string]$DotfilesDir, [string]$DotfilesProfile, [switch]$DryRun)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\detect-state.ps1"

function log  { param($m) Write-Host "  -> $m" }
function warn { param($m) Write-Host "  ! $m" -ForegroundColor Yellow }

# Manual drive-letter translation instead of `wsl.exe wslpath` - wslpath works
# fine, but wsl.exe's argument parser treats a single backslash as an escape
# character, so passing a plain Windows path from PowerShell mangles it
# (`C:\Users\...` arrives as `C:Users...`). Doubling backslashes works too,
# but this is simpler and has no subprocess/quoting surface at all.
function ConvertTo-WslPath {
  param([string]$WindowsPath)
  $drive = $WindowsPath.Substring(0, 1).ToLower()
  $rest = $WindowsPath.Substring(2) -replace '\\', '/'
  return "/mnt/$drive$rest"
}

$state = Get-WslDebianState

switch ($state) {
  "NotInstalled" {
    warn "wsl.exe not found on this system. Install WSL manually, then re-run install.ps1."
    return
  }
  "NoDebianDistro" {
    if ($DryRun) {
      Write-Host "  would run: wsl --install -d Debian"
      return
    }
    log "Installing Debian via wsl --install -d Debian..."
    wsl.exe --install -d Debian
    warn "Debian install kicked off. Reboot if prompted, complete the Debian username/password setup from the Start menu, then re-run install.ps1."
    return
  }
  "DebianUnprovisioned" {
    warn "Debian is installed but first-run setup isn't complete. Open 'Debian' from the Start menu, finish the username/password prompt, then re-run install.ps1."
    return
  }
}

# state -eq "Ready" from here on
if ($DryRun) {
  Write-Host "  would migrate gitconfig credential, bridge WSL git credentials to Windows Credential Manager, and invoke bootstrap/bootstrap.sh in Debian"
  return
}

$wslDotfiles = ConvertTo-WslPath $DotfilesDir
$wslWindowsGitconfigLocal = ConvertTo-WslPath "$HOME\.gitconfig.local"

log "Migrating git credential helper (if needed)..."
wsl.exe -d Debian -- bash "$wslDotfiles/wsl/migrate-gitconfig-credential.sh" "$wslWindowsGitconfigLocal"

log "Bridging WSL git credentials to Windows Credential Manager (if needed)..."
$gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
if ($gitCmd) {
  $gitRoot = Split-Path (Split-Path $gitCmd.Source -Parent) -Parent
  $gcmWindowsPath = Join-Path $gitRoot "mingw64\bin\git-credential-manager.exe"
  if (Test-Path $gcmWindowsPath) {
    $gcmWslPath = ConvertTo-WslPath $gcmWindowsPath
    # Passed via a temp file's *content*, not as a wsl.exe argument: the
    # path contains a space ("Program Files"), and wsl.exe re-joins and
    # re-parses its arguments through the Linux shell internally, which
    # mangles embedded spaces (confirmed live - it corrupted this into an
    # unparseable git-config value on the first version of this script).
    # $env:TEMP has no spaces for a normal user profile, so it's safe as an
    # argument itself.
    $gcmPathFile = Join-Path $env:TEMP "dotfiles-gcm-path.txt"
    Set-Content -Path $gcmPathFile -Value $gcmWslPath -NoNewline -Encoding ascii
    $gcmPathFileWsl = ConvertTo-WslPath $gcmPathFile
    wsl.exe -d Debian -- bash "$wslDotfiles/wsl/bridge-gcm.sh" $gcmPathFileWsl
    Remove-Item $gcmPathFile -ErrorAction SilentlyContinue
  } else {
    warn "git-credential-manager.exe not found under $gitRoot - skipping WSL credential bridge."
  }
} else {
  warn "git.exe not found on Windows - skipping WSL credential bridge."
}

log "Running bootstrap/bootstrap.sh inside WSL..."
# Invoked as a script file with separate arguments, not an inline `bash -lc
# "..."` string, for the same reason as the (now-removed) apt-install call
# above: wsl.exe re-joins and re-parses its arguments through the default
# shell internally, which can mangle an inline string. bootstrap.sh does its
# own `cd` into provision/ before running ansible-playbook, so no `cd` is
# needed here.
$bootstrapArgs = @()
if ($DotfilesProfile) { $bootstrapArgs += @("--profile", $DotfilesProfile) }
wsl.exe -d Debian -- bash "$wslDotfiles/bootstrap/bootstrap.sh" @bootstrapArgs
if ($LASTEXITCODE -ne 0) {
  warn "bootstrap.sh failed (exit $LASTEXITCODE) - continuing anyway, check output above."
}

Write-Host "  Debian WSL bootstrap complete"
