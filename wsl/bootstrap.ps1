# bootstrap.ps1 - provisions WSL Debian as the primary Windows dev shell.
# Called from install.ps1 unless -SkipWSL is passed.
#
# State machine (see detect-state.ps1): root-level provisioning (apt install)
# never needs the human-facing first-run wizard, but install.sh and the
# gitconfig migration need the real default user's $HOME, so those only run
# once the distro is fully Ready.

param([string]$DotfilesDir, [switch]$DryRun)

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
  Write-Host "  would install packages/apt.txt, migrate gitconfig credential, bridge WSL git credentials to Windows Credential Manager, and run install.sh in Debian"
  return
}

$wslDotfiles = ConvertTo-WslPath $DotfilesDir
$wslWindowsGitconfigLocal = ConvertTo-WslPath "$HOME\.gitconfig.local"

log "Installing apt packages in Debian..."
# Invoked as a script file, not an inline `bash -lc "..."` string: wsl.exe
# re-joins and re-parses its arguments through the default shell internally,
# so a literal `$` in an inline string gets expanded a second time (by the
# wrong shell context) before the intended script ever runs - silently
# swallowing every `$pkg` reference. A file path has nothing for that second
# pass to mangle. (install-apt-packages.sh itself also pre-filters to names
# that actually resolve, so one bad entry in apt.txt can't abort every
# package - that's what happened with a stale "docker-compose-v2" entry.)
$aptIds = Get-Content "$DotfilesDir\packages\apt.txt" |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ -and $_ -notmatch '^#' }
wsl.exe -d Debian -u root -- bash "$wslDotfiles/wsl/install-apt-packages.sh" @aptIds
if ($LASTEXITCODE -ne 0) {
  warn "apt install failed (exit $LASTEXITCODE) - continuing anyway, check output above."
}

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

log "Running install.sh inside WSL..."
wsl.exe -d Debian -- bash -lc "cd '$wslDotfiles' && ./install.sh"

Write-Host "  Debian WSL bootstrap complete"
