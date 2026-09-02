#!/usr/bin/env bash
# Claude Code PreToolUse hook -- blocks file edits and project commands against
# a git project's working tree when the session is not running inside a
# container. Wired up via claude/settings.json's hooks.PreToolUse matchers for
# Bash, Edit, Write and NotebookEdit. Exit 2 blocks the tool call and returns
# stderr to the calling agent as feedback; exit 0 allows it through.
#
# Why this exists: agents did engineering work on the WSL host against a
# containerized project and littered the host with build artifacts, caches and
# toolchains. The container exists so that cannot happen. A prose rule can't
# enforce it -- subagents share the top-level session's OS process, so nothing
# below the top-level `claude` process can be independently "inside" a
# container, and a fresh session never read the conversation where the rule was
# agreed. Only a hook fires unconditionally, for every agent, every session.
#
# The decision procedure once blocked lives in the `devcontainer-first` skill;
# this script deliberately holds no prose about what to do next beyond pointing
# there, so the two can't drift.
#
# Scoping errs wide on purpose. For Bash it allowlists a narrow read-only set
# rather than denylisting risky commands: a denylist that misses a case fails
# *silently* and reproduces exactly the host clutter this guards against, while
# an over-broad allowlist fails loudly and is trivially recoverable (relaunch in
# the container, or widen the list deliberately). Known, accepted over-blocks:
# a quoted pipe or semicolon inside an argument (`grep 'a|b' f`) splits into
# segments and trips the allowlist; command substitution is refused outright
# even when its inner command would be allowed; `cd x && ls` is refused because
# `cd` is not on the list; a backslash line-continuation (`git log --oneline \`
# + newline + `-n 10`) is refused, because every newline is treated as a command
# separator and `-n` is not a command name; and a `#` comment inside a
# multi-line command splits at that newline the same way, so whatever follows it
# is judged as its own segment and will usually trip the allowlist.
#
# Those last two are deliberate, and were reached by reverting an attempt to do
# better. A ten-line splice that rejoined backslash-continued lines before
# segmenting looked like a free convenience and was not. Bash ends a `#` comment
# at the newline *regardless* of a trailing backslash, so `ls -la #\` + newline
# + `bash evil.sh` spliced into one segment headed by an allowlisted `ls` and
# ran arbitrary code against a guarded working tree. The splice was also
# quadratic in line count -- ~176s on 32k lines, past Claude Code's 60s default
# hook timeout, and a timed-out hook does not exit 2, so the tool call proceeds.
# An ACE bypass and a fail-open, bought for the convenience of not retyping a
# command on one line. Modelling shell quoting and comments does not belong in a
# security guard; when a continuation is refused, join the lines. The over-block
# only bites on the bare host in a non-exempt repo anyway -- inside a container
# this script has already exited 0 -- so it lands exactly where work should not
# be happening. DO NOT reintroduce a splice, comment-aware or otherwise.
#
# The same bias governs failure of the script itself. PreToolUse treats *only*
# exit 2 as a block; every other non-zero exit is a non-blocking error and the
# tool call proceeds anyway. So an unhandled failure -- jq missing from PATH
# (exit 127), a malformed payload (exit 5), an unset variable -- would silently
# disable this guard for that call, which is the one failure mode that must not
# happen. The ERR trap turns any such failure into a block. `-E` makes the trap
# inherit into functions and subshells.
set -Eeuo pipefail
# A failure inside a command substitution prints this twice -- once in the
# subshell, once when the parent re-checks the failed assignment. Disarming the
# trap from inside it does not help (the subshell only disarms its own copy),
# and the exit code is 2 either way, so the duplication is left alone.
trap 'echo "BLOCKED by claude/hooks/require-devcontainer.sh: the guard itself failed unexpectedly near line $LINENO, so this call is refused rather than silently allowed. This is a bug in the hook, not in your command -- report it to the Captain." >&2; exit 2' ERR

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // "main"')

case "$tool_name" in
Bash | Edit | Write | NotebookEdit) ;;
*) exit 0 ;;
esac

# chief-engineer is exempt wholesale: its entire job is host-side bootstrap --
# git init, docker build, docker run -- which by definition happens before any
# container exists. Gating it would make it impossible to ever provision one,
# and it is the single intended path *into* a container.
[ "$agent_type" = "chief-engineer" ] && exit 0

# Which directory is this call acting on? File tools carry their own target;
# Bash is judged by the session's cwd (a `cd` inside the command is not
# resolvable here, and doesn't need to be -- the allowlist bounds what a Bash
# call can do regardless of where it lands).
if [ "$tool_name" = "Bash" ]; then
  target=$(printf '%s' "$input" | jq -r '.cwd // empty')
else
  target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
  target=$(dirname -- "${target:-.}")
fi
[ -n "$target" ] || exit 0

# A Write may target a file in a directory that doesn't exist yet, so walk up to
# the nearest existing ancestor before asking git anything.
while [ ! -d "$target" ] && [ "$target" != "/" ] && [ -n "$target" ]; do
  target=$(dirname -- "$target")
done

# Not inside a git repo at all (scratch dir, $HOME, /tmp) -- out of scope.
project_root=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$project_root" ] || exit 0

# The portable opt-out: a repo whose job is configuring the host it lives on
# (the dotfiles repo being the first such) drops this marker at its root. Test
# for the marker and never for a hardcoded path -- the marker is the mechanism.
[ -f "$project_root/.no-auto-provision" ] && exit 0

# Am I in *some* container? Any one signal is sufficient. This intentionally
# does not try to prove it is *this project's* container -- the failure being
# guarded against is work landing on the bare host.
in_container() {
  [ -f /.dockerenv ] && return 0
  [ -r /proc/1/cgroup ] && grep -qE '(docker|containerd)' /proc/1/cgroup && return 0
  [ "${REMOTE_CONTAINERS:-}" = "true" ] && return 0
  [ -n "${CODESPACES:-}" ] && return 0
  return 1
}
in_container && exit 0

block() {
  echo "BLOCKED by claude/hooks/require-devcontainer.sh: $1" >&2
  # agent_type (parsed above, hardcoded as "kilo"/"copilot" by those shims) is
  # available here if a future tool-specific message is ever wanted -- that
  # would be a `case "$agent_type"` in this function, not an interface change.
  echo "This session is not running inside the devcontainer for the project at $project_root, so it may not edit its files or run project commands against it. Getting containerized means relaunching the session inside the container; no worker can arrange that for itself mid-task, and host-side work is never the substitute. If the project has no .devcontainer/ yet, retrofitting one needs the Captain's confirmation first; if it has one and this session simply isn't in it, the session needs relaunching inside it. Route that through whatever provisioning path this CLI has -- and if it has none, stop and tell the Captain rather than working around it. The \`devcontainer-first\` skill holds the full decision tree. (Agent: \"$agent_type\")" >&2
  exit 2
}

# Mutating a project file from the bare host has no legitimate form once this
# rule exists, so there is nothing to allowlist here.
if [ "$tool_name" != "Bash" ]; then
  block "$tool_name against a non-containerized project working tree"
fi

command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -n "$command" ] || exit 0

# Fold newlines to spaces for the two text passes below, exactly as
# block-pr-merge.sh does and for the same reason: grep is line-oriented, so a real
# newline in a multi-line command silently truncates what gets inspected -- a
# `$(` opened on line 2 would go unseen if the substitution grep only ever saw
# line 1. This folded copy is for those two passes ONLY. Segmentation below must
# see the newlines -- see the note there. Pure parameter expansion, so no
# external process can fail under `set -e` and fail this guard open, and it is
# linear in the size of the command.
folded=${command//$'\n'/ }

# Command substitution can smuggle an arbitrary command inside an allowlisted
# one (`echo $(npm ci)`), and this hook cannot evaluate what is inside it.
if printf '%s' "$folded" | grep -qE '\$\(|`|<\('; then
  block "command substitution cannot be inspected, so it is refused on the host"
fi

# Output redirection writes files, which is the thing being prevented. Strip the
# harmless /dev/null and fd-dup idioms first so ordinary read-only invocations
# (`find . 2>/dev/null`) aren't caught.
redir_check=$(printf '%s' "$folded" | sed -E 's/2>&1//g; s/[0-9]?>>?[[:space:]]*\/dev\/null//g')
if printf '%s' "$redir_check" | grep -q '>'; then
  block "output redirection writes files on the host"
fi

# Judge every segment of a chained command, not just the first: an allowlisted
# command followed by `&& npm ci` must not pass on the strength of its head.
#
# A NEWLINE IS A COMMAND SEPARATOR AND MUST BE IN THIS SET. This once ran on the
# folded string, and because the fold happened first `tr` never saw a newline at
# all: `$'ls\nrm -rf /'` collapsed to `ls rm -rf /`, a single segment headed by an
# allowlisted `ls`, and every line after the first was waved through as an
# ARGUMENT to it. That was arbitrary command execution against a guarded working
# tree -- the exact failure this file exists to prevent. Segment the
# newline-bearing string, never the folded one, and never a rejoined
# derivative of it -- see the header on why the line-continuation splice that
# once sat here was removed rather than repaired.
segments=$(printf '%s' "$command" | tr ';&|\n' '\n\n\n\n')

while IFS= read -r segment; do
  # shellcheck disable=SC2206 # deliberate word splitting: shell tokens
  read -ra toks <<<"$segment"
  [ "${#toks[@]}" -gt 0 ] || continue

  i=0
  # Skip leading VAR=value assignments (`FOO=bar ls`).
  while [ "$i" -lt "${#toks[@]}" ] && [[ ${toks[i]} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    i=$((i + 1))
  done
  [ "$i" -lt "${#toks[@]}" ] || continue

  cmd=${toks[i]##*/} # tolerate an absolute path: /usr/bin/git -> git

  case "$cmd" in
  ls | cat | grep | wc | pwd | echo) ;;

  find)
    # find is a read tool until it isn't: -exec/-delete make it arbitrary.
    if printf '%s' "$segment" | grep -qE '(^|[[:space:]])-(exec|execdir|ok|okdir|delete|fprint|fprintf|fls)([[:space:]]|$)'; then
      block "find with -exec/-delete can mutate the tree"
    fi
    ;;

  git)
    # Resolve the subcommand past any interposed flags, so `git -C dir status`
    # is judged on `status` rather than on `-C` -- the exact bypass that once
    # defeated block-ai-attribution.sh.
    sub=""
    j=$((i + 1))
    while [ "$j" -lt "${#toks[@]}" ]; do
      case "${toks[j]}" in
      -C | -c | --git-dir | --work-tree | --namespace | --exec-path) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *)
        sub=${toks[j]}
        j=$((j + 1))
        break
        ;;
      esac
    done
    rest=()
    [ "$j" -lt "${#toks[@]}" ] && rest=("${toks[@]:j}")

    case "$sub" in
    status | diff | log | show | rev-parse | fetch) ;;

    branch)
      # Read-only forms only. Requiring every remaining token to be a flag is
      # blunt (it refuses `git branch --contains HEAD`) but it closes both
      # branch creation (`git branch new-name`) and deletion in one rule.
      for t in ${rest[@]+"${rest[@]}"}; do
        case "$t" in
        -d | -D | -m | -M | -c | -C | -f | --delete | --move | --copy | --force | --unset-upstream | --edit-description | --set-upstream-to*)
          block "git branch write form ($t) is not read-only"
          ;;
        -*) ;;
        *) block "git branch with a positional argument can create or reset a branch" ;;
        esac
      done
      ;;

    remote)
      case "${rest[0]:-}" in
      "" | show | get-url | -v | -vv | --verbose) ;;
      *) block "only read-only 'git remote' forms are permitted (${rest[0]})" ;;
      esac
      ;;

    worktree)
      case "${rest[0]:-}" in
      list) ;;
      *) block "only 'git worktree list' is permitted (${rest[0]:-<none>})" ;;
      esac
      ;;

    *) block "'git ${sub:-<none>}' is not on the host read-only allowlist" ;;
    esac
    ;;

  gh)
    # Same flag-skipping, then judge the first two non-flag tokens as the
    # command path (`pr view`, `issue list`).
    path=""
    count=0
    j=$((i + 1))
    while [ "$j" -lt "${#toks[@]}" ] && [ "$count" -lt 2 ]; do
      case "${toks[j]}" in
      -R | --repo) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *)
        path="${path:+$path }${toks[j]}"
        count=$((count + 1))
        j=$((j + 1))
        ;;
      esac
    done
    case "$path" in
    "pr view" | "pr checks" | "pr status" | "pr list" | "issue view" | "issue list") ;;
    *) block "'gh ${path:-<none>}' is not on the host read-only allowlist" ;;
    esac
    ;;

  *)
    block "'$cmd' is not on the host read-only allowlist"
    ;;
  esac
done <<<"$segments"

exit 0
