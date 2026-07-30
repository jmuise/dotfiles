# detect-state.ps1 - dot-sourced by wsl/bootstrap.ps1. Defines Get-WslDebianState,
# which reports one of: NotInstalled | NoDebianDistro | DebianUnprovisioned | Ready
#
# The state machine matters because root-level provisioning (apt install) never
# needs the human-facing first-run username/password wizard, but install.sh and
# the gitconfig migration need the real default user's $HOME - so those only run
# once the distro is fully Ready.

function Invoke-WithTimeout {
  param([int]$Seconds, [scriptblock]$Script)
  $job = Start-Job -ScriptBlock $Script
  $done = Wait-Job $job -Timeout $Seconds
  if (-not $done) {
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return $false
  }
  $result = Receive-Job $job
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  return $result
}

function Get-WslDebianState {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    return "NotInstalled"
  }

  # wsl.exe emits UTF-16LE, which PowerShell capture can turn into strings with
  # embedded NUL bytes between characters - strip them before comparing.
  $rawDistros = (wsl.exe -l -q 2>$null) -split "`r?`n"
  $distros = $rawDistros | ForEach-Object { ($_ -replace "`0", "").Trim() } | Where-Object { $_ }

  if ($distros -notcontains "Debian") {
    return "NoDebianDistro"
  }

  # Root exec bypasses the first-run wizard entirely (auth is controlled by
  # wsl.exe itself, not Linux-side) - if this fails, the distro is broken or
  # still mid-boot, not just "wizard not completed".
  $rootOk = Invoke-WithTimeout -Seconds 15 -Script {
    wsl.exe -d Debian -u root -- true
    $LASTEXITCODE -eq 0
  }
  if (-not $rootOk) {
    return "DebianUnprovisioned"
  }

  # No -u root here - this is the probe that hangs if the human hasn't
  # completed the interactive username/password first-run prompt yet.
  $userOk = Invoke-WithTimeout -Seconds 15 -Script {
    wsl.exe -d Debian -- whoami
    $LASTEXITCODE -eq 0
  }
  if (-not $userOk) {
    return "DebianUnprovisioned"
  }

  return "Ready"
}
