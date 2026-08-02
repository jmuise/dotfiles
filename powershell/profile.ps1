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

# ── environment health check ─────────────────────────────────────────────────
# Warns (never blocks) about drift like a placeholder git identity or
# credential forwarding that didn't land - replaces the old pre-commit/
# pre-push hard block (git/identity-guard.sh, now retired) that used to
# refuse the commit outright. Silent when everything looks fine. Also
# callable by hand as `doctor`. Mirrors shell/doctor.sh.
function doctor {
  $issues = 0
  $name = git config user.name 2>$null
  $email = git config user.email 2>$null
  $placeholderNames = '^(Your Name|John Doe|Test|test)$'
  $placeholderEmails = '^(you@example\.com|your\.email@example\.com|user@example\.com|test@example\.com|root@localhost)$'

  if (-not $name -or $name -match $placeholderNames) {
    Write-Host "⚠ git user.name is unset or a placeholder ($(if ($name) { $name } else { '<empty>' })) — commits will misattribute. Fix: git config --global user.name `"Your Actual Name`"" -ForegroundColor Yellow
    $issues++
  }
  if (-not $email -or $email -match $placeholderEmails -or $email -notmatch '@.*\.') {
    Write-Host "⚠ git user.email is unset or a placeholder ($(if ($email) { $email } else { '<empty>' })) — commits will misattribute. Fix: git config --global user.email `"you@yourdomain.com`"" -ForegroundColor Yellow
    $issues++
  }

  $claudeTokenSentinel = Join-Path $env:LOCALAPPDATA "dotfiles\claude-token.configured"
  if ((Test-Path $claudeTokenSentinel) -and -not $env:CLAUDE_CODE_OAUTH_TOKEN) {
    Write-Host "⚠ Claude Code token forwarding is configured but CLAUDE_CODE_OAUTH_TOKEN is unset this session — see secrets/README.md" -ForegroundColor Yellow
    $issues++
  }

  # `gh auth token` is a local read (no network call), same check used above
  # to populate GH_TOKEN - safe to repeat here.
  if (Get-Command gh -ErrorAction SilentlyContinue) {
    $ghToken = gh auth token 2>$null
    if (-not $ghToken) {
      Write-Host "⚠ gh is installed but not authenticated (or its token is unreadable) — run: gh auth login" -ForegroundColor Yellow
      $issues++
    } elseif (-not $env:GH_TOKEN) {
      Write-Host "⚠ gh is authenticated but GH_TOKEN is unset this session — try a fresh shell" -ForegroundColor Yellow
      $issues++
    }
  }

  return $issues
}
$null = doctor

# ── local overrides ───────────────────────────────────────────────────────────
$localProfile = Join-Path (Split-Path $PROFILE) "profile.local.ps1"
if (Test-Path $localProfile) { . $localProfile }
