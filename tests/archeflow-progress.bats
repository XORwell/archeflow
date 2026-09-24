# Tests for archeflow-progress.sh — live progress file generation.
#
# Validates: markdown output structure, JSON mode, missing events handling, exit codes.

setup() {
  load test_helper
  _common_setup

  # Create standard events for progress tests
  mkdir -p .archeflow/events
  cat > ".archeflow/events/test-run.jsonl" <<'EVENTS'
{"ts":"2026-04-03T10:00:00Z","run_id":"test-run","seq":1,"parent":[],"type":"run.start","phase":"plan","agent":null,"data":{"task":"Build feature","workflow":"standard","team":"default"}}
{"ts":"2026-04-03T10:01:00Z","run_id":"test-run","seq":2,"parent":[1],"type":"agent.complete","phase":"plan","agent":"creator","data":{"archetype":"creator","duration_ms":60000,"tokens":1500,"estimated_cost_usd":0.02,"summary":"Planned"}}
EVENTS
}

@test "progress: exits 1 with usage when called with no args" {
  run "$LIB_DIR/archeflow-progress.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "progress: exits 1 when events file not found" {
  run "$LIB_DIR/archeflow-progress.sh" nonexistent-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "progress: default mode generates progress.md" {
  run "$LIB_DIR/archeflow-progress.sh" test-run
  [ "$status" -eq 0 ]
  [ -f ".archeflow/progress.md" ]
  [[ "$output" == *"# ArcheFlow Run: test-run"* ]]
  [[ "$output" == *"Status:"* ]]
  [[ "$output" == *"Progress"* ]]
}

@test "progress: json mode outputs valid JSON" {
  run "$LIB_DIR/archeflow-progress.sh" test-run --json
  [ "$status" -eq 0 ]
  echo "$output" | jq empty
  local run_id
  run_id=$(echo "$output" | jq -r '.run_id')
  [ "$run_id" = "test-run" ]
}

@test "progress: json mode includes completed agents" {
  run "$LIB_DIR/archeflow-progress.sh" test-run --json
  [ "$status" -eq 0 ]
  local completed_count
  completed_count=$(echo "$output" | jq '.completed | length')
  [ "$completed_count" -eq 1 ]
  local agent
  agent=$(echo "$output" | jq -r '.completed[0].agent')
  [ "$agent" = "creator" ]
}

@test "progress: json mode shows correct phase" {
  run "$LIB_DIR/archeflow-progress.sh" test-run --json
  [ "$status" -eq 0 ]
  local phase
  phase=$(echo "$output" | jq -r '.phase')
  [ "$phase" = "plan" ]
}

@test "progress: reports error in json when events file missing" {
  run "$LIB_DIR/archeflow-progress.sh" missing-run --json
  # JSON mode returns the JSON even on error
  local error
  error=$(echo "$output" | jq -r '.error // empty')
  [[ "$error" == *"not found"* ]]
}

@test "progress: rejects unknown flags" {
  run "$LIB_DIR/archeflow-progress.sh" test-run --invalid
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown flag"* ]]
}

@test "progress: missing-run JSON error is valid JSON even with quotes in context" {
  run "$LIB_DIR/archeflow-progress.sh" "no-such-run" --json
  [[ "$output" == *"Event file not found"* ]]
  echo "$output" | grep 'Event file not found' | jq -e '.run_id == "no-such-run"'
}

@test "progress: rejects run_id with path separators" {
  run "$LIB_DIR/archeflow-progress.sh" "a/b" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid run_id"* ]]
}
