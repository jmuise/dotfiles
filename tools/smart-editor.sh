#!/usr/bin/env bash
# smart-editor.sh — context-aware $EDITOR/$VISUAL shim.
#
# Linked to ~/.local/bin/smart-editor by install.py and pointed at by
# shell/exports.sh's EDITOR/VISUAL. Picks the right editor for where it's
# actually being run from, instead of always hard-launching VS Code:
#
#   1. Agent session (Claude Code, or another tool exporting a recognized
#      agent marker) — refuse and explain. An agent has no way to close an
#      interactive editor it opens (GUI or terminal), so launching one either
#      hangs the tool call or pops a window the human never asked for — see
#      the incident that prompted this: `starship config` silently launched
#      VS Code from inside a Claude Code session. Agents have their own
#      file-editing tools and should use those instead of shelling out to
#      $EDITOR; if a human genuinely needs to open the file, say so in chat.
#   2. VS Code-wrapped terminal (its integrated terminal, including one
#      forwarded into a devcontainer) — a human is driving, and VS Code is
#      right there, so hand the file to `code --wait`.
#   3. Plain terminal, no VS Code wrapper — use a terminal editor in-place
#      rather than launching a GUI app the terminal can't see.
set -euo pipefail

is_agent_session() {
  [[ -n "${CLAUDECODE:-}${AI_AGENT:-}${CODEX_SANDBOX:-}${CURSOR_TRACE_ID:-}" ]]
}

is_vscode_terminal() {
  [[ "${TERM_PROGRAM:-}" == "vscode" || -n "${VSCODE_INJECTION:-}" ]]
}

if is_agent_session; then
  agent_name="${AI_AGENT:-${CLAUDECODE:+claude-code}}"
  echo "smart-editor: refusing to launch an interactive editor from an agent session (${agent_name:-unknown}) for: $*" >&2
  echo "smart-editor: use your own file-editing tools instead of \$EDITOR; tell the user directly if a human needs to open this file." >&2
  exit 1
fi

if is_vscode_terminal; then
  exec code --wait "$@"
fi

for candidate in nvim vim nano; do
  if command -v "$candidate" >/dev/null 2>&1; then
    exec "$candidate" "$@"
  fi
done

echo "smart-editor: no terminal editor found (tried nvim, vim, nano)" >&2
exit 1
