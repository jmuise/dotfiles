#!/usr/bin/env bash
# start-project.sh — build/start a project's devcontainer and drop into it
# from the terminal, the way VS Code's "Reopen in Container" does from its UI.
# Linked to ~/.local/bin/start-project by install.py; aliased to `sp`.
#
# Usage: sp [path] [-c|--code]
#   path        project directory (default: current directory)
#   -c, --code  attach VS Code to the container instead of opening a shell
set -euo pipefail

use_code=false
dir=""
for arg in "$@"; do
  case "$arg" in
    -c|--code) use_code=true ;;
    -h|--help)
      echo "Usage: sp [path] [-c|--code]"
      echo "  Builds/starts the project's devcontainer via the devcontainer CLI"
      echo "  (same thing VS Code's \"Reopen in Container\" does), then:"
      echo "    default      drops you into a shell inside the container"
      echo "    -c, --code   attaches VS Code to the container instead"
      exit 0
      ;;
    *) dir="$arg" ;;
  esac
done
dir="${dir:-$PWD}"
dir="$(cd -- "$dir" && pwd)"

if ! command -v devcontainer >/dev/null 2>&1; then
  echo "sp: devcontainer CLI not found. Install it with: npm install -g @devcontainers/cli" >&2
  echo "sp: (or re-run the dotfiles installer — it installs this alongside kilo/copilot)" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "sp: jq not found (required to parse devcontainer CLI output). Install it and re-run." >&2
  exit 1
fi

if [[ ! -e "$dir/.devcontainer/devcontainer.json" && ! -e "$dir/.devcontainer.json" ]] \
   && ! compgen -G "$dir/.devcontainer/*/devcontainer.json" >/dev/null; then
  echo "sp: no devcontainer found in $dir" >&2
  echo "sp: add .devcontainer/devcontainer.json first (or have it provisioned)." >&2
  exit 1
fi

echo "sp: starting devcontainer for $dir..." >&2
set +e
result="$(devcontainer up --workspace-folder "$dir")"
status=$?
set -e

outcome=""
[[ -n "$result" ]] && outcome="$(jq -r '.outcome // empty' <<<"$result" 2>/dev/null)"

if [[ $status -ne 0 || "$outcome" != "success" ]]; then
  echo "sp: devcontainer up failed:" >&2
  if [[ -n "$result" ]]; then
    echo "$result" | jq . >&2 2>/dev/null || echo "$result" >&2
  fi
  exit 1
fi

if $use_code; then
  if ! command -v code >/dev/null 2>&1; then
    echo "sp: container is up, but the 'code' CLI isn't on PATH — can't attach VS Code." >&2
    exit 1
  fi
  remote_workspace="$(jq -r '.remoteWorkspaceFolder // empty' <<<"$result")"
  target="${remote_workspace:-/workspaces/$(basename "$dir")}"
  hex="$(printf '%s' "$dir" | od -An -tx1 | tr -d ' \n')"
  exec code --folder-uri "vscode-remote://dev-container+${hex}${target}"
fi

exec devcontainer exec --workspace-folder "$dir" bash
