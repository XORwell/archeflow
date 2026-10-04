#!/usr/bin/env bash
# run-tests.sh — Run all ArcheFlow bats tests.
#
# Runs the tests in parallel (bats --jobs <nproc>) when GNU parallel is
# installed, serially otherwise. ARCHEFLOW_TEST_JOBS=<n> sets the job count
# (1 = serial); a --jobs/-j argument of your own takes precedence.
#
# Usage: ./scripts/run-tests.sh [bats-args...]
# Examples:
#   ./scripts/run-tests.sh                  # Run all tests
#   ./scripts/run-tests.sh --filter "event" # Run only event tests
#   ./scripts/run-tests.sh -t               # TAP output
#   ARCHEFLOW_TEST_JOBS=1 ./scripts/run-tests.sh   # serial

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

# Parallel jobs: bats --jobs needs GNU parallel (not the moreutils one).
jobs_args=()
user_jobs=false
for a in "$@"; do
  case "$a" in -j|--jobs|--jobs=*|-j[0-9]*) user_jobs=true ;; esac
done
if ! $user_jobs && parallel --version 2>/dev/null | grep -q 'GNU parallel'; then
  jobs="${ARCHEFLOW_TEST_JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
  [[ "$jobs" =~ ^[0-9]+$ ]] || { echo "ERROR: ARCHEFLOW_TEST_JOBS must be a number" >&2; exit 1; }
  (( jobs > 1 )) && jobs_args=(--jobs "$jobs")
fi

echo "Running ArcheFlow tests..."
echo "  bats: $($BATS --version)"
echo "  tests: $TESTS_DIR"
if [[ ${#jobs_args[@]} -gt 0 ]]; then
  echo "  jobs: ${jobs_args[1]} (GNU parallel)"
else
  echo "  jobs: serial"
fi
echo ""

exec "$BATS" "${jobs_args[@]}" "$@" "$TESTS_DIR"/*.bats "$TESTS_DIR"/e2e/*.bats
