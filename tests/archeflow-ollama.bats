# Tests for archeflow-ollama.sh — local Ollama API helper.

setup() {
  load test_helper
  _common_setup
}

teardown() {
  _common_teardown
}

@test "ollama: exits 1 with usage when called with no args" {
  run "$LIB_DIR/archeflow-ollama.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Commands"* ]] || [[ "$output" == *"chat"* ]]
}

@test "ollama: chat exits non-zero without model" {
  run "$LIB_DIR/archeflow-ollama.sh" chat
  [ "$status" -ne 0 ]
}

@test "ollama: chat exits non-zero on empty stdin" {
  run bash -c 'echo -n "" | '"$LIB_DIR/archeflow-ollama.sh"' chat some-model'
  [ "$status" -ne 0 ]
}

@test "ollama: unknown command" {
  run "$LIB_DIR/archeflow-ollama.sh" not-a-command
  [ "$status" -ne 0 ]
}

@test "ollama: ARCHEFLOW_OLLAMA_BASE_URL sets the base URL" {
  run env -u ARCHFLOW_OLLAMA_BASE_URL ARCHEFLOW_OLLAMA_BASE_URL="http://127.0.0.1:9/" \
    "$LIB_DIR/archeflow-ollama.sh" health
  [ "$status" -ne 0 ]
  [[ "$output" == *"http://127.0.0.1:9/api/tags"* ]]
}

@test "ollama: legacy ARCHFLOW_OLLAMA_BASE_URL is honored as fallback" {
  run env -u ARCHEFLOW_OLLAMA_BASE_URL ARCHFLOW_OLLAMA_BASE_URL="127.0.0.1:7" \
    "$LIB_DIR/archeflow-ollama.sh" health
  [ "$status" -ne 0 ]
  [[ "$output" == *"http://127.0.0.1:7/api/tags"* ]]
}

@test "ollama: canonical ARCHEFLOW_ name wins over legacy ARCHFLOW_ name" {
  run env ARCHEFLOW_OLLAMA_BASE_URL="http://127.0.0.1:9" ARCHFLOW_OLLAMA_BASE_URL="http://127.0.0.1:7" \
    "$LIB_DIR/archeflow-ollama.sh" health
  [ "$status" -ne 0 ]
  [[ "$output" == *"127.0.0.1:9/api/tags"* ]]
  [[ "$output" != *"127.0.0.1:7"* ]]
}

@test "ollama: --system-file without a path fails cleanly" {
  run bash -c 'echo hi | '"$LIB_DIR/archeflow-ollama.sh"' chat m --system-file'
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a path"* ]]
}

@test "ollama: non-local hosts are refused unless the user opts in" {
  run env -u ARCHEFLOW_OLLAMA_ALLOW_REMOTE ARCHEFLOW_OLLAMA_BASE_URL="https://ollama.attacker.example" \
    "$LIB_DIR/archeflow-ollama.sh" health
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing non-local Ollama host"* ]]
  run bash -c 'echo hi | env -u ARCHEFLOW_OLLAMA_ALLOW_REMOTE ARCHEFLOW_OLLAMA_BASE_URL=http://10.0.0.1:11434 '"$LIB_DIR"'/archeflow-ollama.sh chat m'
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing non-local"* ]]
}

@test "ollama: malformed base URLs are rejected" {
  for u in 'http://user:pw@127.0.0.1:1' 'http://127.0.0.1:1;id' 'ftp://127.0.0.1'; do
    run env ARCHEFLOW_OLLAMA_BASE_URL="$u" "$LIB_DIR/archeflow-ollama.sh" health
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid Ollama base URL"* ]]
  done
}

@test "ollama: ARCHEFLOW_OLLAMA_ALLOW_REMOTE=1 permits a remote host" {
  # Point at a closed local port through a non-loopback name that resolves locally is not
  # portable; assert only that the refusal is lifted (curl then fails to connect).
  run env ARCHEFLOW_OLLAMA_ALLOW_REMOTE=1 ARCHEFLOW_OLLAMA_BASE_URL="http://invalid.invalid:1" \
    "$LIB_DIR/archeflow-ollama.sh" health
  [ "$status" -ne 0 ]
  [[ "$output" != *"refusing"* ]]
  [[ "$output" == *"cannot reach http://invalid.invalid:1/api/tags"* ]]
}
