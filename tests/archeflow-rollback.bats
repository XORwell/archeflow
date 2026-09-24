# Tests for archeflow-rollback.sh — post-merge test and phase rollback.
#
# Validates: argument parsing, mutual exclusivity, phase validation, test-cmd config reading.

setup() {
  load test_helper
  _common_setup
}

teardown() {
  _common_teardown
}

@test "rollback: exits with error when called with no args" {
  run "$LIB_DIR/archeflow-rollback.sh"
  [ "$status" -ne 0 ]
}

@test "rollback: rejects mutually exclusive --to and --test-cmd" {
  run "$LIB_DIR/archeflow-rollback.sh" test-run --to plan --test-cmd "true"
  [ "$status" -eq 2 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "rollback: rejects invalid phase names" {
  run "$LIB_DIR/archeflow-rollback.sh" test-run --to invalid-phase
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid phase"* ]]
}

@test "rollback: accepts valid phase names (plan, do, check)" {
  # This will fail because no git branch exists, but should NOT fail on phase validation
  run "$LIB_DIR/archeflow-rollback.sh" test-run --to plan
  # Should fail later (archeflow-git.sh rollback) not on phase validation
  [[ "$output" != *"Invalid phase"* ]]
}

@test "rollback: exits 2 when no test command available" {
  run "$LIB_DIR/archeflow-rollback.sh" test-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"No test command"* ]]
}

@test "rollback: reads test_command from config.yaml" {
  mkdir -p .archeflow
  echo 'test_command: "echo ok"' > .archeflow/config.yaml
  # HEAD is not an ArcheFlow merge: tests still run (auto-revert is disabled)
  run "$LIB_DIR/archeflow-rollback.sh" test-run
  # It should pick up the command and try to run it (test should pass -> exit 0)
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tests passed"* ]]
}

@test "rollback: rejects unknown options" {
  run "$LIB_DIR/archeflow-rollback.sh" test-run --unknown-flag
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option"* ]]
}

# squash_merge_run <run_id>: an ArcheFlow squash merge of a run branch onto main,
# with the exact commit subject archeflow-git.sh merge produces.
squash_merge_run() {
  git checkout --quiet -b "archeflow/$1"
  echo feature > feature.txt
  git add feature.txt
  git commit --quiet -m "do: feature"
  git checkout --quiet main
  git merge --squash --quiet "archeflow/$1"
  git commit --quiet -m "feat: archeflow run $1 complete"
}

@test "rollback: failing tests revert this run's ArcheFlow squash merge" {
  squash_merge_run r1
  run "$LIB_DIR/archeflow-rollback.sh" r1 --test-cmd "false"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Merge reverted"* ]]
  [ ! -f feature.txt ]
  [[ "$(git log -1 --format=%s)" == Revert* ]]
  # a decision event documents the revert
  jq -e 'select(.type == "decision.point" or .type == "decision") | .data.chosen == "revert"' .archeflow/events/r1.jsonl
}

@test "rollback: failing tests revert an ArcheFlow no-ff merge commit" {
  git checkout --quiet -b archeflow/r2
  echo feature > feature.txt
  git add feature.txt && git commit --quiet -m "do: feature"
  git checkout --quiet main
  git merge --no-ff --quiet -m "feat: archeflow run r2 complete" archeflow/r2
  run "$LIB_DIR/archeflow-rollback.sh" r2 --test-cmd "false"
  [ "$status" -eq 1 ]
  [ ! -f feature.txt ]
}

@test "rollback: never reverts a commit that is not this run's ArcheFlow merge" {
  echo mine > mine.txt
  git add mine.txt && git commit --quiet -m "my own work mentioning archeflow and r3"
  head_before=$(git rev-parse HEAD)
  run "$LIB_DIR/archeflow-rollback.sh" r3 --test-cmd "false"
  [ "$status" -eq 3 ]
  [[ "$output" == *"refusing to revert"* ]]
  [ "$(git rev-parse HEAD)" = "$head_before" ]
  [ -f mine.txt ]
}

@test "rollback: another run's merge commit is not reverted" {
  squash_merge_run other
  head_before=$(git rev-parse HEAD)
  run "$LIB_DIR/archeflow-rollback.sh" r4 --test-cmd "false"
  [ "$status" -eq 3 ]
  [ "$(git rev-parse HEAD)" = "$head_before" ]
}

@test "rollback: passing tests leave the merge in place" {
  squash_merge_run r5
  run "$LIB_DIR/archeflow-rollback.sh" r5 --test-cmd "true"
  [ "$status" -eq 0 ]
  [ -f feature.txt ]
}
