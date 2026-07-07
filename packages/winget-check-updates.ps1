# winget-check-updates.ps1 - scheduled weekly (via Task Scheduler, wired up
# by install.ps1) to check for newer versions of the packages listed in
# packages/winget.txt.
#
# If newer versions are available, commits an updated packages/winget.lock.json
# to a `winget-updates` branch for review - it never touches your working
# tree, index, or whatever branch you currently have checked out. Safe to
# run in the background at any time.
#
# Review with:  git log winget-updates -p
# Accept with:  git merge winget-updates   (then run packages/winget-apply.ps1)

$ErrorActionPreference = "Stop"
$DOTFILES = if ($env:DOTFILES_DIR) { $env:DOTFILES_DIR } else { Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$baseBranch = "main"
$updateBranch = "winget-updates"
$lockRelPath = "packages/winget.lock.json"

$env:GIT_DIR = "$DOTFILES\.git"
$tempIndex = Join-Path $env:TEMP "winget-updates-$([guid]::NewGuid()).index"
$env:GIT_INDEX_FILE = $tempIndex

try {
  # curated package list - read from the working tree, since that's what
  # you actually edit when adding/removing a package
  $ids = Get-Content "$DOTFILES\packages\winget.txt" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and $_ -notmatch '^#' }

  # latest version available in the winget repo for each package (not what's
  # installed locally - this is what proposes the update)
  $latest = foreach ($id in $ids) {
    $show = winget show --id $id -e 2>$null
    $versionLine = $show | Select-String '^Version:\s*(.+)$'
    if ($versionLine) {
      [PSCustomObject]@{ id = $id; version = $versionLine.Matches[0].Groups[1].Value.Trim() }
    } else {
      Write-Warning "Could not look up: $id"
    }
  }
  $latest = $latest | Sort-Object id
  $newLockJson = if ($latest.Count -eq 0) { "[]" } else { $latest | ConvertTo-Json -AsArray }

  # compare against whatever's already committed - prefer the winget-updates
  # branch if one exists (so repeated runs diff against the last proposal,
  # not re-propose the same thing against main), else fall back to main
  git rev-parse --verify --quiet "refs/heads/$updateBranch" | Out-Null
  $refForCurrent = if ($LASTEXITCODE -eq 0) { $updateBranch } else { $baseBranch }

  $currentLockJson = git show "${refForCurrent}:$lockRelPath" 2>$null
  if ($LASTEXITCODE -ne 0) { $currentLockJson = "[]" }

  # compare parsed values, not raw text - ConvertTo-Json emits CRLF on
  # Windows while `git show` returns whatever line endings are committed
  # (LF, after autocrlf normalization), so a text comparison never matches
  # even when the data is identical.
  $currentEntries = @(try { $currentLockJson | ConvertFrom-Json } catch { @() }) | Sort-Object id
  $latestSorted = @($latest) | Sort-Object id

  $changes = foreach ($n in $latestSorted) {
    $old = $currentEntries | Where-Object { $_.id -eq $n.id }
    if (-not $old) {
      "$($n.id): (new) -> $($n.version)"
    } elseif ($old.version -ne $n.version) {
      "$($n.id): $($old.version) -> $($n.version)"
    }
  }
  $changes += foreach ($old in $currentEntries) {
    if (-not ($latestSorted | Where-Object { $_.id -eq $old.id })) {
      "$($old.id): $($old.version) -> (removed from winget.txt)"
    }
  }

  if ($changes.Count -eq 0) {
    Write-Host "No winget updates found."
    return
  }

  $summary = $changes -join "`n"
  Write-Host "Proposing winget updates:`n$summary"

  # commit the new lock file onto $updateBranch via plumbing, without ever
  # touching the working tree or checked-out branch
  $parentSha = git rev-parse $refForCurrent
  git read-tree $parentSha

  $tempFile = Join-Path $env:TEMP "winget-lock-$([guid]::NewGuid()).json"
  Set-Content -Path $tempFile -Value $newLockJson -Encoding utf8 -NoNewline
  $blobSha = git hash-object -w $tempFile
  Remove-Item $tempFile

  git update-index --add --cacheinfo "100644,$blobSha,$lockRelPath"
  $treeSha = git write-tree
  $commitMessage = "chore: winget updates available`n`n$summary"
  $commitSha = git commit-tree $treeSha -p $parentSha -m $commitMessage
  git update-ref "refs/heads/$updateBranch" $commitSha

  Write-Host "Committed to $updateBranch ($commitSha)"
}
finally {
  Remove-Item Env:\GIT_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue
  Remove-Item $tempIndex -ErrorAction SilentlyContinue
}
