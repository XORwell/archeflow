# Tests for archeflow-report.sh — Markdown process report generation from JSONL events.
#
# Validates: report output format, summary mode, missing file handling, jq dependency check.

setup() {
  load test_helper
  _common_setup

  # Create a standard events file used by multiple tests
  mkdir -p .archeflow/events
  cat > "$BATS_TEST_TMPDIR/events.jsonl" <<'EVENTS'
{"ts":"2026-04-03T10:00:00Z","run_id":"test-run","seq":1,"parent":[],"type":"run.start","phase":"plan","agent":null,"data":{"task":"Write unit tests","workflow":"standard","team":"default"}}
{"ts":"2026-04-03T10:01:00Z","run_id":"test-run","seq":2,"parent":[1],"type":"agent.complete","phase":"plan","agent":"creator","data":{"archetype":"creator","duration_ms":60000,"tokens":1500,"summary":"Designed test structure"}}
{"ts":"2026-04-03T10:02:00Z","run_id":"test-run","seq":3,"parent":[2],"type":"phase.transition","phase":"do","agent":null,"data":{"from":"plan","to":"do"}}
{"ts":"2026-04-03T10:05:00Z","run_id":"test-run","seq":4,"parent":[3],"type":"agent.complete","phase":"do","agent":"maker","data":{"archetype":"maker","duration_ms":180000,"tokens":3000,"summary":"Implemented tests"}}
{"ts":"2026-04-03T10:06:00Z","run_id":"test-run","seq":5,"parent":[4],"type":"phase.transition","phase":"check","agent":null,"data":{"from":"do","to":"check"}}
{"ts":"2026-04-03T10:07:00Z","run_id":"test-run","seq":6,"parent":[5],"type":"review.verdict","phase":"check","agent":"guardian","data":{"archetype":"guardian","verdict":"approved","findings":[]}}
{"ts":"2026-04-03T10:08:00Z","run_id":"test-run","seq":7,"parent":[6],"type":"run.complete","phase":"act","agent":null,"data":{"status":"completed","cycles":1,"agents_total":3,"fixes_total":0,"duration_ms":480000}}
EVENTS
}

@test "report: exits 1 with usage when called with no args" {
  run "$LIB_DIR/archeflow-report.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "report: exits 1 when events file not found" {
  run "$LIB_DIR/archeflow-report.sh" nonexistent.jsonl
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "report: full mode produces markdown with header and overview" {
  run "$LIB_DIR/archeflow-report.sh" "$BATS_TEST_TMPDIR/events.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"# Process Report: Write unit tests"* ]]
  [[ "$output" == *"test-run"* ]]
  [[ "$output" == *"Overview"* ]]
  [[ "$output" == *"Status"* ]]
  [[ "$output" == *"completed"* ]]
}

@test "report: full mode includes phase sections" {
  run "$LIB_DIR/archeflow-report.sh" "$BATS_TEST_TMPDIR/events.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN"* ]]
  [[ "$output" == *"DO"* ]]
  [[ "$output" == *"CHECK"* ]]
}

@test "report: summary mode outputs one-line summary" {
  run "$LIB_DIR/archeflow-report.sh" "$BATS_TEST_TMPDIR/events.jsonl" --summary
  [ "$status" -eq 0 ]
  # Should be a single logical line with key stats
  [[ "$output" == *"[completed]"* ]]
  [[ "$output" == *"Write unit tests"* ]]
  [[ "$output" == *"1 cycles"* ]]
  [[ "$output" == *"test-run"* ]]
}

@test "report: --output writes to file instead of stdout" {
  run "$LIB_DIR/archeflow-report.sh" "$BATS_TEST_TMPDIR/events.jsonl" --output "$BATS_TEST_TMPDIR/report.md"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/report.md" ]
  local content
  content=$(cat "$BATS_TEST_TMPDIR/report.md")
  [[ "$content" == *"# Process Report"* ]]
}

@test "report: summary for in-progress run shows [in-progress]" {
  # Events file without run.complete
  cat > "$BATS_TEST_TMPDIR/in-progress.jsonl" <<'EVENTS'
{"ts":"2026-04-03T10:00:00Z","run_id":"wip-run","seq":1,"parent":[],"type":"run.start","phase":"plan","agent":null,"data":{"task":"WIP task","workflow":"fast","team":"default"}}
EVENTS
  run "$LIB_DIR/archeflow-report.sh" "$BATS_TEST_TMPDIR/in-progress.jsonl" --summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"[in-progress]"* ]]
  [[ "$output" == *"WIP task"* ]]
}
