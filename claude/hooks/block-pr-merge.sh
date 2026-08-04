#!/usr/bin/env bash
# Claude Code PreToolUse hook -- blocks PR-merge and unsafe force-push
# commands, regardless of which agent (including number-one's delegated
# workers) issues them. Wired up via claude/settings.json's
# hooks.PreToolUse -> Bash matcher. Exit 2 blocks the tool call and returns
# stderr to the calling agent as feedback; exit 0 allows it through.
set -euo pipefail

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')

# Only inspect Bash invocations.
[ "$tool_name" = "Bash" ] || exit 0

command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // "main"')

block() {
  echo "BLOCKED by claude/hooks/block-pr-merge.sh: $1" >&2
  echo "PRs in this workflow are merged by a human only -- no agent (including \"$agent_type\") may merge or force-push over shared history. Push your branch, keep the PR description/CI status current, and hand off for human review/merge instead." >&2
  exit 2
}

# gh pr merge, in any form (flags, PR number/URL, --auto, --admin, etc.),
# including when chained after other commands with && / ; / |.
if printf '%s' "$command" | grep -Eiq '(^|[;&|]|[[:space:]])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
  block "gh pr merge is not permitted"
fi

# git push --force handling: bare --force / -f is blocked outright.
# --force-with-lease is allowed on a worker's own feature branch (needed to
# keep a PR current after a rebase) but never onto main/master.
if printf '%s' "$command" | grep -Eiq '(^|[;&|]|[[:space:]])git[[:space:]]+push\b'; then
  if printf '%s' "$command" | grep -Eiq -- '--force([[:space:]]|$)' \
     && ! printf '%s' "$command" | grep -Eiq -- '--force-with-lease'; then
    block "bare 'git push --force' is not permitted; use --force-with-lease on your own feature branch if you must rewrite it"
  fi
  if printf '%s' "$command" | grep -Eiq -- '(--force|--force-with-lease|[[:space:]]-f([[:space:]]|$))' \
     && printf '%s' "$command" | grep -Eiq '\b(origin[[:space:]]+)?(main|master)\b'; then
    block "force-pushing to main/master is not permitted"
  fi
fi

exit 0
