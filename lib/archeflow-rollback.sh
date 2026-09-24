#!/usr/bin/env bash
# archeflow-rollback.sh — Auto-revert a merge that fails post-merge tests,
# or roll back to a specific PDCA phase boundary.
#
# Usage:
#   archeflow-rollback.sh <run_id> [--test-cmd <cmd>]       # Post-merge test + revert
#   archeflow-rollback.sh <run_id> --to <phase>             # Roll back to phase boundary
#
# --to <phase>: Roll back to the given phase boundary (plan, do, or check).
#   Delegates to archeflow-git.sh rollback and emits a decision event.
#
# If --test-cmd not provided (and --to not used), reads test_command from .archeflow/config.yaml.
#
# Auto-revert only ever reverts the ArcheFlow merge commit of THIS run: HEAD must
# be the commit that "archeflow-git.sh merge <run_id>" creates, i.e. its subject
# is exactly "feat: archeflow run <run_id> complete" (squash or no-ff merge).
# Otherwise the tests still run, but a failure is reported without reverting,
# so a user's own commit is never reverted.
#
# Exit codes: 0 tests pass (or phase rollback succeeded); 1 tests failed and the
# merge was reverted; 2 usage/config error; 3 tests failed, HEAD is not this
# run's ArcheFlow merge commit, nothing reverted.
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/archeflow-common.sh
source "${SCRIPT_DIR}/archeflow-common.sh"
RUN_ID="${1:?Usage: archeflow-rollback.sh <run_id> [--test-cmd <cmd>] [--to <phase>]}"
shift

# Run IDs become file names under .archeflow/ (and git branch names).
af_require_run_id "$RUN_ID"

# Parse options
TEST_CMD=""
TARGET_PHASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-cmd) TEST_CMD="$2"; shift 2 ;;
    --to) TARGET_PHASE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# Mutual exclusivity check
if [[ -n "$TARGET_PHASE" && -n "$TEST_CMD" ]]; then
  echo "ERROR: --to and --test-cmd are mutually exclusive." >&2
  exit 2
fi

# --- Phase rollback mode ---
if [[ -n "$TARGET_PHASE" ]]; then
  # Validate phase name
  case "$TARGET_PHASE" in
    plan|do|check) ;;
    *)
      echo "ERROR: Invalid phase '$TARGET_PHASE'. Must be one of: plan, do, check" >&2
      exit 2
      ;;
  esac

  echo "Rolling back run $RUN_ID to phase boundary: $TARGET_PHASE"

  # Delegate to archeflow-git.sh
  if [[ ! -x "$SCRIPT_DIR/archeflow-git.sh" ]]; then
    echo "ERROR: archeflow-git.sh not found or not executable" >&2
    exit 1
  fi

  "$SCRIPT_DIR/archeflow-git.sh" rollback "$RUN_ID" --to "$TARGET_PHASE"

  # Emit decision event
  if [[ -x "$SCRIPT_DIR/archeflow-event.sh" ]]; then
    "$SCRIPT_DIR/archeflow-event.sh" "$RUN_ID" decision act "" \
      "{\"what\":\"phase_rollback\",\"chosen\":\"rollback_to_${TARGET_PHASE}\",\"rationale\":\"user requested rollback to ${TARGET_PHASE} phase boundary\"}" ""
  fi

  echo "Rollback to $TARGET_PHASE complete for run $RUN_ID."
  exit 0
fi

# --- Post-merge test mode ---

# Read test_command from config if not provided
if [[ -z "$TEST_CMD" ]]; then
  if [[ -f ".archeflow/config.yaml" ]]; then
    TEST_CMD=$(grep -E "^test_command:" .archeflow/config.yaml | head -1 | sed 's/^test_command:[[:space:]]*//' | tr -d '"' || true)
  fi
fi

if [[ -z "$TEST_CMD" ]]; then
  echo "ERROR: No test command specified (use --test-cmd or set test_command in .archeflow/config.yaml)" >&2
  exit 2
fi

# Only this run's ArcheFlow merge commit may be reverted (see header).
HEAD_MSG=$(git log -1 --format=%s HEAD 2>/dev/null || true)
EXPECTED_MSG="feat: archeflow run ${RUN_ID} complete"
CAN_REVERT=false
if [[ "$HEAD_MSG" == "$EXPECTED_MSG" ]]; then
  CAN_REVERT=true
else
  echo "WARNING: HEAD is not the ArcheFlow merge commit for run ${RUN_ID} (subject: ${HEAD_MSG:-<none>})." >&2
  echo "Auto-revert is disabled; a test failure will be reported, not reverted." >&2
fi

echo "Running post-merge tests: $TEST_CMD"

_portable_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@" &
    local pid=$!
    ( sleep "$secs" && kill "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid"
    local ret=$?
    kill "$watchdog" 2>/dev/null
    return "$ret"
  fi
}

if _portable_timeout 300 bash -c "$TEST_CMD"; then
  echo "Tests passed — merge is good."
  exit 0
fi

if [[ "$CAN_REVERT" != "true" ]]; then
  echo "Tests FAILED — HEAD is not this run's ArcheFlow merge commit; refusing to revert it." >&2
  echo "Inspect the failure and revert manually if needed." >&2
  exit 3
fi

echo "Tests FAILED — reverting merge..."
# --mainline 1 is only valid (and needed) for a real merge commit (no-ff);
# a squash merge is an ordinary single-parent commit.
if git rev-parse --verify --quiet HEAD^2 >/dev/null; then
  git revert --no-edit --mainline 1 HEAD
else
  git revert --no-edit HEAD
fi

# Emit event if event script exists
if [[ -x "$SCRIPT_DIR/archeflow-event.sh" ]]; then
  "$SCRIPT_DIR/archeflow-event.sh" "$RUN_ID" decision act "" \
    "{\"what\":\"post_merge_test\",\"chosen\":\"revert\",\"rationale\":\"test suite failed after merge\"}" ""
fi

REVERT_HASH=$(git rev-parse --short HEAD)
echo "Merge reverted (commit: $REVERT_HASH). Tests must pass before re-merging."
exit 1
