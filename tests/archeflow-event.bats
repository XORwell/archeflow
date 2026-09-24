# Tests for archeflow-event.sh — structured JSONL event logging.
#
# Validates: JSONL output format, sequence numbering, parent field handling,
# input validation, file/directory creation.

setup() {
  load test_helper
  _common_setup
}

teardown() {
  _common_teardown
}

@test "event: exits 1 with usage when called with fewer than 4 args" {
  run "$LIB_DIR/archeflow-event.sh" run1 type1 plan
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "event: creates events directory and file on first call" {
  run "$LIB_DIR/archeflow-event.sh" test-run run.start plan "" '{"task":"test"}'
  [ "$status" -eq 0 ]
  [ -d ".archeflow/events" ]
  [ -f ".archeflow/events/test-run.jsonl" ]
}

@test "event: first event has seq=1" {
  run "$LIB_DIR/archeflow-event.sh" test-run run.start plan "" '{"task":"test"}'
  [ "$status" -eq 0 ]
  local seq
  seq=$(head -1 ".archeflow/events/test-run.jsonl" | jq -r '.seq')
  [ "$seq" -eq 1 ]
}

@test "event: second event has seq=2" {
  "$LIB_DIR/archeflow-event.sh" test-run run.start plan "" '{"task":"test"}' 2>/dev/null
  "$LIB_DIR/archeflow-event.sh" test-run agent.complete plan creator '{"dur":100}' "1" 2>/dev/null
  local count
  count=$(wc -l < ".archeflow/events/test-run.jsonl")
  [ "$count" -eq 2 ]
  local seq2
  seq2=$(tail -1 ".archeflow/events/test-run.jsonl" | jq -r '.seq')
  [ "$seq2" -eq 2 ]
}

@test "event: output is valid JSONL" {
  "$LIB_DIR/archeflow-event.sh" test-run run.start plan "" '{"task":"hello"}' 2>/dev/null
  # jq will fail if the line is not valid JSON
  jq empty ".archeflow/events/test-run.jsonl"
}

@test "event: fields are correctly populated" {
  "$LIB_DIR/archeflow-event.sh" test-run agent.complete do maker '{"tokens":500}' 2>/dev/null
  local event
  event=$(head -1 ".archeflow/events/test-run.jsonl")
  [ "$(echo "$event" | jq -r '.run_id')" = "test-run" ]
  [ "$(echo "$event" | jq -r '.type')" = "agent.complete" ]
  [ "$(echo "$event" | jq -r '.phase')" = "do" ]
  [ "$(echo "$event" | jq -r '.agent')" = "maker" ]
  [ "$(echo "$event" | jq -r '.data.tokens')" = "500" ]
}

@test "event: empty agent becomes null in JSON" {
  "$LIB_DIR/archeflow-event.sh" test-run phase.transition do "" '{"from":"plan","to":"do"}' 2>/dev/null
  local agent
  agent=$(head -1 ".archeflow/events/test-run.jsonl" | jq -r '.agent')
  [ "$agent" = "null" ]
}

@test "event: parent field is empty array for root events" {
  "$LIB_DIR/archeflow-event.sh" test-run run.start plan "" '{}' 2>/dev/null
  local parent
  parent=$(head -1 ".archeflow/events/test-run.jsonl" | jq -c '.parent')
  [ "$parent" = "[]" ]
}

@test "event: single parent is parsed correctly" {
  "$LIB_DIR/archeflow-event.sh" test-run run.start plan "" '{}' 2>/dev/null
  "$LIB_DIR/archeflow-event.sh" test-run agent.complete plan creator '{}' "1" 2>/dev/null
  local parent
  parent=$(tail -1 ".archeflow/events/test-run.jsonl" | jq -c '.parent')
  [ "$parent" = "[1]" ]
}

@test "event: multiple parents (fan-in) are parsed correctly" {
  "$LIB_DIR/archeflow-event.sh" test-run run.start plan "" '{}' 2>/dev/null
  "$LIB_DIR/archeflow-event.sh" test-run a plan "" '{}' "1" 2>/dev/null
  "$LIB_DIR/archeflow-event.sh" test-run b plan "" '{}' "1" 2>/dev/null
  "$LIB_DIR/archeflow-event.sh" test-run merge plan "" '{}' "2,3" 2>/dev/null
  local parent
  parent=$(tail -1 ".archeflow/events/test-run.jsonl" | jq -c '.parent')
  [ "$parent" = "[2,3]" ]
}

@test "event: rejects invalid JSON data" {
  run "$LIB_DIR/archeflow-event.sh" test-run run.start plan "" 'not-json'
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid JSON"* ]]
}

@test "event: rejects invalid parent format" {
  run "$LIB_DIR/archeflow-event.sh" test-run run.start plan "" '{}' "abc"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid parent format"* ]]
}

@test "event: timestamp is ISO 8601 UTC format" {
  "$LIB_DIR/archeflow-event.sh" test-run run.start plan "" '{}' 2>/dev/null
  local ts
  ts=$(head -1 ".archeflow/events/test-run.jsonl" | jq -r '.ts')
  # Matches YYYY-MM-DDTHH:MM:SSZ
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "event: default data is empty object when omitted" {
  "$LIB_DIR/archeflow-event.sh" test-run run.start plan agent 2>/dev/null
  local data
  data=$(head -1 ".archeflow/events/test-run.jsonl" | jq -c '.data')
  [ "$data" = "{}" ]
}

@test "event: confirmation message goes to stderr" {
  run "$LIB_DIR/archeflow-event.sh" test-run run.start plan "" '{}' "" 2>&1
  [[ "$output" == *"[archeflow-event]"* ]]
  [[ "$output" == *"#1"* ]]
}

@test "event: rejects run_id with path traversal" {
  run "$LIB_DIR/archeflow-event.sh" "../../escape" run.start plan "" '{}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid run_id"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/escape.jsonl" ]
  [ ! -e "$BATS_TEST_TMPDIR/../escape.jsonl" ]
}

@test "event: rejects run_id starting with a dash" {
  run "$LIB_DIR/archeflow-event.sh" "-rf" run.start plan "" '{}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid run_id"* ]]
}

@test "event: accepts the documented YYYY-MM-DD-slug run_id format" {
  run "$LIB_DIR/archeflow-event.sh" "2026-09-24-fix_auth.v2" run.start plan "" '{}'
  [ "$status" -eq 0 ]
  [ -f ".archeflow/events/2026-09-24-fix_auth.v2.jsonl" ]
}

@test "event: parallel emitters get unique, gapless seq numbers" {
  for i in $(seq 1 20); do
    "$LIB_DIR/archeflow-event.sh" par-run agent.start plan "a$i" '{}' 2>/dev/null &
  done
  wait
  [ "$(wc -l < .archeflow/events/par-run.jsonl | tr -d ' ')" -eq 20 ]
  [ "$(jq -s '[.[].seq] | unique | length' .archeflow/events/par-run.jsonl)" -eq 20 ]
  [ "$(jq -s '[.[].seq] | max' .archeflow/events/par-run.jsonl)" -eq 20 ]
}

@test "event: mkdir lock fallback works when flock is unavailable" {
  source "$LIB_DIR/archeflow-lock.sh"
  flock() { return 127; }
  command() { if [[ "$1" == "-v" && "$2" == "flock" ]]; then return 1; fi; builtin command "$@"; }
  af_lock "$BATS_TEST_TMPDIR/x.lock" 1
  [ -d "$BATS_TEST_TMPDIR/x.lock.d" ]
  run af_lock "$BATS_TEST_TMPDIR/x.lock" 1
  [ "$status" -ne 0 ]
  af_unlock "$BATS_TEST_TMPDIR/x.lock"
  [ ! -d "$BATS_TEST_TMPDIR/x.lock.d" ]
}

@test "event: refuses to append through a symlinked event log" {
  mkdir -p .archeflow/events
  echo keep > "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" .archeflow/events/r-link.jsonl
  run "$LIB_DIR/archeflow-event.sh" r-link run.start plan "" '{}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = "keep" ]
}

@test "event: refuses a symlinked lock file" {
  mkdir -p .archeflow/events
  ln -s "$BATS_TEST_TMPDIR/elsewhere" .archeflow/events/r-lock.jsonl.lock
  run "$LIB_DIR/archeflow-event.sh" r-lock run.start plan "" '{}'
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere" ]
}
