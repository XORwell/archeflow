# Tests for archeflow-a2a.sh — Agent Card generation, validation, serve args.

setup() {
  load test_helper
  _common_setup
}

teardown() {
  _common_teardown
}

@test "a2a: generate writes a card that validate accepts" {
  run "$LIB_DIR/archeflow-a2a.sh" generate
  [ "$status" -eq 0 ]
  run "$LIB_DIR/archeflow-a2a.sh" validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"valid"* ]]
}

@test "a2a: serve rejects a non-numeric port" {
  run "$LIB_DIR/archeflow-a2a.sh" serve --port abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid port"* ]]
}

@test "a2a: serve --port without a value fails instead of using '--port' as the port" {
  run "$LIB_DIR/archeflow-a2a.sh" serve --port
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a value"* ]]
}

@test "a2a: serve rejects out-of-range ports and unknown options" {
  run "$LIB_DIR/archeflow-a2a.sh" serve --port 70000
  [ "$status" -ne 0 ]
  run "$LIB_DIR/archeflow-a2a.sh" serve --evil
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown serve option"* ]]
}
