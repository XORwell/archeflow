#!/usr/bin/env bash
# archeflow-rollback.sh — Run the post-merge tests of a run and auto-revert its
# merge commit if they fail.
#
# Usage:
#   archeflow-rollback.sh <run_id> [--test-cmd <cmd>]
#
# (The former "--to <phase>" mode is gone: a run makes no phase commits, so there
# was nothing to roll back to. To reset a run branch to a commit of your own, use
# "archeflow-git.sh rollback <run_id> --to <phase> --yes" on a branch that has
# commits made with "archeflow-git.sh phase-commit".)
#
# Without --test-cmd, the command is the one recorded for this
# run by "archeflow-git.sh init" (.archeflow/runs/<run_id>/test-command), i.e. the
# one the user saw when confirming the merge. If .archeflow/config.yaml now says
# something else (it changed during the run, or the merge brought a new one),
# nothing runs and the exit code is 2. Runs without a record (started by an
# older version) fall back to test_command from .archeflow/config.yaml.
#
# Auto-revert only ever reverts the ArcheFlow merge commit of THIS run: HEAD must
# be the commit that "archeflow-git.sh merge <run_id>" creates, i.e. its subject
# is exactly "archeflow: merge run <run_id>" (squash or no-ff merge), or the
# subject older versions wrote, "feat: archeflow run <run_id> complete".
# Otherwise the tests still run, but a failure is reported without reverting,
# so a user's own commit is never reverted.
#
# Exit codes: 0 tests pass; 1 tests failed and the merge was reverted; 2 usage or
# config error (including a test command that exits 126/127: not found or not
# executable; nothing is reverted); 3 tests failed, HEAD is not this run's
# ArcheFlow merge commit, nothing reverted.
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/archeflow-common.sh
source "${SCRIPT_DIR}/archeflow-common.sh"
# Refuse a symlinked .archeflow/ (or events/, runs/, memory/ ...): writes would land outside the repo.
af_check_state_dirs
RUN_ID="${1:?Usage: archeflow-rollback.sh <run_id> [--test-cmd <cmd>]}"
shift

# Run IDs become file names under .archeflow/ (and git branch names).
af_require_run_id "$RUN_ID"

# Parse options
TEST_CMD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-cmd)
      [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --test-cmd needs a command." >&2; exit 2; }
      TEST_CMD="$2"; shift 2 ;;
    --to)
      echo "ERROR: --to was removed: a run makes no phase commits. Use 'archeflow-git.sh rollback <run_id> --to <phase> --yes' on a branch with phase-commit commits." >&2
      exit 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# --- Post-merge test mode ---

# Test command: the one recorded at run start, verified against the config.
if [[ -z "$TEST_CMD" ]]; then
  RECORDED=".archeflow/runs/${RUN_ID}/test-command"
  CURRENT="$(af_config_test_command 2>/dev/null || true)"
  if [[ -f "$RECORDED" && ! -L "$RECORDED" ]]; then
    TEST_CMD="$(cat -- "$RECORDED")"
    if [[ "$CURRENT" != "$TEST_CMD" ]]; then
      echo "ERROR: test_command changed since the run started." >&2
      echo "  recorded at run start: ${TEST_CMD:-<none>}" >&2
      echo "  config.yaml now:       ${CURRENT:-<none>}" >&2
      echo "Refusing to run either. Review .archeflow/config.yaml, then run your tests yourself." >&2
      exit 2
    fi
  else
    echo "ERROR: no test command recorded for run ${RUN_ID} (${RECORDED} is missing)." >&2
    echo "Refusing to run an unverified command; run your tests yourself or pass --test-cmd." >&2
    exit 2
  fi
fi

if [[ -z "$TEST_CMD" ]]; then
  echo "ERROR: No test command specified (use --test-cmd or set test_command in .archeflow/config.yaml)" >&2
  exit 2
fi

# Only this run's ArcheFlow merge commit may be reverted (see header).
HEAD_MSG=$(git log -1 --format=%s HEAD 2>/dev/null || true)
EXPECTED_MSG="archeflow: merge run ${RUN_ID}"
LEGACY_MSG="feat: archeflow run ${RUN_ID} complete"
CAN_REVERT=false
if [[ "$HEAD_MSG" == "$EXPECTED_MSG" || "$HEAD_MSG" == "$LEGACY_MSG" ]]; then
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

TEST_RC=0
_portable_timeout 300 bash -c "$TEST_CMD" || TEST_RC=$?
if [[ "$TEST_RC" -eq 0 ]]; then
  echo "Tests passed — merge is good."
  exit 0
fi

# 126/127: the command itself could not run (not found, not executable). That is
# a configuration problem, not evidence that the merged code is broken.
if [[ "$TEST_RC" -eq 126 || "$TEST_RC" -eq 127 ]]; then
  echo "test command not found / not executable: $TEST_CMD — configuration problem, nothing reverted" >&2
  exit 2
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
    "{\"what\":\"post_merge_test\",\"chosen\":\"revert\",\"rationale\":\"test suite failed after merge\"}"
fi

REVERT_HASH=$(git rev-parse --short HEAD)
echo "Merge reverted (commit: $REVERT_HASH). Tests must pass before re-merging."
exit 1
