#!/usr/bin/env bash
# run-tests.sh — Run all ArcheFlow bats tests.
#
# Usage: ./scripts/run-tests.sh [bats-args...]
# Examples:
#   ./scripts/run-tests.sh                  # Run all tests
#   ./scripts/run-tests.sh --filter "event" # Run only event tests
#   ./scripts/run-tests.sh -t               # TAP output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$PROJECT_DIR/tests"

# Find bats binary
BATS="${BATS:-}"
if [[ -z "$BATS" ]]; then
  if command -v bats &>/dev/null; then
    BATS="bats"
  elif [[ -x "$HOME/.local/bin/bats" ]]; then
    BATS="$HOME/.local/bin/bats"
  else
    echo "ERROR: bats not found. Install bats-core or set BATS env var." >&2
    exit 1
  fi
fi

echo "Running ArcheFlow tests..."
echo "  bats: $($BATS --version)"
echo "  tests: $TESTS_DIR"
echo ""

exec "$BATS" "$@" "$TESTS_DIR"/*.bats "$TESTS_DIR"/e2e/*.bats
