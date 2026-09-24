# Tests for archeflow-score.sh — archetype effectiveness scoring.
#
# Validates: score extraction from events, report generation, input validation.

setup() {
  load test_helper
  _common_setup

  # Create a complete run events file with review data
  mkdir -p .archeflow/events .archeflow/memory
  cat > "$BATS_TEST_TMPDIR/scored-events.jsonl" <<'EVENTS'
{"ts":"2026-04-03T10:00:00Z","run_id":"score-run","seq":1,"parent":[],"type":"run.start","phase":"plan","agent":null,"data":{"task":"Score test"}}
{"ts":"2026-04-03T10:01:00Z","run_id":"score-run","seq":2,"parent":[1],"type":"agent.complete","phase":"plan","agent":"creator","data":{"archetype":"creator","duration_ms":60000,"tokens":1500,"estimated_cost_usd":0.02}}
{"ts":"2026-04-03T10:02:00Z","run_id":"score-run","seq":3,"parent":[2],"type":"agent.complete","phase":"do","agent":"maker","data":{"archetype":"maker","duration_ms":120000,"tokens":3000,"estimated_cost_usd":0.05}}
{"ts":"2026-04-03T10:03:00Z","run_id":"score-run","seq":4,"parent":[3],"type":"review.verdict","phase":"check","agent":"guardian","data":{"archetype":"guardian","verdict":"needs_changes","findings":[{"severity":"warning","description":"Missing validation","fix_required":true},{"severity":"info","description":"Consider logging","fix_required":false}]}}
{"ts":"2026-04-03T10:03:30Z","run_id":"score-run","seq":5,"parent":[3],"type":"review.verdict","phase":"check","agent":"sage","data":{"archetype":"sage","verdict":"approved","findings":[]}}
{"ts":"2026-04-03T10:04:00Z","run_id":"score-run","seq":6,"parent":[4],"type":"fix.applied","phase":"act","agent":null,"data":{"source":"guardian","finding":"Missing validation"}}
{"ts":"2026-04-03T10:05:00Z","run_id":"score-run","seq":7,"parent":[6],"type":"cycle.boundary","phase":"act","agent":null,"data":{"cycle":1,"max_cycles":3,"met":true,"next_action":"merge"}}
{"ts":"2026-04-03T10:06:00Z","run_id":"score-run","seq":8,"parent":[7],"type":"run.complete","phase":"act","agent":null,"data":{"status":"completed","cycles":1,"agents_total":4,"fixes_total":1}}
EVENTS
}

@test "score: exits 1 with usage when called with no args" {
  run "$LIB_DIR/archeflow-score.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "score: exits 1 for unknown command" {
  run "$LIB_DIR/archeflow-score.sh" nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown command"* ]]
}

@test "score extract: exits 1 when events file not found" {
  run "$LIB_DIR/archeflow-score.sh" extract nonexistent.jsonl
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "score extract: exits 1 for incomplete run (no run.complete)" {
  cat > "$BATS_TEST_TMPDIR/incomplete.jsonl" <<'EVENTS'
{"ts":"2026-04-03T10:00:00Z","run_id":"incomplete","seq":1,"parent":[],"type":"run.start","phase":"plan","agent":null,"data":{"task":"Incomplete"}}
EVENTS
  run "$LIB_DIR/archeflow-score.sh" extract "$BATS_TEST_TMPDIR/incomplete.jsonl"
  [ "$status" -eq 1 ]
  [[ "$output" == *"run.complete"* ]]
}

@test "score extract: creates effectiveness.jsonl with archetype scores" {
  run "$LIB_DIR/archeflow-score.sh" extract "$BATS_TEST_TMPDIR/scored-events.jsonl"
  [ "$status" -eq 0 ]
  [ -f ".archeflow/memory/effectiveness.jsonl" ]

  # Should have scores for guardian and sage (the reviewers)
  local guardian_score
  guardian_score=$(grep '"guardian"' ".archeflow/memory/effectiveness.jsonl" | head -1)
  [ -n "$guardian_score" ]

  # Verify JSONL is valid
  while IFS= read -r line; do
    echo "$line" | jq empty
  done < ".archeflow/memory/effectiveness.jsonl"
}

@test "score extract: guardian has correct finding counts" {
  "$LIB_DIR/archeflow-score.sh" extract "$BATS_TEST_TMPDIR/scored-events.jsonl" 2>/dev/null
  local guardian
  guardian=$(grep '"guardian"' ".archeflow/memory/effectiveness.jsonl" | head -1)
  local total_findings
  total_findings=$(echo "$guardian" | jq '.findings_total')
  [ "$total_findings" -eq 2 ]
  local useful_findings
  useful_findings=$(echo "$guardian" | jq '.findings_useful')
  [ "$useful_findings" -eq 1 ]
  local fixes
  fixes=$(echo "$guardian" | jq '.fixes_applied')
  [ "$fixes" -eq 1 ]
}

@test "score extract: composite score is between 0 and 1" {
  "$LIB_DIR/archeflow-score.sh" extract "$BATS_TEST_TMPDIR/scored-events.jsonl" 2>/dev/null
  [ -s ".archeflow/memory/effectiveness.jsonl" ]
  # jq instead of bc: bc is not installed on stock CI runners.
  jq -se 'length > 0 and all(.[]; .composite_score >= 0 and .composite_score <= 1)' \
    ".archeflow/memory/effectiveness.jsonl"
}

@test "score report: exits 1 when no effectiveness data" {
  run "$LIB_DIR/archeflow-score.sh" report
  [ "$status" -eq 1 ]
  [[ "$output" == *"No effectiveness data"* ]]
}

@test "score report: outputs markdown table with archetype data" {
  "$LIB_DIR/archeflow-score.sh" extract "$BATS_TEST_TMPDIR/scored-events.jsonl" 2>/dev/null
  run "$LIB_DIR/archeflow-score.sh" report
  [ "$status" -eq 0 ]
  [[ "$output" == *"Archetype Effectiveness Report"* ]]
  [[ "$output" == *"Archetype"* ]]
  [[ "$output" == *"guardian"* ]]
}
