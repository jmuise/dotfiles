#!/usr/bin/env bash
# Claude Code PreToolUse hook -- blocks AI-attribution/promotional lines from
# entering git history or any repository artifact, regardless of which agent
# (including number-one's delegated workers) issues the command. Wired up via
# claude/settings.json's hooks.PreToolUse -> Bash matcher. Exit 2 blocks the
# tool call and returns stderr to the calling agent as feedback; exit 0 allows.
#
# Why this exists: CLAUDE.md forbids these lines, but an agent satisfied that
# rule literally for commit messages while still putting "Generated with
# Claude Code" into a pull request description -- the Captain found it himself
# by reading the PR. Prose rules get followed literally; this one gets enforced.
#
# Known limitations -- this is a strong backstop, not an airtight guarantee:
#   1. It can only inspect the command string. A message passed via
#      `git commit -F file` or `gh pr create --body-file file` is invisible here.
#   2. It over-blocks prose that *quotes* the forbidden pattern (e.g. a commit
#      message explaining this very rule). Rare; rephrasing clears it.
#
# Scoping deliberately errs wide: any `git`/`gh` invocation carrying a write-ish
# subcommand token is inspected, so flag interposition (`git -C dir commit`,
# `git --git-dir=... commit`, `gh pr create -R owner/repo`) cannot slip past.
# An earlier revision required the subcommand to immediately follow `git`/`gh`
# and was silently bypassed by `git -C` -- a routine invocation, not an exotic
# one. Matching scope too eagerly is harmless, since a block only fires when an
# attribution string is *also* present; matching it too narrowly fails silently,
# which is the worst possible outcome for a guard like this.
#
# PreToolUse treats only exit 2 as a block -- every other non-zero exit (jq
# missing, a malformed payload, an unset variable) is non-blocking and the tool
# call proceeds anyway, so an unhandled failure here would silently disable this
# guard for that call. The ERR trap turns any such failure into a block instead.
# `-E` makes the trap inherit into functions and subshells.
set -Eeuo pipefail
# A failure inside a command substitution prints this twice -- once in the
# subshell, once when the parent re-checks the failed assignment. The exit
# code is 2 either way, so the duplication is left alone.
trap 'echo "BLOCKED by claude/hooks/block-ai-attribution.sh: the guard itself failed unexpectedly near line $LINENO, so this call is refused rather than silently allowed. This is a bug in the hook, not in your command -- report it to the Captain." >&2; exit 2' ERR

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')

# Only inspect Bash invocations.
[ "$tool_name" = "Bash" ] || exit 0

command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // "main"')

# Only inspect commands that write text into a repo or its forge. Two loose
# stages rather than one tight pattern, so interposed flags cannot defeat it:
# the command must invoke git/gh, AND carry a subcommand that writes text.
if ! printf '%s' "$command" | grep -Eiq '(^|[;&|]|[[:space:]])(git|gh)([[:space:]]|$)'; then
  exit 0
fi
if ! printf '%s' "$command" | grep -Eiq '[[:space:]](commit|tag|notes|create|edit|comment|review)([[:space:]]|$)'; then
  exit 0
fi

block() {
  echo "BLOCKED by claude/hooks/block-ai-attribution.sh: $1" >&2
  echo "The Captain's CLAUDE.md forbids AI-attribution and promotional lines in any artifact a human reads as part of the work -- commit messages, PR descriptions, issue bodies, code comments and docs alike. Remove the line and re-run the command. Attribution belongs in the conversation, not in the repository. (Agent: \"$agent_type\")" >&2
  exit 2
}

# "Co-Authored-By: Claude ..." trailers.
if printf '%s' "$command" | grep -Eiq 'co-authored-by:[[:space:]]*claude'; then
  block "Co-Authored-By: Claude trailer detected"
fi

# "Generated with Claude Code" footers, in any phrasing that pairs the two.
if printf '%s' "$command" | grep -Eiq 'generated[[:space:]]+(with|by)[^\n]{0,40}claude'; then
  block "'Generated with Claude' attribution detected"
fi

# Promotional links back to the product.
if printf '%s' "$command" | grep -Eiq '(claude\.com|anthropic\.com)/claude-code'; then
  block "promotional claude-code link detected"
fi

exit 0
