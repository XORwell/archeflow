# Tests for archeflow-decision.sh — decision.point event wrapper.

setup() {
  load test_helper
  _common_setup
}

teardown() {
  _common_teardown
}

@test "decision: exits 1 with usage on fewer than 6 args" {
  run "$LIB_DIR/archeflow-decision.sh" run1 check guardian "input"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "decision: creates decision.point event in JSONL" {
  run "$LIB_DIR/archeflow-decision.sh" test-run check guardian \
    'diff analysis' 'needs_changes' 0.82
  [ "$status" -eq 0 ]
  [ -f ".archeflow/events/test-run.jsonl" ]
  local event_type
  event_type=$(head -1 ".archeflow/events/test-run.jsonl" | jq -r '.type')
  [ "$event_type" = "decision.point" ]
}

@test "decision: event data contains archetype, input, decision, confidence" {
  "$LIB_DIR/archeflow-decision.sh" test-run check guardian \
    'test input' 'approve' 0.95 2>/dev/null
  local data
  data=$(head -1 ".archeflow/events/test-run.jsonl" | jq -c '.data')
  [ "$(echo "$data" | jq -r '.archetype')" = "guardian" ]
  [ "$(echo "$data" | jq -r '.input')" = "test input" ]
  [ "$(echo "$data" | jq -r '.decision')" = "approve" ]
  [ "$(echo "$data" | jq '.confidence')" = "0.95" ]
}

@test "decision: phase is passed through to event" {
  "$LIB_DIR/archeflow-decision.sh" test-run act "" \
    'route findings' 'send_to_maker' 0.9 2>/dev/null
  local phase
  phase=$(head -1 ".archeflow/events/test-run.jsonl" | jq -r '.phase')
  [ "$phase" = "act" ]
}

@test "decision: parent seq is forwarded to event layer" {
  "$LIB_DIR/archeflow-decision.sh" test-run plan "" 'input' 'decide' 0.5 2>/dev/null
  "$LIB_DIR/archeflow-decision.sh" test-run check guardian 'input' 'approve' 0.8 1 2>/dev/null
  local parent
  parent=$(tail -1 ".archeflow/events/test-run.jsonl" | jq -c '.parent')
  [ "$parent" = "[1]" ]
}

@test "decision: rejects non-numeric confidence" {
  run "$LIB_DIR/archeflow-decision.sh" test-run check guardian \
    'input' 'decide' 'high'
  [ "$status" -eq 1 ]
  [[ "$output" == *"confidence must be a number"* ]]
}
