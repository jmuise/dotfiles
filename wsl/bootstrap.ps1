# bootstrap.ps1 - provisions WSL Debian as the primary Windows dev shell.
# Called from install.ps1 unless -SkipWSL is passed.
#
# State machine (see detect-state.ps1): root-level provisioning never needs
# the human-facing first-run wizard, but bootstrap/bootstrap.sh and the
# gitconfig migration need the real default user's $HOME, so those only run
# once the distro is fully Ready.
#
# Package installs (packages/apt.txt) used to happen from here directly.
# That's now Layer 0/1's job: bootstrap/bootstrap.sh installs its own
# prerequisites and hands off to `ansible-playbook provision/site.yml`, which
# reads packages/apt.txt itself (provision/roles/packages). bootstrap.sh
# deliberately does not run install.sh (Layer 2) — see bootstrap/README.md;
# the full Layer 0 -> 1 -> 2 chain living inside bootstrap.sh itself is a
# later phase (dotfiles issue #47). Until then, this script chains the two
# from the Windows side: it runs bootstrap.sh, then — only if that
# succeeded — runs install.sh in the same WSL checkout bootstrap.sh just
# cloned/updated, so a Windows install still ends with dotfiles symlinked.

# -DotfilesProfile: allow-listed via ValidateSet, not free text. Every
# wsl.exe call below that runs a script now uses --exec (see the Assert-
# SafeWslPath / --exec comments further down) specifically so a value
# forwarded into that argument list is run through CommandLineToArgvW and
# exec'd directly, never through '$SHELL -c <joined string>' — so this can
# no longer run as a second command inside WSL the way an unvalidated value
# like 'agentic; curl ... | bash #' could under the old '--' (default-shell)
# invocation. ValidateSet is kept anyway as belt-and-braces defense in depth
# on top of that, in addition to bootstrap.sh's own --profile validation.
# '' is included because this parameter is optional and empty is its unset
# default (bootstrap.sh resolves the profile itself in that case).
param([string]$DotfilesDir, [ValidateSet('', 'bare', 'inline', 'agentic')][string]$DotfilesProfile, [switch]$DryRun)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\detect-state.ps1"

function log  { param($m) Write-Host "  -> $m" }
function warn { param($m) Write-Host "  ! $m" -ForegroundColor Yellow }

# Manual drive-letter translation instead of `wsl.exe wslpath` - wslpath works
# fine, but wsl.exe's argument parser treats a single backslash as an escape
# character, so passing a plain Windows path from PowerShell mangles it
# (`C:\Users\...` arrives as `C:Users...`). Doubling backslashes works too,
# but this is simpler and has no subprocess/quoting surface at all.
function ConvertTo-WslPath {
  param([string]$WindowsPath)
  $drive = $WindowsPath.Substring(0, 1).ToLower()
  $rest = $WindowsPath.Substring(2) -replace '\\', '/'
  return "/mnt/$drive$rest"
}

# Every wsl.exe call below that runs a script uses --exec (-e), not the
# default '--'. Per WSL's own source (WslClient.cpp, WslMain): without
# --exec the remaining command line is joined into one string and handed to
# the Linux side as "$SHELL -c <that string>" — an extra shell parse pass
# that lets shell metacharacters in an interpolated value (;, $(), a
# backtick, a pipe...) run as a second command. With --exec, WSL instead
# calls CommandLineToArgvW on the same raw command-line text and execs the
# result directly — no shell is ever invoked on the Linux side, so those
# characters can't be interpreted, and (because CommandLineToArgvW is the
# same convention PowerShell already used to quote an interpolated argument
# containing a space when it built wsl.exe's command line) an embedded space
# round-trips correctly too, unlike under the old '--' form.
#
# That removes the shell-metacharacter risk, but every path below still
# crosses this process boundary as an interpolated string, so validate it
# first anyway and fail loudly rather than trust that reasoning alone:
# require an absolute POSIX path with no control characters and none of the
# characters that would still be dangerous if something downstream of the
# exec'd program (e.g. a script that re-splits its own arguments, or a value
# that ends up quoted into a git-config file) ever shells out with it.
# Spaces are explicitly allowed — see above.
function Assert-SafeWslPath {
  param([string]$Path, [string]$Name)
  if ($Path -notmatch '^/') {
    throw "Refusing to continue: $Name resolved to '$Path', which is not an absolute POSIX path (must start with '/'). Aborting rather than passing this to wsl.exe."
  }
  if ($Path -match '[\x00-\x1F\x7F"''`$;|&<>()]') {
    throw "Refusing to continue: $Name resolved to '$Path', which contains a control character or a shell metacharacter (quote, backtick, a dollar sign, ;, |, &, <, >, ( or )) not allowed in a path crossing into wsl.exe. Aborting rather than passing this through."
  }
}

$state = Get-WslDebianState

switch ($state) {
  "NotInstalled" {
    warn "wsl.exe not found on this system. Install WSL manually, then re-run install.ps1."
    return
  }
  "NoDebianDistro" {
    if ($DryRun) {
      Write-Host "  would run: wsl --install -d Debian"
      return
    }
    log "Installing Debian via wsl --install -d Debian..."
    wsl.exe --install -d Debian
    warn "Debian install kicked off. Reboot if prompted, complete the Debian username/password setup from the Start menu, then re-run install.ps1."
    return
  }
  "DebianUnprovisioned" {
    warn "Debian is installed but first-run setup isn't complete. Open 'Debian' from the Start menu, finish the username/password prompt, then re-run install.ps1."
    return
  }
}

# state -eq "Ready" from here on
if ($DryRun) {
  Write-Host "  would migrate gitconfig credential, bridge WSL git credentials to Windows Credential Manager, and invoke bootstrap/bootstrap.sh in Debian"
  return
}

$wslDotfiles = ConvertTo-WslPath $DotfilesDir
Assert-SafeWslPath $wslDotfiles '$wslDotfiles (from -DotfilesDir)'
$wslWindowsGitconfigLocal = ConvertTo-WslPath "$HOME\.gitconfig.local"
Assert-SafeWslPath $wslWindowsGitconfigLocal '$wslWindowsGitconfigLocal'

log "Migrating git credential helper (if needed)..."
wsl.exe -d Debian --exec bash "$wslDotfiles/wsl/migrate-gitconfig-credential.sh" "$wslWindowsGitconfigLocal"

log "Bridging WSL git credentials to Windows Credential Manager (if needed)..."
$gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
if ($gitCmd) {
  $gitRoot = Split-Path (Split-Path $gitCmd.Source -Parent) -Parent
  $gcmWindowsPath = Join-Path $gitRoot "mingw64\bin\git-credential-manager.exe"
  if (Test-Path $gcmWindowsPath) {
    $gcmWslPath = ConvertTo-WslPath $gcmWindowsPath
    Assert-SafeWslPath $gcmWslPath '$gcmWslPath'
    # Still passed via a temp file's *content*, not as a wsl.exe argument,
    # even though the call below now uses --exec: the path contains a space
    # ("Program Files"), and the space-mangling this originally worked around
    # was confirmed live against the old '--' (default-shell) form, where the
    # whole command line is re-wrapped in '$SHELL -c "..."' on the Linux
    # side. --exec's CommandLineToArgvW round-trip (see Assert-SafeWslPath
    # above) should preserve an embedded space correctly instead, since
    # that's the same quoting convention PowerShell used to build this
    # argument in the first place — but that isn't verifiable without a real
    # wsl.exe to run it against, so the known-working temp-file indirection
    # stays as the safer choice rather than trading a confirmed fix for an
    # unverified simplification. $env:TEMP has no spaces for a normal user
    # profile, so it's safe as an argument itself.
    $gcmPathFile = Join-Path $env:TEMP "dotfiles-gcm-path.txt"
    Set-Content -Path $gcmPathFile -Value $gcmWslPath -NoNewline -Encoding ascii
    $gcmPathFileWsl = ConvertTo-WslPath $gcmPathFile
    Assert-SafeWslPath $gcmPathFileWsl '$gcmPathFileWsl'
    wsl.exe -d Debian --exec bash "$wslDotfiles/wsl/bridge-gcm.sh" $gcmPathFileWsl
    Remove-Item $gcmPathFile -ErrorAction SilentlyContinue
  } else {
    warn "git-credential-manager.exe not found under $gitRoot - skipping WSL credential bridge."
  }
} else {
  warn "git.exe not found on Windows - skipping WSL credential bridge."
}

# The WSL-native checkout bootstrap.sh clones/fast-forwards (distinct from
# $wslDotfiles above, which is this *Windows* checkout mounted into WSL).
# Resolved once here and passed to bootstrap.sh explicitly via --dest so
# there is exactly one place computing it — the install.sh call below reuses
# the same variable rather than recomputing bootstrap.sh's own "$HOME/dotfiles"
# default, which would silently drift if that default ever changed.
#
# This one query deliberately keeps the default shell ('--', not --exec):
# 'printf %s "$HOME"' is a fixed literal with no interpolated input, so the
# extra '$SHELL -c "..."' parse pass --exec exists to avoid has nothing to
# bite here, and bash -c is the simplest way to have the *Linux* shell
# resolve $HOME (a plain 'bash "$HOME"' argv would just pass the literal
# three characters '$HOME' through unexpanded).
$wslHome = (wsl.exe -d Debian -- bash -c 'printf %s "$HOME"')
$wslBootstrapDest = "$($wslHome.Trim())/dotfiles"

# $wslBootstrapDest is derived from WSL's own $HOME output (a subprocess
# result, not a literal), and it is about to cross into wsl.exe's --exec
# argument list below. Validate it the same way as the other paths above
# before it is used for anything, and fail loudly rather than pass through
# something unexpected.
Assert-SafeWslPath $wslBootstrapDest '$wslBootstrapDest (from WSL $HOME)'

log "Running bootstrap/bootstrap.sh inside WSL..."
# Invoked as a script file with separate arguments, not an inline `bash -lc
# "..."` string, and via --exec rather than the default shell: WSL's own
# source (see the Assert-SafeWslPath comment above) shows that without
# --exec, this whole argument list is re-joined into one string and handed
# to '$SHELL -c "<that string>"' on the Linux side, which is both a second
# shell-metacharacter parse pass over $wslBootstrapDest/$DotfilesProfile and
# (per the bridge-gcm.sh comment above) exactly the mechanism that mangled
# embedded spaces before. --exec avoids both. bootstrap.sh does its own `cd`
# into provision/ before running ansible-playbook, so no `cd` is needed here.
$bootstrapArgs = @("--dest", $wslBootstrapDest)
if ($DotfilesProfile) {
  # Belt-and-braces re-check right at the point this value is threaded into
  # the wsl.exe argument list, in addition to the ValidateSet on the
  # parameter above — this is the actual security boundary, so it should not
  # rely solely on validation attributes staying attached to the parameter
  # declaration.
  if ($DotfilesProfile -notin @('bare', 'inline', 'agentic')) {
    throw "Refusing to continue: -DotfilesProfile '$DotfilesProfile' is not one of bare, inline, agentic."
  }
  $bootstrapArgs += @("--profile", $DotfilesProfile)
}
wsl.exe -d Debian --exec bash "$wslDotfiles/bootstrap/bootstrap.sh" @bootstrapArgs
if ($LASTEXITCODE -ne 0) {
  warn "bootstrap.sh failed (exit $LASTEXITCODE) - aborting; install.sh was NOT run, so dotfiles are not symlinked. Fix the error above, then re-run install.ps1."
  return
}

log "Running install.sh inside the WSL checkout bootstrap.sh just created ($wslBootstrapDest)..."
wsl.exe -d Debian --exec bash "$wslBootstrapDest/install.sh"
if ($LASTEXITCODE -ne 0) {
  warn "install.sh failed (exit $LASTEXITCODE) - continuing anyway, check output above."
}

Write-Host "  Debian WSL bootstrap complete"
