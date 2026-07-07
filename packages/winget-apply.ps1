# winget-apply.ps1 - install/upgrade packages so this machine matches the
# pinned versions in packages/winget.lock.json.
#
# Run this after merging `winget-updates` (git merge winget-updates), or any
# time you want your machine synced to the committed lock file.

$ErrorActionPreference = "Stop"
$DOTFILES = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$lockPath = "$DOTFILES\packages\winget.lock.json"

if (-not (Test-Path $lockPath)) {
  Write-Host "No lock file at $lockPath - run winget-lock.ps1 first." -ForegroundColor Yellow
  exit 1
}

$entries = Get-Content $lockPath -Raw | ConvertFrom-Json

$exportPath = Join-Path $env:TEMP "winget-export-$([guid]::NewGuid()).json"
winget export -o $exportPath --accept-source-agreements | Out-Null
$export = Get-Content $exportPath -Raw | ConvertFrom-Json
Remove-Item $exportPath

$installedIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($source in $export.Sources) {
  foreach ($pkg in $source.Packages) {
    $installedIds.Add($pkg.PackageIdentifier) | Out-Null
  }
}

foreach ($entry in $entries) {
  Write-Host "-> $($entry.id) $($entry.version)"
  if ($installedIds.Contains($entry.id)) {
    winget upgrade --id $entry.id --version $entry.version -e --silent --accept-package-agreements --accept-source-agreements
  } else {
    winget install --id $entry.id --version $entry.version -e --silent --accept-package-agreements --accept-source-agreements
  }
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Failed: $($entry.id)"
  }
}
