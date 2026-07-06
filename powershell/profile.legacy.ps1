# profile.ps1 for Windows PowerShell 5.1 (the "Windows PowerShell" shortcut
# built into Windows). The real profile in this repo targets PowerShell 7+,
# so this just hands off to pwsh, keeping the terminal experience the same
# no matter which shortcut you happened to launch.
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
  pwsh
  exit $LASTEXITCODE
}

Write-Host "PowerShell 7 isn't installed — run: winget install --id Microsoft.PowerShell -e" -ForegroundColor Yellow
