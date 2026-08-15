#!/usr/bin/env bash
# Sync the shared body content of the number-one orchestrator agent between
# its Claude Code definition and its Kilo definition.
#
# The two files have different YAML frontmatter (Claude Code uses comma-separated
# `tools:` and `permissionMode`, while Kilo uses an object `tools:` map and
# `mode:`). The markdown body (the actual instructions) is identical and must
# not drift. This script copies the body from claude/agents/number-one.md into
# kilo/.kilo/agents/number-one.md, preserving the Kilo frontmatter.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

CLAUDE_AGENT="claude/agents/number-one.md"
KILO_AGENT="kilo/.kilo/agents/number-one.md"

for f in "$CLAUDE_AGENT" "$KILO_AGENT"; do
  if [ ! -f "$f" ]; then
    echo "error: $f not found" >&2; exit 1
  fi
done

# Extract body: everything after the second --- delimiter.
# c counts --- delimiters; skip the delimiter lines themselves, print only after c > 1.
claude_body=$(awk '/^---$/{c++; next} c>1' "$CLAUDE_AGENT")

# Extract frontmatter from the Kilo file: lines between the first and second ---,
# excluding the delimiter lines themselves.
kilo_fm=$(awk '/^---$/ { c++; if (c == 2) exit; next } c == 1' "$KILO_AGENT")

tmp=$(mktemp)
printf '%s\n%s\n%s\n' '---' "$kilo_fm" '---' > "$tmp"
printf '%s\n' "$claude_body" >> "$tmp"
mv "$tmp" "$KILO_AGENT"

echo "synced body from $CLAUDE_AGENT → $KILO_AGENT (Kilo frontmatter preserved)"
