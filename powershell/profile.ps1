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

# ── local overrides ───────────────────────────────────────────────────────────
$localProfile = Join-Path (Split-Path $PROFILE) "profile.local.ps1"
if (Test-Path $localProfile) { . $localProfile }
