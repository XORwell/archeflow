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

# ── the fields documented in skills/run/reference.md ───────────────────────

# Events as the run skill emits them (no team, no duration_ms, no parents given).
_documented_run() {
  local E="$LIB_DIR/archeflow-event.sh"
  "$E" doc run.start plan "" '{"task":"Fix average()","workflow":"fast","max_cycles":1}' 2>/dev/null
  "$E" doc agent.start plan creator '{"archetype":"creator","model":"sonnet"}' 2>/dev/null
  "$E" doc agent.complete plan creator '{"archetype":"creator","duration_ms":1000,"artifacts":["plan-creator.md"],"summary":"proposal","estimated_cost_usd":0.01}' 2>/dev/null
  "$E" doc agent.start do maker '{"archetype":"maker","model":"sonnet"}' 2>/dev/null
  "$E" doc agent.complete do maker '{"archetype":"maker","duration_ms":2000,"artifacts":["do-maker.md"],"summary":"fixed","estimated_cost_usd":0.02}' 2>/dev/null
  "$E" doc agent.start check guardian '{"archetype":"guardian","model":"sonnet"}' 2>/dev/null
  "$E" doc agent.complete check guardian '{"archetype":"guardian","duration_ms":1500,"artifacts":["check-guardian.md"],"summary":"ok","estimated_cost_usd":0.01}' 2>/dev/null
  "$E" doc review.verdict check guardian '{"archetype":"guardian","verdict":"APPROVED","findings":[]}' 2>/dev/null
  "$E" doc cycle.boundary act "" '{"cycle":1,"max_cycles":1,"exit_condition":"approved","decision":"merge","critical":0,"warning":0,"info":0}' 2>/dev/null
  "$E" doc run.complete act "" '{"status":"awaiting_merge","cycles":1,"agents_total":3,"fixes_total":0}' 2>/dev/null
}

@test "report: a run logged per reference.md has a team, a duration and an exit condition" {
  _documented_run
  run "$LIB_DIR/archeflow-report.sh" .archeflow/events/doc.jsonl
  [ "$status" -eq 0 ]
  [[ "$output" == *'Team: `creator, maker, guardian`'* ]]
  [[ "$output" == *"| **Duration** | <1 min |"* ]]
  [[ "$output" == *"exit condition: approved (0 CRITICAL, 0 WARNING, 0 INFO) → merge"* ]]
  [[ "$output" != *"unknown"* ]]
  [[ "$output" != *"~0 min"* ]]
  [[ "$output" != *"false →"* ]]
  [[ "$output" == *"- \`plan-creator.md\`"* ]]
  # the process flow is a tree, not a single root line
  [[ "$output" == *"└── #3"* || "$output" == *"│   └── #3"* ]]
}

@test "report: duration comes from the timestamps when run.complete has no duration_ms" {
  cat > "$BATS_TEST_TMPDIR/ts.jsonl" <<'EVENTS'
{"ts":"2026-04-03T10:00:00Z","run_id":"t","seq":1,"parent":[],"type":"run.start","phase":"plan","agent":null,"data":{"task":"T"}}
{"ts":"2026-04-03T10:07:30Z","run_id":"t","seq":2,"parent":[1],"type":"run.complete","phase":"act","agent":null,"data":{"status":"merged","cycles":1}}
EVENTS
  run "$LIB_DIR/archeflow-report.sh" "$BATS_TEST_TMPDIR/ts.jsonl" --summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"(~7 min)"* ]]
}

@test "report: a later run.merged event turns awaiting_merge into merged" {
  _documented_run
  "$LIB_DIR/archeflow-event.sh" doc run.merged act "" '{"base":"main","strategy":"no-ff"}' 2>/dev/null
  run "$LIB_DIR/archeflow-report.sh" .archeflow/events/doc.jsonl --summary
  [ "$status" -eq 0 ]
  [[ "$output" == "[merged]"* ]]
  run "$LIB_DIR/archeflow-report.sh" .archeflow/events/doc.jsonl
  [[ "$output" == *"| **Status** | merged |"* ]]
  [[ "$output" == *"**Merged** into main"* ]]
}

@test "report: pre-0.11 cycle.boundary fields (met, next_action) are still read" {
  cat > "$BATS_TEST_TMPDIR/old.jsonl" <<'EVENTS'
{"ts":"2026-04-03T10:00:00Z","run_id":"o","seq":1,"parent":[],"type":"run.start","phase":"plan","agent":null,"data":{"task":"T","team":"default"}}
{"ts":"2026-04-03T10:01:00Z","run_id":"o","seq":2,"parent":[1],"type":"cycle.boundary","phase":"act","agent":null,"data":{"cycle":1,"max_cycles":2,"met":true,"next_action":"merge"}}
EVENTS
  run "$LIB_DIR/archeflow-report.sh" "$BATS_TEST_TMPDIR/old.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exit condition: met → merge"* ]]
  [[ "$output" == *'Team: `default`'* ]]
}

@test "report: run.start team as a list (as the run skill writes it) is joined" {
  cat > "$BATS_TEST_TMPDIR/team.jsonl" <<'EVENTS'
{"ts":"2026-04-03T10:00:00Z","run_id":"tm","seq":1,"parent":[],"type":"run.start","phase":"plan","agent":null,"data":{"task":"T","team":["creator","maker","guardian"]}}
EVENTS
  run "$LIB_DIR/archeflow-report.sh" "$BATS_TEST_TMPDIR/team.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Team: `creator, maker, guardian`'* ]]
}
