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

# VS Code's own Dev Containers extension clones dotfiles.repository into the
# container and runs dotfiles.installCommand on attach; the devcontainer CLI
# has no equivalent, so replicate it here from the same settings this repo
# ships to VS Code, for parity between `sp`, `sp -c`, and a native VS Code
# attach. install.sh is self-updating and safe to re-run, so this runs on
# every `sp`, not just first creation.
setup_dotfiles() {
  local self settings repo target_path install_cmd
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  settings="$(dirname "$self")/../vscode/settings.json"
  [[ -f "$settings" ]] || return 0

  # Anchored to (optional whitespace +) the key at line start, so a
  # commented-out (`// "dotfiles.repository": ...`) or otherwise indented
  # example line elsewhere in this JSONC file can't be picked up instead.
  repo="$(sed -n 's/^[[:space:]]*"dotfiles\.repository"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$settings" | head -n1)"
  target_path="$(sed -n 's/^[[:space:]]*"dotfiles\.targetPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$settings" | head -n1)"
  install_cmd="$(sed -n 's/^[[:space:]]*"dotfiles\.installCommand"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$settings" | head -n1)"
  [[ -n "$repo" ]] || return 0
  target_path="${target_path:-~/dotfiles}"
  install_cmd="${install_cmd:-install.sh}"

  echo "sp: setting up dotfiles in container ($repo)..." >&2
  # target_path/repo/install_cmd come from this repo's own settings.json, but
  # are passed as argv (not interpolated into the remote script's text) so a
  # stray quote/`$(...)`/`;` in any of them can't inject into the remote
  # shell — no string-building, no eval.
  devcontainer exec --workspace-folder "$dir" bash -c '
    set -e
    target="${1/#\~/$HOME}"
    [[ -d "$target/.git" ]] || git clone -- "$2" "$target"
    [[ -f "$target/$3" ]] && bash "$target/$3"
  ' _ "$target_path" "$repo" "$install_cmd" \
    || echo "sp: dotfiles setup failed (continuing)" >&2
}
setup_dotfiles

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
