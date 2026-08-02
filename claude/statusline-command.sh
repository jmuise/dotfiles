#!/usr/bin/env bash
# Claude Code status line script

input=$(cat)

cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // ""')
model=$(echo "$input" | jq -r '.model.display_name // ""')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
repo=$(echo "$input" | jq -r '.workspace.repo | if . then .owner + "/" + .name else empty end')
branch=$(echo "$input" | jq -r '.worktree.branch // empty')
if [ -z "$branch" ] && [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null || true)
fi

# Shorten cwd: replace $HOME with ~
home="$HOME"
short_cwd="${cwd/#$home/\~}"

# Build status line parts
parts=()

# Directory
if [ -n "$short_cwd" ]; then
  parts+=("$(printf '\033[34m%s\033[0m' "$short_cwd")")
fi

# Repo and branch
if [ -n "$repo" ] && [ -n "$branch" ]; then
  parts+=("$(printf '\033[33m%s\033[0m %s' "$repo" "$branch")")
elif [ -n "$repo" ]; then
  parts+=("$(printf '\033[33m%s\033[0m' "$repo")")
fi

# Model
if [ -n "$model" ]; then
  parts+=("$(printf '\033[36m%s\033[0m' "$model")")
fi

# Context usage
if [ -n "$used" ]; then
  used_int=$(printf '%.0f' "$used")
  if [ "$used_int" -ge 80 ]; then
    color='\033[31m'
  elif [ "$used_int" -ge 50 ]; then
    color='\033[33m'
  else
    color='\033[32m'
  fi
  parts+=("$(printf "${color}ctx:%d%%\033[0m" "$used_int")")
fi

# Rate limits (5-hour, if present)
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
if [ -n "$five_pct" ]; then
  five_int=$(printf '%.0f' "$five_pct")
  parts+=("$(printf '5h:%d%%' "$five_int")")
fi

# Join parts with separator
sep=" | "
result=""
for part in "${parts[@]}"; do
  if [ -z "$result" ]; then
    result="$part"
  else
    result="$result$sep$part"
  fi
done

printf '%b\n' "$result"
