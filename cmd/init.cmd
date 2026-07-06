@echo off
:: init.cmd - loaded automatically for every new cmd.exe session via the
:: AutoRun value at HKCU\Software\Microsoft\Command Processor\AutoRun,
:: which install.ps1 sets to: call "<dotfiles>\cmd\init.cmd"
::
:: Mirrors shell/aliases.sh and powershell/profile.ps1 so cmd behaves the
:: same as bash/zsh/PowerShell. Skipped if cmd is started with /D.

set "EDITOR=code --wait"

:: -- prompt --------------------------------------------------------------
:: cmd has no scripting hooks for a starship-style prompt (that needs Clink -
:: see README). This just colors the path so cmd doesn't look totally bare
:: next to the other shells.
prompt $E[36m$P$E[0m$G$S

:: -- listing (eza if available, else built-ins) ---------------------------
where eza >nul 2>nul
if %errorlevel%==0 (
  doskey ls=eza --icons --group-directories-first $*
  doskey ll=eza -la --icons --group-directories-first --git $*
  doskey la=eza -la --icons --group-directories-first --git $*
  doskey lt=eza --tree --icons -L 2 $*
) else (
  doskey ll=dir /a $*
  doskey la=dir /a $*
)

:: -- cat / grep replacements ------------------------------------------------
where bat >nul 2>nul
if %errorlevel%==0 doskey cat=bat --style=plain $*

where rg >nul 2>nul
if %errorlevel%==0 doskey grep=rg $*

:: -- navigation ------------------------------------------------------------
doskey ..=cd ..
doskey ...=cd ..\..
doskey ~=cd /d %USERPROFILE%

:: -- git ---------------------------------------------------------------
doskey g=git $*
doskey gs=git status -sb $*
doskey ga=git add $*
doskey gaa=git add --all $*
doskey gc=git commit -m $*
doskey gca=git commit --amend --no-edit $*
doskey gp=git push $*
doskey gpf=git push --force-with-lease $*
doskey gl=git pull $*
doskey gco=git checkout $*
doskey gcob=git checkout -b $*
doskey glog=git log --oneline --graph --decorate -20 $*
doskey gdiff=git diff $*
doskey gstash=git stash push -m $*
doskey gpop=git stash pop $*

:: -- docker --------------------------------------------------------------
doskey dc=docker compose $*
doskey dcu=docker compose up -d $*
doskey dcd=docker compose down $*
doskey dcl=docker compose logs -f $*
doskey dps=docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

:: -- editor / misc ---------------------------------------------------------
doskey c=code $*
doskey c.=code .
if defined DOTFILES_DIR doskey reload=call "%DOTFILES_DIR%\cmd\init.cmd"
doskey dotfiles=cd /d %DOTFILES_DIR% ^& code .
