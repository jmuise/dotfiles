#!/usr/bin/env bash
# identity-guard.sh — aborts noisily if the *effective* git user.name/
# user.email (local > global > system) are still a placeholder, so a bad
# identity gets caught at commit/push time instead of silently landing as
# "Your Name <you@example.com>" in history.
#
# install.sh/install.ps1 scaffold ~/.gitconfig.local with exactly these
# placeholder values on first run and expect you to fill them in before
# committing anything - this is the enforcement half of that contract. Wired
# up as both a pre-commit and pre-push hook (see git/global-hooks/ and
# hooks/) so it catches the problem however it would happen: committing here
# with a bad identity, or pushing commits authored elsewhere (e.g. an old
# checkout, a rebase) under one.
set -euo pipefail

placeholder_names="Your Name|John Doe|Test|test"
placeholder_emails="you@example\.com|your\.email@example\.com|user@example\.com|test@example\.com|root@localhost"

name="$(git config user.name 2>/dev/null || true)"
email="$(git config user.email 2>/dev/null || true)"

bad=""
if [[ -z "$name" ]] || [[ "$name" =~ ^($placeholder_names)$ ]]; then
  bad="${bad}user.name "
fi
if [[ -z "$email" ]] || [[ "$email" =~ ^($placeholder_emails)$ ]] || [[ "$email" != *@*.* ]]; then
  bad="${bad}user.email "
fi

if [[ -n "$bad" ]]; then
  cat >&2 <<EOF

✖✖✖ ABORTED — placeholder git identity: ${bad}✖✖✖

  user.name  = ${name:-<empty>}
  user.email = ${email:-<empty>}

This commit/push would be attributed to a garbage identity. Fix it with:

  git config user.name  "Your Actual Name"
  git config user.email "you@yourdomain.com"

...or, if this is meant to be permanent for this machine, edit
~/.gitconfig.local and re-run install.sh/install.ps1.

To bypass once (not recommended): git commit/push --no-verify
EOF
  exit 1
fi
