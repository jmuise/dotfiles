# doctor.sh — lightweight environment health check
# Sourced by .bashrc/.zshrc at the start of every interactive shell (see
# ~/.doctor, symlinked by install.sh). Warns, never blocks - replaces the old
# pre-commit/pre-push hard block (git/identity-guard.sh) that used to catch a
# placeholder git identity by refusing the commit outright. That caught real
# problems but also caught the user off guard mid-commit; this surfaces the
# same signal earlier and non-destructively instead. Silent when everything
# looks fine. Also callable by hand as `doctor`.
doctor() {
  local issues=0
  local name email
  name="$(git config user.name 2>/dev/null || true)"
  email="$(git config user.email 2>/dev/null || true)"

  # Same placeholder patterns the retired identity-guard.sh used to enforce.
  local placeholder_names="Your Name|John Doe|Test|test"
  local placeholder_emails="you@example\.com|your\.email@example\.com|user@example\.com|test@example\.com|root@localhost"

  if [[ -z "$name" || "$name" =~ ^($placeholder_names)$ ]]; then
    printf '\033[0;33m⚠\033[0m git user.name is unset or a placeholder (%s) — commits will misattribute. Fix: git config --global user.name "Your Actual Name"\n' "${name:-<empty>}"
    issues=$((issues + 1))
  fi
  if [[ -z "$email" || "$email" =~ ^($placeholder_emails)$ || "$email" != *@*.* ]]; then
    printf '\033[0;33m⚠\033[0m git user.email is unset or a placeholder (%s) — commits will misattribute. Fix: git config --global user.email "you@yourdomain.com"\n' "${email:-<empty>}"
    issues=$((issues + 1))
  fi

  # Credential forwarding configured (sentinel present) but didn't land this
  # session - see shell/exports.sh for the actual forwarding attempt.
  if [[ -f "${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/claude-token.configured" && -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    printf '\033[0;33m⚠\033[0m Claude Code token forwarding is configured but CLAUDE_CODE_OAUTH_TOKEN is unset this session — see secrets/README.md\n'
    issues=$((issues + 1))
  fi

  if [[ -f "${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/openrouter-token.configured" && -z "${OPENROUTER_API_KEY:-}" ]]; then
    printf '\033[0;33m⚠\033[0m OpenRouter key forwarding is configured but OPENROUTER_API_KEY is unset this session — see secrets/README.md\n'
    issues=$((issues + 1))
  fi

  # core.hooksPath pointing at a directory that doesn't exist (issue #70): git
  # silently skips every hook in that case -- no error, no warning -- so a
  # stale or wrong path (e.g. install.py once repointed the canonical
  # checkout's hooksPath at a deleted /tmp scratch dir) disarms the
  # never-merge pre-commit guard and the post-* auto-sync hooks with nothing
  # to say so. A hook dispatcher can't catch this itself (a hook in a missing
  # directory never runs to report it), so this has to live somewhere that
  # runs regardless -- here, at shell start.
  #
  # doctor() runs in whatever directory the shell happens to start in, not
  # necessarily inside the dotfiles checkout, so `git config` alone can't be
  # trusted to see the right repo. The install receipt (written by
  # install.py, read the same way hooks/_dispatch.sh reads it for #54)
  # records which checkout this $HOME was actually installed from -- check
  # THAT repo's hooksPath explicitly instead of relying on cwd.
  local receipt dotfiles_dir hooks_path
  receipt="$HOME/.local/state/dotfiles/install-root"
  if [[ -f "$receipt" ]]; then
    dotfiles_dir="$(cat "$receipt" 2>/dev/null || true)"
    if [[ -n "$dotfiles_dir" && -d "$dotfiles_dir" ]]; then
      hooks_path="$(git -C "$dotfiles_dir" config --get core.hooksPath 2>/dev/null || true)"
      if [[ -n "$hooks_path" ]]; then
        # core.hooksPath may be a relative path (git resolves it against the
        # working tree root); an absolute one is what install.py writes, but
        # resolve either case against $dotfiles_dir rather than assume.
        case "$hooks_path" in
          /*) : ;;
          *)  hooks_path="$dotfiles_dir/$hooks_path" ;;
        esac
        if [[ ! -d "$hooks_path" ]]; then
          printf '\033[0;33m⚠\033[0m core.hooksPath (%s) does not exist — git silently skips every hook (including the never-merge pre-commit guard) until this is fixed. Re-run: bash install.sh\n' "$hooks_path"
          issues=$((issues + 1))
        fi
      fi
    fi
  fi

  # `gh auth token` is a local read (no network call), same check
  # shell/exports.sh uses to populate GH_TOKEN - safe to repeat here.
  if command -v gh &>/dev/null; then
    local gh_token
    gh_token="$(gh auth token 2>/dev/null || true)"
    if [[ -z "$gh_token" ]]; then
      printf '\033[0;33m⚠\033[0m gh is installed but not authenticated (or its token is unreadable) — run: gh auth login\n'
      issues=$((issues + 1))
    elif [[ -z "${GH_TOKEN:-}" ]]; then
      printf '\033[0;33m⚠\033[0m gh is authenticated but GH_TOKEN is unset this session — exports.sh should have picked this up, try a fresh shell\n'
      issues=$((issues + 1))
    fi
  fi

  return "$issues"
}

doctor
