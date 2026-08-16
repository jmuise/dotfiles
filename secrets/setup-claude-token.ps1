# setup-claude-token.ps1 - one-time: generates a long-lived Claude Code OAuth
# token and stores it via git-credential-manager under a synthetic host, so
# powershell/profile.ps1 can set CLAUDE_CODE_OAUTH_TOKEN in every new shell
# without the token ever being written into this repo. See ./README.md.
#
# Interactive - run this yourself, it's not called by install.ps1. Not piped
# through `claude setup-token`: its exact stdout format (token-only vs mixed
# with prompts) isn't documented, so this lets it run against a real console
# and has you paste the printed token back, rather than risk silently storing
# the wrong thing.

$ErrorActionPreference = "Stop"

$HostName = "dotfiles-secrets.local"
$Username = "claude-code"
$CacheDir = Join-Path $env:LOCALAPPDATA "dotfiles"
$Sentinel = Join-Path $CacheDir "claude-token.configured"

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Error "claude CLI not found - install Claude Code first."
  exit 1
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Error "git not found."
  exit 1
}

Write-Host "Running 'claude setup-token' - complete the browser/code flow, then copy the token it prints."
Write-Host ""
claude setup-token
Write-Host ""
$SecureToken = Read-Host "Paste the token printed above to store it (blank to abort)" -AsSecureString
$BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken)
try {
  $Token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}
if ([string]::IsNullOrWhiteSpace($Token)) {
  Write-Host "Aborted - nothing stored."
  exit 1
}

Write-Host ""
Write-Host "About to store this value under git-credential-manager (host=$HostName):"
$prefixLen = [Math]::Min(12, $Token.Length)
$suffixStart = [Math]::Max(0, $Token.Length - 4)
Write-Host "  $($Token.Substring(0, $prefixLen))...$($Token.Substring($suffixStart)) ($($Token.Length) chars)"
$Confirm = Read-Host "Store it? [y/N]"
if ($Confirm -notmatch '^[Yy]$') {
  Write-Host "Aborted - nothing stored."
  exit 1
}

$credInput = "protocol=https`nhost=$HostName`nusername=$Username`npassword=$Token`n"
$credInput | git credential approve

# `approve` reports success even when nothing was actually persisted (e.g.
# no credential.helper configured, or a broken one) - confirmed live, it
# exits 0 regardless. Read it straight back before trusting it worked.
$fillInput = "protocol=https`nhost=$HostName`nusername=$Username`n"
$fillOutput = $fillInput | git credential fill 2>$null
$passwordLine = $fillOutput | Where-Object { $_ -like "password=*" } | Select-Object -First 1
$readback = if ($passwordLine) { $passwordLine.Substring(9) } else { $null }
if ($readback -ne $Token) {
  Write-Host "Stored, but reading it back didn't return the same value - something's" -ForegroundColor Red
  Write-Host "wrong with your credential.helper. Not writing the sentinel file; see" -ForegroundColor Red
  Write-Host "secrets/README.md. Run 'git config --get credential.helper' to check." -ForegroundColor Red
  exit 1
}

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
New-Item -ItemType File -Force -Path $Sentinel | Out-Null

Write-Host "Stored and verified. Open a new shell - CLAUDE_CODE_OAUTH_TOKEN will be set automatically."
