# PowerShell profile — loaded for every interactive session
# Linked to $PROFILE by install.ps1

# ── imports & modules ─────────────────────────────────────────────────────────
# PSReadLine — better history, syntax highlighting (ships with PS 7+)
if (Get-Module -ListAvailable PSReadLine) {
  Import-Module PSReadLine
  Set-PSReadLineOption -PredictionSource History
  Set-PSReadLineOption -PredictionViewStyle ListView
  Set-PSReadLineOption -EditMode Emacs
  Set-PSReadLineOption -HistorySearchCursorMovesToEnd
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
function gdiff  { git diff @args }
function gstash { git stash push -m @args }
function gpop   { git stash pop @args }

# docker
function dc   { docker compose @args }
function dcu  { docker compose up -d @args }
function dcd  { docker compose down @args }
function dcl  { docker compose logs -f @args }
function dps  { docker ps --format "table {{.Names}}`t{{.Status}}`t{{.Ports}}" }

function reload  { . $PROFILE }
function path    { $env:PATH -split [IO.Path]::PathSeparator }

# ── claude → WSL ──────────────────────────────────────────────────────────────
# The real Claude Code install lives in the WSL distro, so `claude` typed in an
# interactive pwsh session forwards into it. This function is the ONLY forwarding
# mechanism: a windows/claude.cmd on the PATH used to cover cmd.exe and
# profile-less PowerShell, but cmd.exe re-parses a batch file's %* after
# substitution, so a quote or an & in any argument could break out and run
# arbitrary Windows commands — it was removed rather than patched, and must not
# come back. Calling wsl.exe — a real .exe — straight from a function skips cmd
# entirely and forwards every argument verbatim as argv (verified for spaces,
# quotes, &, |, %, !, backslash paths and empty strings). Contexts without this
# profile (raw cmd.exe, `pwsh -NoProfile`) are no longer intercepted at all; see
# README.md.
#
# `bash -lc <script> claude @args` passes the script as a fixed
# constant and every user argument as a positional parameter, so no argument can
# ever be re-parsed as shell syntax. Login shell is used so /etc/profile.d
# applies, but it isn't enough on its own (~/.bashrc returns early when
# non-interactive and ~/.profile is skipped when ~/.bash_profile exists), hence
# the explicit PATH prepend. No --cd is passed: wsl.exe translates the caller's
# cwd itself, including \\wsl.localhost paths, and falls back to the Linux home
# directory when a path has no WSL mapping, whereas an explicit --cd would turn
# that graceful fallback into a hard error.
if (Test-Path "$env:SystemRoot\System32\wsl.exe") {
  function claude {
    $distro = if ($env:CLAUDE_WSL_DISTRO) { $env:CLAUDE_WSL_DISTRO } else { "Debian" }
    $launch = 'PATH=$HOME/.local/bin:$HOME/bin:$PATH; if ! command -v claude >/dev/null 2>&1 && [ -s $HOME/.nvm/nvm.sh ]; then . $HOME/.nvm/nvm.sh >/dev/null 2>&1; fi; command -v claude >/dev/null 2>&1 || { echo claude: Claude Code is not installed in the $WSL_DISTRO_NAME WSL distro. Install it there, then retry. 1>&2; exit 127; }; case $(command -v claude) in /mnt/*) echo claude: only a Windows claude is visible from inside WSL - refusing to recurse. Install Claude Code in the distro. 1>&2; exit 127;; esac; exec claude "$@"'
    & "$env:SystemRoot\System32\wsl.exe" -d $distro -e bash -lc $launch claude @args
  }

  # Same forwarding pattern as claude above — kilo lives in the WSL distro too,
  # so type `kilo` in pwsh and it runs inside WSL. See the comment block above
  # for the security rationale (wsl.exe is a real .exe, arguments are passed
  # verbatim as argv, no cmd.exe re-parsing layer).
  function kilo {
    $distro = if ($env:KILO_WSL_DISTRO) { $env:KILO_WSL_DISTRO } else { "Debian" }
    $launch = 'PATH=$HOME/.local/bin:$HOME/bin:$PATH; if ! command -v kilo >/dev/null 2>&1 && [ -s $HOME/.nvm/nvm.sh ]; then . $HOME/.nvm/nvm.sh >/dev/null 2>&1; fi; command -v kilo >/dev/null 2>&1 || { echo kilo: Kilo Code is not installed in the $WSL_DISTRO_NAME WSL distro. Install it there, then retry. 1>&2; exit 127; }; case $(command -v kilo) in /mnt/*) echo kilo: only a Windows kilo is visible from inside WSL - refusing to recurse. Install Kilo Code in the distro. 1>&2; exit 127;; esac; exec kilo "$@"'
    & "$env:SystemRoot\System32\wsl.exe" -d $distro -e bash -lc $launch kilo @args
  }

  # Same forwarding pattern as claude/kilo above — GitHub Copilot CLI lives in
  # the WSL distro too, so type `copilot` in pwsh and it runs inside WSL. See
  # the comment block above claude for the security rationale (wsl.exe is a
  # real .exe, arguments are passed verbatim as argv, no cmd.exe re-parsing
  # layer).
  function copilot {
    $distro = if ($env:COPILOT_WSL_DISTRO) { $env:COPILOT_WSL_DISTRO } else { "Debian" }
    $launch = 'PATH=$HOME/.local/bin:$HOME/bin:$PATH; if ! command -v copilot >/dev/null 2>&1 && [ -s $HOME/.nvm/nvm.sh ]; then . $HOME/.nvm/nvm.sh >/dev/null 2>&1; fi; command -v copilot >/dev/null 2>&1 || { echo copilot: GitHub Copilot CLI is not installed in the $WSL_DISTRO_NAME WSL distro. Install it there, then retry. 1>&2; exit 127; }; case $(command -v copilot) in /mnt/*) echo copilot: only a Windows copilot is visible from inside WSL - refusing to recurse. Install GitHub Copilot CLI in the distro. 1>&2; exit 127;; esac; exec copilot "$@"'
    & "$env:SystemRoot\System32\wsl.exe" -d $distro -e bash -lc $launch copilot @args
  }

  # Same forwarding pattern as claude/kilo/copilot above — rtk (Rust Token
  # Killer) is installed in the WSL distro by install.py, so type `rtk` in pwsh
  # and it runs inside WSL. See the comment block above claude for the security
  # rationale (wsl.exe is a real .exe, arguments are passed verbatim as argv, no
  # cmd.exe re-parsing layer).
  function rtk {
    $distro = if ($env:RTK_WSL_DISTRO) { $env:RTK_WSL_DISTRO } else { "Debian" }
    $launch = 'PATH=$HOME/.local/bin:$HOME/bin:$PATH; command -v rtk >/dev/null 2>&1 || { echo rtk: rtk is not installed in the $WSL_DISTRO_NAME WSL distro. Run install.py there, then retry. 1>&2; exit 127; }; case $(command -v rtk) in /mnt/*) echo rtk: only a Windows rtk is visible from inside WSL - refusing to recurse. Install rtk in the distro. 1>&2; exit 127;; esac; exec rtk "$@"'
    & "$env:SystemRoot\System32\wsl.exe" -d $distro -e bash -lc $launch rtk @args
  }
}

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
#
# OpenRouter takes precedence over the Claude Pro OAuth path below: when
# configured, ANTHROPIC_API_KEY="" forces Claude Code to use ANTHROPIC_AUTH_TOKEN
# instead of any cached OAuth session. See secrets/setup-openrouter-key.ps1.
$orSentinel = Join-Path $env:LOCALAPPDATA "dotfiles\openrouter-token.configured"
if (-not $env:OPENROUTER_API_KEY -and (Test-Path $orSentinel) -and (Get-Command git -ErrorAction SilentlyContinue)) {
  $credInput = "protocol=https`nhost=dotfiles-openrouter.local`nusername=openrouter`n"
  $credOutput = $credInput | git credential fill 2>$null
  $passwordLine = $credOutput | Where-Object { $_ -like "password=*" } | Select-Object -First 1
  if ($passwordLine) {
    $env:OPENROUTER_API_KEY = $passwordLine.Substring(9)
    $env:ANTHROPIC_BASE_URL = "https://openrouter.ai/api"
    $env:ANTHROPIC_AUTH_TOKEN = $env:OPENROUTER_API_KEY
    $env:ANTHROPIC_API_KEY = ""
  }
}

$claudeTokenSentinel = Join-Path $env:LOCALAPPDATA "dotfiles\claude-token.configured"
if (-not $env:OPENROUTER_API_KEY -and -not $env:CLAUDE_CODE_OAUTH_TOKEN -and (Test-Path $claudeTokenSentinel) -and (Get-Command git -ErrorAction SilentlyContinue)) {
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

  $orSentinel = Join-Path $env:LOCALAPPDATA "dotfiles\openrouter-token.configured"
  if ((Test-Path $orSentinel) -and -not $env:OPENROUTER_API_KEY) {
    Write-Host "⚠ OpenRouter key forwarding is configured but OPENROUTER_API_KEY is unset this session — see secrets/README.md" -ForegroundColor Yellow
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
