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
