#!/usr/bin/env bash
# Sync the shared "spine" of the number-one orchestrator agent from its
# Claude Code definition into its other per-CLI copies (Kilo, Copilot, ...).
#
# hooks/pre-commit enforces that everything OUTSIDE a
# `<!-- PER-TOOL:BEGIN <label> --> ... <!-- PER-TOOL:END <label> -->` region
# (and outside YAML frontmatter) is byte-identical across every guarded
# file. This script is that guard's remediation: it takes Claude's copy as
# source of truth for the spine and rewrites each target file's spine to
# match, while leaving that target's own frontmatter and its own per-tool
# regions exactly as they were. It never touches per-tool content and never
# touches frontmatter — those are genuinely per-tool and this script has no
# opinion about them.
#
# Requires all files to already have well-formed, identically-ordered
# PER-TOOL markers (the same structural invariant hooks/pre-commit checks).
# If a target's marker structure doesn't match the source's, this script
# refuses to guess and tells you to fix the markers first.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Source of truth for the spine. Keep this and TARGET_FILES in sync with
# GUARDED_FILES in hooks/pre-commit — same set of files, same reason.
SOURCE_FILE="claude/agents/number-one.md"
TARGET_FILES=(
  "kilo/.kilo/agents/number-one.md"
  "copilot/agents/number-one.agent.md"
)

for f in "$SOURCE_FILE" "${TARGET_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "error: $f not found" >&2
    exit 1
  fi
done

sync_one() {
  local source="$1" target="$2"
  python3 - "$source" "$target" << 'PYEOF'
import os
import re
import sys
import tempfile

source_path, target_path = sys.argv[1], sys.argv[2]

def split_frontmatter(text, path):
    """Split into (frontmatter_including_delimiters, body). Only the
    leading ---...--- block at the very top counts as frontmatter, so a
    bare `---` later in the body is left alone."""
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        raise ValueError(f"{path}: no leading frontmatter")
    for i in range(1, len(lines)):
        if lines[i] == "---":
            fm = "\n".join(lines[: i + 1])
            body = "\n".join(lines[i + 1 :])
            # body originally starts with a blank line after the closing
            # delimiter; preserve that by not stripping.
            return fm, body
    raise ValueError(f"{path}: no closing frontmatter delimiter found")

# Region labels (e.g. "order-2-task-tracking", "absolute-rule-body") are
# opaque frozen identifiers here too, exactly as in hooks/pre-commit's
# structural check. This script never interprets a label's text — it only
# uses it to look up the target's own region content by matching label
# (target_region_text below) and to confirm, via source_labels != target_labels,
# that the source and target agree on the ordered set of labels before syncing
# anything. Labels are not renumbered when standing orders move elsewhere in
# the agent definition; don't "fix" one to match prose that shifted around it.
REGION_RE = re.compile(
    r"<!-- PER-TOOL:BEGIN (?P<label>[A-Za-z0-9_-]+) -->\n.*?<!-- PER-TOOL:END (?P=label) -->\n?",
    re.DOTALL,
)

def split_segments(body):
    """Return a list of ('spine', text) / ('region', label, text) segments,
    in document order. 'text' for a region includes its markers."""
    segments = []
    pos = 0
    for m in REGION_RE.finditer(body):
        if m.start() > pos:
            segments.append(("spine", body[pos:m.start()]))
        segments.append(("region", m.group("label"), m.group(0)))
        pos = m.end()
    if pos < len(body):
        segments.append(("spine", body[pos:]))
    return segments

with open(source_path) as f:
    source_text = f.read()
with open(target_path) as f:
    target_text = f.read()

source_fm, source_body = split_frontmatter(source_text, source_path)
target_fm, target_body = split_frontmatter(target_text, target_path)

source_segments = split_segments(source_body)
target_segments = split_segments(target_body)

source_labels = [s[1] for s in source_segments if s[0] == "region"]
target_labels = [s[1] for s in target_segments if s[0] == "region"]

if source_labels != target_labels:
    sys.stderr.write(
        f"error: {target_path} PER-TOOL region labels do not match {source_path}\n"
        f"  {source_path}: {source_labels}\n"
        f"  {target_path}: {target_labels}\n"
        "  Fix the markers (see hooks/pre-commit's structural check) before syncing.\n"
    )
    sys.exit(1)

# Map target's own region text by label, so we can preserve it verbatim.
target_region_text = {s[1]: s[2] for s in target_segments if s[0] == "region"}

merged_parts = []
for seg in source_segments:
    if seg[0] == "spine":
        merged_parts.append(seg[1])
    else:
        _, label, _source_region_text = seg
        merged_parts.append(target_region_text[label])

merged_body = "".join(merged_parts)

# Write atomically: all validation above has already happened, so by this
# point we're committed to writing — but a hard interruption mid-write
# (power loss, kill -9, disk full) must not be able to truncate or corrupt
# the target in place. Write to a sibling temp file in the same directory
# (so the final rename is same-filesystem and therefore atomic) and
# os.replace() it over the target, preserving the target's original file
# mode instead of picking up the temp file's default (more restrictive) one.
target_mode = os.stat(target_path).st_mode
target_dir = os.path.dirname(os.path.abspath(target_path)) or "."
fd, tmp_path = tempfile.mkstemp(dir=target_dir, prefix=os.path.basename(target_path) + ".", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        f.write(target_fm + "\n" + merged_body)
    os.chmod(tmp_path, target_mode)
    os.replace(tmp_path, target_path)
except BaseException:
    os.unlink(tmp_path)
    raise

print(f"synced spine from {source_path} -> {target_path} (frontmatter and per-tool regions preserved)")
PYEOF
}

for target in "${TARGET_FILES[@]}"; do
  sync_one "$SOURCE_FILE" "$target"
done
