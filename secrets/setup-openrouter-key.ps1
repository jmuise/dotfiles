# setup-openrouter-key.ps1 - one-time: stores an OpenRouter API key via
# git-credential-manager under a synthetic host, so powershell/profile.ps1
# can export OPENROUTER_API_KEY + routing vars in every new shell without
# the key ever being written into this repo. See ./README.md.
#
# Interactive - run this yourself, it's not called by install.ps1.

$ErrorActionPreference = "Stop"

$HostName = "dotfiles-openrouter.local"
$Username = "openrouter"
$CacheDir = Join-Path $env:LOCALAPPDATA "dotfiles"
$Sentinel = Join-Path $CacheDir "openrouter-token.configured"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Error "git not found."
  exit 1
}

$SecureToken = Read-Host "Paste your OpenRouter API key (blank to abort)" -AsSecureString
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

Write-Host "Stored and verified. Open a new shell - OPENROUTER_API_KEY will be set automatically."
