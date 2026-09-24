# Tests for archeflow-replay.sh — timeline, what-if, and compare modes.

setup() {
  load test_helper
  _common_setup

  mkdir -p .archeflow/events
  cat > ".archeflow/events/replay-run.jsonl" <<'EVENTS'
{"ts":"2026-04-03T10:00:00Z","run_id":"replay-run","seq":1,"parent":[],"type":"run.start","phase":"plan","agent":null,"data":{"task":"replay test"}}
{"ts":"2026-04-03T10:05:00Z","run_id":"replay-run","seq":2,"parent":[1],"type":"decision.point","phase":"check","agent":"guardian","data":{"archetype":"guardian","input":"diff","decision":"needs_changes","confidence":0.88}}
{"ts":"2026-04-03T10:06:00Z","run_id":"replay-run","seq":3,"parent":[1],"type":"review.verdict","phase":"check","agent":"guardian","data":{"archetype":"guardian","verdict":"needs_changes","findings":[]}}
{"ts":"2026-04-03T10:07:00Z","run_id":"replay-run","seq":4,"parent":[1],"type":"review.verdict","phase":"check","agent":"sage","data":{"archetype":"sage","verdict":"approved","findings":[]}}
{"ts":"2026-04-03T10:08:00Z","run_id":"replay-run","seq":5,"parent":[1],"type":"run.complete","phase":"act","agent":null,"data":{"agents_total":2,"fixes_total":0}}
EVENTS
}

@test "replay: usage without args" {
  run "$LIB_DIR/archeflow-replay.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "replay: timeline shows decision.point" {
  run "$LIB_DIR/archeflow-replay.sh" timeline replay-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision.point"* ]]
  [[ "$output" == *"guardian"* ]]
  [[ "$output" == *"needs_changes"* ]]
}

@test "replay: whatif strict blocks when any reviewer blocks" {
  run "$LIB_DIR/archeflow-replay.sh" whatif replay-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCK"* ]]
}

@test "replay: whatif weighted can ship when blocker is down-weighted" {
  run "$LIB_DIR/archeflow-replay.sh" whatif replay-run --weights guardian=0.2,sage=3
  [ "$status" -eq 0 ]
  [[ "$output" == *"Weighted replay"* ]] || [[ "$output" == *"SHIP"* ]]
  [[ "$output" == *"SHIP"* ]]
}

@test "replay: whatif --json is valid JSON" {
  run "$LIB_DIR/archeflow-replay.sh" whatif replay-run --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.run_id == "replay-run"' >/dev/null
}

@test "replay: compare includes timeline and whatif" {
  run "$LIB_DIR/archeflow-replay.sh" compare replay-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Decision timeline"* ]]
  [[ "$output" == *"What-if replay"* ]]
}

@test "decision: logs decision.point via wrapper" {
  run "$LIB_DIR/archeflow-decision.sh" replay-run check trickster 'diff only' 'edge_case' 0.61 1
  [ "$status" -eq 0 ]
  last=$(jq -r 'select(.type=="decision.point") | .data.decision' ".archeflow/events/replay-run.jsonl" | tail -1)
  [ "$last" = "edge_case" ]
}
