#!/usr/bin/env bash
# Claude Code PreToolUse hook -- blocks PR-merge and unsafe force-push
# commands, regardless of which agent (including number-one's delegated
# workers) issues them. Wired up via claude/settings.json's
# hooks.PreToolUse -> Bash matcher. Exit 2 blocks the tool call and returns
# stderr to the calling agent as feedback; exit 0 allows it through.
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
trap 'echo "BLOCKED by claude/hooks/block-pr-merge.sh: the guard itself failed unexpectedly near line $LINENO, so this call is refused rather than silently allowed. This is a bug in the hook, not in your command -- report it to the Captain." >&2; exit 2' ERR

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')

# Only inspect Bash invocations.
[ "$tool_name" = "Bash" ] || exit 0

command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // "main"')

# Fold every embedded newline in the command -- whether it's a genuine
# backslash-continuation (`git push \` / newline / `  --force origin main`)
# or a bare, unescaped newline -- into a single space before any pattern
# matching happens below. grep is line-oriented: a pattern (or a
# grep -o segment extraction) can never span a newline, so leaving real
# newlines in place lets a multi-line invocation silently truncate the
# segment we scan for --force/-f/main and drop coverage (this is exactly
# how the previous version of this scoped check regressed).
#
# We deliberately fold newlines to whitespace rather than treating them
# like a `;`/`&`/`|` hard boundary. A bare newline in a shell command can
# legitimately be either a statement separator or a continuation
# depending on surrounding context (open quotes, a trailing `&&`/`|`,
# etc.) that we can't reliably resolve with regex alone -- and unlike a
# hard boundary, folding to whitespace can only ever widen a matched
# segment, never shrink it. That means the worst case is an extra,
# tolerable false positive (e.g. two unrelated commands on consecutive
# lines both get pulled into one scanned segment); it can never cause a
# real force-push to be missed. Under-firing is the failure mode we
# cannot accept here, so this bias is intentional. True hard separators
# (; & |) are left untouched, so `git push origin feature ; git push
# --force origin main` on one line still resolves as two independent
# segments.
#
# Implemented as a pure-bash parameter expansion (no external process)
# so this fold has no dependency that could fail and, under `set -e`,
# abort the whole script -- which would fail the guard open for every
# Bash call, not just push/merge ones.
command=${command//$'\n'/ }

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
  # Restrict flag inspection to the git-push invocation itself (from "git
  # push" up to the next shell command separator), so a -f/-F flag
  # belonging to an unrelated command chained on the same line -- `docker
  # compose -f x.yml up`, `tar -f a.tar`, `git commit -F -` -- can never
  # trigger a false block here.
  push_segments=$(printf '%s' "$command" | grep -Eio 'git[[:space:]]+push[^;&|]*')

  # Long-form flags are matched case-insensitively (git only recognizes
  # lowercase spellings anyway, so this can't over-match). The short flag
  # -f must be matched case-SENSITIVELY: git's short options are
  # case-sensitive, and -F is an unrelated flag (e.g. `git commit -F -`,
  # `git push -F` doesn't even exist) -- matching it case-insensitively is
  # the bug being fixed here.
  if printf '%s' "$push_segments" | grep -Eiq -- '--force([[:space:]]|$)' \
     && ! printf '%s' "$push_segments" | grep -Eiq -- '--force-with-lease'; then
    block "bare 'git push --force' is not permitted; use --force-with-lease on your own feature branch if you must rewrite it"
  fi
  if { printf '%s' "$push_segments" | grep -Eiq -- '(--force|--force-with-lease)' \
       || printf '%s' "$push_segments" | grep -Eq -- '(^|[[:space:]])-f([[:space:]]|$)'; } \
     && printf '%s' "$push_segments" | grep -Eiq '\b(origin[[:space:]]+)?(main|master)\b'; then
    block "force-pushing to main/master is not permitted"
  fi
fi

exit 0
