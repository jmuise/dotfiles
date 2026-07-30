# configure.ps1 - points Windows Terminal's default profile at Debian WSL,
# without touching the rest of your settings.json (color scheme, opacity,
# keybindings, etc. - all yours, none of it managed by this repo).
#
# This does a surgical JSON patch rather than a full-file symlink (unlike
# vscode/settings.json): Windows Terminal auto-generates a "Debian" profile
# of its own via a dynamic WSL-fragment extension, but that profile's GUID
# is derived per-machine and isn't portable/reproducible across machines, so
# this script adds its own profile entry with a fixed, hardcoded GUID instead
# and points defaultProfile at that one.

param([switch]$DryRun)

$ErrorActionPreference = "Stop"

function log  { param($m) Write-Host "  -> $m" }
function warn { param($m) Write-Host "  ! $m" -ForegroundColor Yellow }

# Generated once with [guid]::NewGuid() - never re-derive this.
$FixedDebianProfileGuid = "{c673155e-bf69-447f-badf-459d2edb3f01}"

function Get-WindowsTerminalSettingsPath {
  $packaged = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
  $unpackaged = "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
  if (Test-Path $packaged) { return $packaged }
  if (Test-Path $unpackaged) { return $unpackaged }
  return $null
}

$path = Get-WindowsTerminalSettingsPath
if (-not $path) {
  warn "Windows Terminal settings.json not found - skipping (is it installed?)"
  return
}

$raw = Get-Content $path -Raw
# Default -Depth of 2 truncates settings.json's nested profile objects -
# explicit high depth is required on both read and write below.
$json = $raw | ConvertFrom-Json -Depth 32

if (-not $json.profiles) {
  warn "Unexpected settings.json shape (no 'profiles' key) - skipping"
  return
}
if (-not $json.profiles.list) {
  $json.profiles | Add-Member -NotePropertyName list -NotePropertyValue @() -Force
}

$changed = $false

$existing = $json.profiles.list | Where-Object { $_.guid -eq $FixedDebianProfileGuid }
if (-not $existing) {
  # Deliberately no "source" key - that's reserved for Windows Terminal's own
  # dynamic per-machine WSL-fragment-extension profiles (the auto-generated
  # "Debian" entry with the non-portable GUID). Hand-authoring a source-based
  # entry risks colliding with or being overwritten by that mechanism.
  $newProfile = [ordered]@{
    guid        = $FixedDebianProfileGuid
    name        = "Debian (dotfiles)"
    commandline = "wsl.exe -d Debian --cd ~"
    hidden      = $false
  }
  $json.profiles.list = @($json.profiles.list) + [PSCustomObject]$newProfile
  $changed = $true
  log "Adding fixed-GUID 'Debian (dotfiles)' Windows Terminal profile"
} else {
  log "'Debian (dotfiles)' profile already present - leaving it as-is"
}

if ($json.defaultProfile -ne $FixedDebianProfileGuid) {
  $json.defaultProfile = $FixedDebianProfileGuid
  $changed = $true
  log "Setting defaultProfile to 'Debian (dotfiles)'"
} else {
  log "defaultProfile already set - nothing to do"
}

if ($changed) {
  if ($DryRun) {
    Write-Host "  would write: $path"
  } else {
    # Accepted caveat: this file is technically JSONC (may contain // comments
    # per WT's schema) - a full parse/round-trip destroys any comments. This
    # file currently has none; not worth a token-preserving patcher for a
    # hypothetical future case.
    $json | ConvertTo-Json -Depth 32 | Set-Content $path -Encoding utf8
    Write-Host "  Windows Terminal configured"
  }
} else {
  Write-Host "  Windows Terminal already configured - nothing to do"
}
