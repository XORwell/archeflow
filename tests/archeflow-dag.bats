# Tests for archeflow-dag.sh — ASCII DAG rendering from JSONL events.
#
# Validates: basic rendering, parent relationships, color flags, missing file handling.

setup() {
  load test_helper
  _common_setup

  # Create a standard events file with parent relationships
  cat > "$BATS_TEST_TMPDIR/dag-events.jsonl" <<'EVENTS'
{"ts":"2026-04-03T10:00:00Z","run_id":"dag-run","seq":1,"parent":[],"type":"run.start","phase":"plan","agent":null,"data":{"task":"DAG test"}}
{"ts":"2026-04-03T10:01:00Z","run_id":"dag-run","seq":2,"parent":[1],"type":"agent.complete","phase":"plan","agent":"creator","data":{"archetype":"creator","duration_ms":60000,"tokens":1500}}
{"ts":"2026-04-03T10:02:00Z","run_id":"dag-run","seq":3,"parent":[2],"type":"phase.transition","phase":"do","agent":null,"data":{"from":"plan","to":"do"}}
{"ts":"2026-04-03T10:03:00Z","run_id":"dag-run","seq":4,"parent":[3],"type":"agent.complete","phase":"do","agent":"maker","data":{"archetype":"maker","duration_ms":120000,"tokens":3000}}
{"ts":"2026-04-03T10:04:00Z","run_id":"dag-run","seq":5,"parent":[4],"type":"run.complete","phase":"act","agent":null,"data":{"agents_total":2,"fixes_total":0}}
EVENTS
}

@test "dag: exits 1 with usage when called with no args" {
  run "$LIB_DIR/archeflow-dag.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "dag: exits 1 when events file not found" {
  run "$LIB_DIR/archeflow-dag.sh" nonexistent.jsonl
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "dag: renders run.start as root node" {
  run "$LIB_DIR/archeflow-dag.sh" "$BATS_TEST_TMPDIR/dag-events.jsonl" --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"#1"* ]]
  [[ "$output" == *"run.start"* ]]
}

@test "dag: renders agent.complete events with archetype name" {
  run "$LIB_DIR/archeflow-dag.sh" "$BATS_TEST_TMPDIR/dag-events.jsonl" --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"creator"* ]]
  [[ "$output" == *"maker"* ]]
}

@test "dag: renders phase transitions" {
  run "$LIB_DIR/archeflow-dag.sh" "$BATS_TEST_TMPDIR/dag-events.jsonl" --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan"* ]]
  [[ "$output" == *"do"* ]]
}

@test "dag: renders run.complete with agent/fix counts" {
  run "$LIB_DIR/archeflow-dag.sh" "$BATS_TEST_TMPDIR/dag-events.jsonl" --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"run.complete"* ]]
  [[ "$output" == *"2 agents"* ]]
}

@test "dag: --no-color suppresses ANSI codes" {
  run "$LIB_DIR/archeflow-dag.sh" "$BATS_TEST_TMPDIR/dag-events.jsonl" --no-color
  [ "$status" -eq 0 ]
  # Should not contain escape sequences
  [[ "$output" != *$'\033'* ]]
}

@test "dag: uses tree-drawing characters for hierarchy" {
  run "$LIB_DIR/archeflow-dag.sh" "$BATS_TEST_TMPDIR/dag-events.jsonl" --no-color
  [ "$status" -eq 0 ]
  # Should contain box-drawing characters (either unicode or ASCII connectors)
  [[ "$output" == *"├"* ]] || [[ "$output" == *"└"* ]]
}

@test "dag: events without parents are still drawn (regression: only #1 was rendered)" {
  cat > "$BATS_TEST_TMPDIR/flat.jsonl" <<'EVENTS'
{"ts":"2026-04-03T10:00:00Z","run_id":"f","seq":1,"parent":[],"type":"run.start","phase":"plan","agent":null,"data":{}}
{"ts":"2026-04-03T10:01:00Z","run_id":"f","seq":2,"parent":[],"type":"cycle.boundary","phase":"act","agent":null,"data":{"cycle":1,"max_cycles":1,"decision":"merge"}}
{"ts":"2026-04-03T10:02:00Z","run_id":"f","seq":3,"parent":[],"type":"run.complete","phase":"act","agent":null,"data":{"agents_total":3}}
{"ts":"2026-04-03T10:02:00Z","run_id":"f","seq":4,"parent":[99],"type":"agent.complete","phase":"act","agent":"sage","data":{}}
EVENTS
  run "$LIB_DIR/archeflow-dag.sh" "$BATS_TEST_TMPDIR/flat.jsonl" --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"#2"*"cycle 1/1 → merge"* ]]
  [[ "$output" == *"#3"*"run.complete"* ]]
  [[ "$output" == *"#4"*"sage"* ]]
}

@test "dag: events written without parents by archeflow-event.sh form a tree" {
  for e in "run.start plan -" "agent.start plan creator" "agent.complete plan creator" \
           "agent.start check guardian" "review.verdict check guardian" "cycle.boundary act -"; do
    read -r t p a <<<"$e"; [[ "$a" == "-" ]] && a=""
    "$LIB_DIR/archeflow-event.sh" tree "$t" "$p" "$a" '{"archetype":"x","verdict":"APPROVED"}' 2>/dev/null
  done
  run "$LIB_DIR/archeflow-dag.sh" .archeflow/events/tree.jsonl --no-color
  [ "$status" -eq 0 ]
  # agent.complete (#3) is nested one level below its agent.start (#2)
  [[ "$output" == *"#2  "*$'\n'"    └── #3 "* ]] || [[ "$output" == *$'\n'"│   └── #3 "* ]]
  [ "$(grep -c '#' <<<"$output")" -eq 6 ]
}
