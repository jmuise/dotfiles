# winget-lock.ps1 - (re)generate packages/winget.lock.json from the
# currently *installed* versions of the packages listed in packages/winget.txt.
#
# Run this after adding/removing a package from winget.txt, or right after
# installing packages for the first time, to establish the baseline lock.
# It only touches the working tree - commit the result yourself.

$ErrorActionPreference = "Stop"
$DOTFILES = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$wingetTxt = "$DOTFILES\packages\winget.txt"
$lockPath = "$DOTFILES\packages\winget.lock.json"

$ids = Get-Content $wingetTxt |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ -and $_ -notmatch '^#' }

# winget export's JSON is far more reliable than parsing `winget list`'s
# table output, which wraps/shifts columns depending on console width and
# whether an "Available" column happens to be present.
$exportPath = Join-Path $env:TEMP "winget-export-$([guid]::NewGuid()).json"
winget export -o $exportPath --include-versions --accept-source-agreements | Out-Null
$export = Get-Content $exportPath -Raw | ConvertFrom-Json
Remove-Item $exportPath

$installed = @{}
foreach ($source in $export.Sources) {
  foreach ($pkg in $source.Packages) {
    $installed[$pkg.PackageIdentifier] = $pkg.Version
  }
}

$entries = foreach ($id in $ids) {
  if ($installed.ContainsKey($id)) {
    [PSCustomObject]@{ id = $id; version = $installed[$id] }
  } else {
    Write-Warning "Not installed, skipping: $id"
  }
}

$sorted = $entries | Sort-Object id
if ($sorted.Count -eq 0) {
  "[]" | Set-Content $lockPath -Encoding utf8
} else {
  $sorted | ConvertTo-Json -AsArray | Set-Content $lockPath -Encoding utf8
}

Write-Host "Wrote $($sorted.Count) entries to $lockPath"
