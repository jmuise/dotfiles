# PowerShell profile — loaded for every interactive session
# Linked to $PROFILE by install.ps1

# ── imports & modules ─────────────────────────────────────────────────────────
# PSReadLine — better history, syntax highlighting (ships with PS 7+)
if (Get-Module -ListAvailable PSReadLine) {
  Import-Module PSReadLine
  Set-PSReadLineOption -PredictionSource History
  Set-PSReadLineOption -PredictionViewStyle ListView
  Set-PSReadLineOption -EditMode Emacs
  Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
  Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
  Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
}

# posh-git (optional — install with: Install-Module posh-git -Scope CurrentUser)
if (Get-Module -ListAvailable posh-git) { Import-Module posh-git }

# ── environment ───────────────────────────────────────────────────────────────
$env:EDITOR = "code --wait"

# ── aliases ───────────────────────────────────────────────────────────────────
Set-Alias g    git
Set-Alias c    code
Set-Alias which Get-Command

function ll   { eza -la --icons --group-directories-first --git @args 2>$null ?? (Get-ChildItem @args) }
function la   { ll @args }
function lt   { eza --tree --icons -L 2 @args 2>$null }

function ..   { Set-Location .. }
function ...  { Set-Location ..\.. }
function ~    { Set-Location $HOME }

# git shortcuts
function gs   { git status -sb @args }
function ga   { git add @args }
function gaa  { git add --all @args }
function gc   { git commit -m @args }
function gca  { git commit --amend --no-edit @args }
function gp   { git push @args }
function gpf  { git push --force-with-lease @args }
function gl   { git pull @args }
function gco  { git checkout @args }
function gcob { git checkout -b @args }
function glog { git log --oneline --graph --decorate -20 @args }

# docker
function dc   { docker compose @args }
function dcu  { docker compose up -d @args }
function dcd  { docker compose down @args }
function dps  { docker ps --format "table {{.Names}}`t{{.Status}}`t{{.Ports}}" }

function reload  { . $PROFILE }
function path    { $env:PATH -split [IO.Path]::PathSeparator }

# ── prompt ────────────────────────────────────────────────────────────────────
if (Get-Command starship -ErrorAction SilentlyContinue) {
  Invoke-Expression (&starship init powershell)
}

# ── secrets ───────────────────────────────────────────────────────────────────
# See secrets/README.md. Claude Code's token is stored via git-credential-
# manager under a synthetic host (secrets/setup-claude-token.ps1); GH_TOKEN is
# just reused from gh's own already-persisted session. Both are strictly
# no-ops if unconfigured/unauthenticated - never blocks shell startup. The
# sentinel-file check avoids GCM's multi-second network-probe-then-fail path
# that a plain `git credential fill` against an unconfigured host triggers.
$claudeTokenSentinel = Join-Path $env:LOCALAPPDATA "dotfiles\claude-token.configured"
if (-not $env:CLAUDE_CODE_OAUTH_TOKEN -and (Test-Path $claudeTokenSentinel) -and (Get-Command git -ErrorAction SilentlyContinue)) {
  $credInput = "protocol=https`nhost=dotfiles-secrets.local`nusername=claude-code`n"
  $credOutput = $credInput | git credential fill 2>$null
  $passwordLine = $credOutput | Where-Object { $_ -like "password=*" } | Select-Object -First 1
  if ($passwordLine) { $env:CLAUDE_CODE_OAUTH_TOKEN = $passwordLine.Substring(9) }
}

if (-not $env:GH_TOKEN -and (Get-Command gh -ErrorAction SilentlyContinue)) {
  $ghToken = gh auth token 2>$null
  if ($ghToken) { $env:GH_TOKEN = $ghToken }
}

# ── local overrides ───────────────────────────────────────────────────────────
$localProfile = Join-Path (Split-Path $PROFILE) "profile.local.ps1"
if (Test-Path $localProfile) { . $localProfile }
