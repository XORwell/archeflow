# Tests for archeflow-memory.sh — cross-run lesson memory management.
#
# Validates: add, list, decay, forget, inject filtering, and JSONL format.

setup() {
  load test_helper
  _common_setup
}

teardown() {
  _common_teardown
}

# --- Usage / error handling ---

@test "memory: exits 1 with usage when called with no args" {
  run "$LIB_DIR/archeflow-memory.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "memory: exits 1 for unknown command" {
  run "$LIB_DIR/archeflow-memory.sh" nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown command"* ]]
}

# --- add ---

@test "memory add: creates lessons.jsonl and appends a valid JSONL line" {
  run "$LIB_DIR/archeflow-memory.sh" add preference "Always validate inputs"
  [ "$status" -eq 0 ]
  [ -f ".archeflow/memory/lessons.jsonl" ]
  jq empty ".archeflow/memory/lessons.jsonl"
}

@test "memory add: lesson has correct fields" {
  "$LIB_DIR/archeflow-memory.sh" add pattern "Guardian misses SQL injection" 2>/dev/null
  [ "$(jq -r '.type' .archeflow/memory/lessons.jsonl)" = "pattern" ]
  [ "$(jq -r '.description' .archeflow/memory/lessons.jsonl)" = "Guardian misses SQL injection" ]
  [ "$(jq -r '.source' .archeflow/memory/lessons.jsonl)" = "user_feedback" ]
  [ "$(jq -r '.frequency' .archeflow/memory/lessons.jsonl)" = "1" ]
  [ "$(jq -r '.run_id' .archeflow/memory/lessons.jsonl)" = "manual" ]
  [ "$(jq -r '.domain' .archeflow/memory/lessons.jsonl)" = "general" ]
}

@test "memory add: generates sequential IDs" {
  "$LIB_DIR/archeflow-memory.sh" add pattern "first lesson" 2>/dev/null
  "$LIB_DIR/archeflow-memory.sh" add pattern "second lesson" 2>/dev/null
  local id1 id2
  id1=$(head -1 ".archeflow/memory/lessons.jsonl" | jq -r '.id')
  id2=$(tail -1 ".archeflow/memory/lessons.jsonl" | jq -r '.id')
  [ "$id1" = "m-001" ]
  [ "$id2" = "m-002" ]
}

@test "memory add: generates tags from description" {
  "$LIB_DIR/archeflow-memory.sh" add pattern "Guardian misses SQL injection attacks" 2>/dev/null
  local tags_count
  tags_count=$(head -1 ".archeflow/memory/lessons.jsonl" | jq '.tags | length')
  [ "$tags_count" -gt 0 ]
}

@test "memory add: exits 1 when description is missing" {
  run "$LIB_DIR/archeflow-memory.sh" add pattern
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

# --- list ---

@test "memory list: shows message when no lessons exist" {
  run bash -c "'$LIB_DIR/archeflow-memory.sh' list 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No lessons"* ]]
}

@test "memory list: shows table header and lesson data" {
  "$LIB_DIR/archeflow-memory.sh" add pattern "Test lesson for listing" 2>/dev/null
  run "$LIB_DIR/archeflow-memory.sh" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"ID"* ]]
  [[ "$output" == *"Freq"* ]]
  [[ "$output" == *"m-001"* ]]
  [[ "$output" == *"Test lesson for listing"* ]]
}

# --- decay ---

@test "memory decay: increments runs_since_last_seen" {
  "$LIB_DIR/archeflow-memory.sh" add pattern "Decay test lesson" 2>/dev/null
  "$LIB_DIR/archeflow-memory.sh" decay 2>/dev/null
  local runs_since
  runs_since=$(head -1 ".archeflow/memory/lessons.jsonl" | jq '.runs_since_last_seen')
  [ "$runs_since" -eq 1 ]
}

@test "memory decay: decrements frequency after 10 runs" {
  "$LIB_DIR/archeflow-memory.sh" add pattern "Decay frequency test" 2>/dev/null
  # Set frequency=3 and runs_since=9 to trigger decay on next call
  local tmp=".archeflow/memory/lessons.jsonl.tmp"
  head -1 ".archeflow/memory/lessons.jsonl" | jq -c '.frequency = 3 | .runs_since_last_seen = 9' > "$tmp"
  mv "$tmp" ".archeflow/memory/lessons.jsonl"

  "$LIB_DIR/archeflow-memory.sh" decay 2>/dev/null
  local freq
  freq=$(head -1 ".archeflow/memory/lessons.jsonl" | jq '.frequency')
  [ "$freq" -eq 2 ]
}

@test "memory decay: archives lesson when frequency reaches 0" {
  "$LIB_DIR/archeflow-memory.sh" add pattern "Will be archived" 2>/dev/null
  # Set frequency=1 and runs_since=9 to trigger archival
  local tmp=".archeflow/memory/lessons.jsonl.tmp"
  head -1 ".archeflow/memory/lessons.jsonl" | jq -c '.frequency = 1 | .runs_since_last_seen = 9' > "$tmp"
  mv "$tmp" ".archeflow/memory/lessons.jsonl"

  "$LIB_DIR/archeflow-memory.sh" decay 2>/dev/null

  # Lesson should be gone from lessons file (file should be empty)
  local remaining
  remaining=$(wc -l < ".archeflow/memory/lessons.jsonl" | tr -d ' ')
  [ "$remaining" -eq 0 ]

  # And present in archive
  [ -f ".archeflow/memory/archive.jsonl" ]
  local archived_count
  archived_count=$(wc -l < ".archeflow/memory/archive.jsonl" | tr -d ' ')
  [ "$archived_count" -eq 1 ]
}

@test "memory decay: does nothing when no lessons exist" {
  run "$LIB_DIR/archeflow-memory.sh" decay
  [ "$status" -eq 0 ]
}

# --- forget ---

@test "memory forget: moves lesson to archive" {
  "$LIB_DIR/archeflow-memory.sh" add pattern "Will forget this" 2>/dev/null
  "$LIB_DIR/archeflow-memory.sh" forget m-001 2>/dev/null

  # Lessons file should be empty
  local remaining
  remaining=$(wc -l < ".archeflow/memory/lessons.jsonl" | tr -d ' ')
  [ "$remaining" -eq 0 ]

  # Archive should have it
  [ -f ".archeflow/memory/archive.jsonl" ]
  local archived_id
  archived_id=$(head -1 ".archeflow/memory/archive.jsonl" | jq -r '.id')
  [ "$archived_id" = "m-001" ]
}

@test "memory forget: exits 1 for nonexistent ID" {
  "$LIB_DIR/archeflow-memory.sh" add pattern "test" 2>/dev/null
  run "$LIB_DIR/archeflow-memory.sh" forget m-999
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "memory forget: exits 1 when no lessons file exists" {
  run "$LIB_DIR/archeflow-memory.sh" forget m-001
  [ "$status" -eq 1 ]
  [[ "$output" == *"No lessons file"* ]]
}

# --- inject ---

@test "memory inject: outputs nothing when no lessons file exists" {
  run "$LIB_DIR/archeflow-memory.sh" inject code guardian
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "memory inject: outputs relevant lessons with frequency >= 2" {
  "$LIB_DIR/archeflow-memory.sh" add pattern "Test injection lesson" 2>/dev/null
  # Bump frequency to 2
  local tmp=".archeflow/memory/lessons.jsonl.tmp"
  jq -c '.frequency = 2' ".archeflow/memory/lessons.jsonl" > "$tmp"
  mv "$tmp" ".archeflow/memory/lessons.jsonl"

  run "$LIB_DIR/archeflow-memory.sh" inject "" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Known Issues"* ]]
  [[ "$output" == *"Test injection lesson"* ]]
}

@test "memory inject: skips lessons with frequency < 2 (except preferences)" {
  "$LIB_DIR/archeflow-memory.sh" add pattern "Low frequency lesson" 2>/dev/null
  # frequency is 1 by default, type is pattern -> should NOT be injected
  run "$LIB_DIR/archeflow-memory.sh" inject "" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "memory inject: always injects preferences regardless of frequency" {
  "$LIB_DIR/archeflow-memory.sh" add preference "User prefers explicit error messages" 2>/dev/null
  run "$LIB_DIR/archeflow-memory.sh" inject "" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"User prefers explicit error messages"* ]]
}

# --- extract ---

@test "memory extract: exits 1 when events file not found" {
  run "$LIB_DIR/archeflow-memory.sh" extract nonexistent.jsonl
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "memory extract: extracts findings from review.verdict events" {
  # Create a mock events file with a review.verdict
  mkdir -p .archeflow/events
  cat > /tmp/test-events.jsonl <<'EOF'
{"run_id":"test-run","seq":1,"type":"run.start","phase":"plan","data":{"task":"test"}}
{"run_id":"test-run","seq":2,"type":"review.verdict","phase":"check","data":{"archetype":"guardian","verdict":"needs_changes","findings":[{"severity":"warning","description":"Missing input validation on user endpoint","category":"code"}]}}
EOF

  run "$LIB_DIR/archeflow-memory.sh" extract /tmp/test-events.jsonl
  [ "$status" -eq 0 ]
  [ -f ".archeflow/memory/lessons.jsonl" ]
  local desc
  desc=$(jq -r '.description' ".archeflow/memory/lessons.jsonl")
  [[ "$desc" == *"Missing input validation"* ]]
  rm -f /tmp/test-events.jsonl
}

@test "memory: concurrent adds do not lose lessons (serialized writers)" {
  for i in $(seq 1 10); do
    "$LIB_DIR/archeflow-memory.sh" add pattern "distinct lesson number $i about topic$i" >/dev/null 2>&1 &
  done
  wait
  [ "$(wc -l < .archeflow/memory/lessons.jsonl | tr -d ' ')" -eq 10 ]
  [ "$(jq -s '[.[].id] | unique | length' .archeflow/memory/lessons.jsonl)" -eq 10 ]
  # no leftover temp files
  [ -z "$(ls .archeflow/memory | grep -E 'lessons\.jsonl\.[A-Za-z0-9]{6}$' || true)" ]
}
