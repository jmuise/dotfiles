# shellcheck shell=bash
# Sourced, not executed: shared jq bootstrap for the hooks in claude/hooks/.
# Not a hook itself -- claude/settings.json wires up hooks by explicit path, so
# nothing under _lib/ ever runs on its own.
#
# Hooks inherit the agent's PATH, which in a devcontainer may not include
# ~/.local/bin (shell/exports.sh only runs for shells), where tools/ensure-jq.sh
# installs jq -- so append it as a last-resort fallback (appended, never
# prepended: it must not shadow system binaries). Done on source, so a hook that
# treats jq as optional (rtk-rewrite.sh) gets the same lookup as the guards.
[ -n "${HOME:-}" ] && PATH="$PATH:$HOME/.local/bin"

# require_jq <hook-name>: for the fail-CLOSED guards. A missing jq is a block
# with an actionable message, never an allow.
require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "BLOCKED by claude/hooks/$1: jq not found on PATH, so this guard cannot read the tool call and refuses it rather than silently allowing it. Install jq: re-run the dotfiles installer (install.sh) or run tools/ensure-jq.sh from the dotfiles checkout (installs a checksum-verified jq into ~/.local/bin, no sudo), or install jq with the system package manager." >&2
  exit 2
}

# Explicit, so a later trailing command can't change the status `source` reports.
return 0
