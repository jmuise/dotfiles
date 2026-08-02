# self-heal.sh — periodically re-applies install.sh so drift (a clobbered
# symlink, a stale rendered ~/.gitconfig, a template bugfix that landed
# upstream) self-corrects without a manual re-run or a git operation in this
# checkout. install.ps1 gets this for free on Windows from a Startup-folder
# launcher that fires every logon (see its "Logon sync" section); POSIX has
# no single universal login event that covers desktop terminals, SSH
# sessions, WSL, and devcontainers alike, so this runs from every
# interactive shell startup instead, gated by a once-a-day timestamp
# sentinel so it costs one stat+read on the other 99% of shells. Runs in the
# background so a slow step (e.g. ensure-gcm.sh's network probe) never
# delays the prompt; output goes to a log instead of the terminal since
# nothing interactive is there to read it.
if [[ -n "${DOTFILES_DIR:-}" && -x "$DOTFILES_DIR/install.sh" ]]; then
  _self_heal_dir="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles"
  _self_heal_sentinel="$_self_heal_dir/self-heal.last-run"
  _self_heal_now="$(date +%s)"
  _self_heal_last="$(cat "$_self_heal_sentinel" 2>/dev/null)"
  [[ "$_self_heal_last" =~ ^[0-9]+$ ]] || _self_heal_last=0

  if (( _self_heal_now - _self_heal_last > 86400 )); then
    mkdir -p "$_self_heal_dir"
    echo "$_self_heal_now" > "$_self_heal_sentinel"
    ( "$DOTFILES_DIR/install.sh" >"$_self_heal_dir/self-heal.log" 2>&1 & )
  fi

  unset _self_heal_dir _self_heal_sentinel _self_heal_now _self_heal_last
fi
