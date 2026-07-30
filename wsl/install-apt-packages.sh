#!/usr/bin/env bash
# install-apt-packages.sh - installs the packages passed as arguments,
# skipping any that don't resolve rather than letting one bad name abort the
# entire apt-get install (this is what happened with a stale
# "docker-compose-v2" entry - it took tmux and everything else down with it).
#
# Usage: install-apt-packages.sh pkg1 pkg2 ...

set -e

DEBIAN_FRONTEND=noninteractive apt-get update -qq

VALID=()
for pkg in "$@"; do
  if apt-cache show "$pkg" >/dev/null 2>&1; then
    VALID+=("$pkg")
  else
    echo "WARNING: package not found in apt repos, skipping: $pkg" >&2
  fi
done

if [[ ${#VALID[@]} -eq 0 ]]; then
  echo "No valid packages to install."
  exit 0
fi

DEBIAN_FRONTEND=noninteractive apt-get install -y "${VALID[@]}"
