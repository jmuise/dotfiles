#!/usr/bin/env bash
# Run both reader test suites for the `profile` file contract.
#   bash profile/run-tests.sh
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

echo "=== python: profile/test_profile.py ==="
python3 "$DIR/test_profile.py"

echo
echo "=== shell: profile/test_profile.sh ==="
bash "$DIR/test_profile.sh"
