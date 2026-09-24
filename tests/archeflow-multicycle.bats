# Multi-cycle PDCA evaluation tests.
#
# Exercises convergence scoring, oscillation detection, Wiggum Breaks,
# and evidence validation with realistic multi-cycle scenarios.
# These tests validate the mechanisms the paper claims but single-cycle
# observational runs could not exercise.

setup() {
  load test_helper
  _common_setup
}

teardown() {
  _common_teardown
}

# Helper: create a findings JSON file with given IDs
_make_findings() {
  local file="$1"
  shift
  local entries=""
  for id in "$@"; do
    local sev="WARNING"
    [[ "$id" == CRIT-* ]] && sev="CRITICAL"
    entries="${entries}{\"id\":\"$id\",\"file\":\"src/${id}.py\",\"category\":\"security\",\"severity\":\"$sev\"},"
  done
  entries="${entries%,}"
  echo "[$entries]" > "$file"
}

# ============================================================
# Convergence scoring — core mechanism
# ============================================================

@test "convergence: perfect resolution scores 1.0 (converging)" {
  local prev="$BATS_TEST_TMPDIR/prev.json"
  local curr="$BATS_TEST_TMPDIR/curr.json"
  _make_findings "$prev" "F-01" "F-02" "F-03"
  echo "[]" > "$curr"

  run "$LIB_DIR/archeflow-convergence.sh" score "$curr" "$prev"
  [ "$status" -eq 0 ]
  local score=$(echo "$output" | jq -r '.convergence_score')
  local status_val=$(echo "$output" | jq -r '.status')
  [ "$score" = "1" ] || [ "$score" = "1.00" ]
  [ "$status_val" = "converging" ]
}

@test "convergence: 2 resolved + 1 new = 0.67 (stalling)" {
  local prev="$BATS_TEST_TMPDIR/prev.json"
  local curr="$BATS_TEST_TMPDIR/curr.json"
  _make_findings "$prev" "F-01" "F-02" "F-03"
  _make_findings "$curr" "F-03" "F-04"

  run "$LIB_DIR/archeflow-convergence.sh" score "$curr" "$prev"
  [ "$status" -eq 0 ]
  local score=$(echo "$output" | jq -r '.convergence_score')
  local status_val=$(echo "$output" | jq -r '.status')
  [ "$score" = "0.67" ]
  [ "$status_val" = "stalling" ]
}

@test "convergence: 1 resolved + 3 new = 0.25 (diverging)" {
  local prev="$BATS_TEST_TMPDIR/prev.json"
  local curr="$BATS_TEST_TMPDIR/curr.json"
  _make_findings "$prev" "F-01" "F-02"
  _make_findings "$curr" "F-02" "F-03" "F-04" "F-05"

  run "$LIB_DIR/archeflow-convergence.sh" score "$curr" "$prev"
  [ "$status" -eq 0 ]
  local score=$(echo "$output" | jq -r '.convergence_score')
  local status_val=$(echo "$output" | jq -r '.status')
  [ "$score" = "0.25" ]
  [ "$status_val" = "diverging" ]
}

@test "convergence: 0 resolved + 2 new = 0.0 (stuck)" {
  local prev="$BATS_TEST_TMPDIR/prev.json"
  local curr="$BATS_TEST_TMPDIR/curr.json"
  _make_findings "$prev" "F-01" "F-02"
  _make_findings "$curr" "F-01" "F-02" "F-03" "F-04"

  run "$LIB_DIR/archeflow-convergence.sh" score "$curr" "$prev"
  [ "$status" -eq 0 ]
  local score=$(echo "$output" | jq -r '.convergence_score')
  local status_val=$(echo "$output" | jq -r '.status')
  [ "$score" = "0" ] || [ "$score" = "0.00" ]
  [ "$status_val" = "stuck" ]
}

@test "convergence: empty-to-empty = 1.0 (all clear)" {
  local prev="$BATS_TEST_TMPDIR/prev.json"
  local curr="$BATS_TEST_TMPDIR/curr.json"
  echo "[]" > "$prev"
  echo "[]" > "$curr"

  run "$LIB_DIR/archeflow-convergence.sh" score "$curr" "$prev"
  [ "$status" -eq 0 ]
  local score=$(echo "$output" | jq -r '.convergence_score')
  [ "$score" = "1" ] || [ "$score" = "1.00" ]
}

# ============================================================
# Oscillation detection
# ============================================================

@test "oscillation: detects when finding reappears after absence" {
  local n="$BATS_TEST_TMPDIR/cycle-n.json"
  local n1="$BATS_TEST_TMPDIR/cycle-n1.json"
  local n2="$BATS_TEST_TMPDIR/cycle-n2.json"

  _make_findings "$n2" "F-01" "F-02" "F-03"
  _make_findings "$n1" "F-02"
  _make_findings "$n" "F-01" "F-02" "F-03"

  run "$LIB_DIR/archeflow-convergence.sh" oscillation "$n" "$n1" "$n2"
  [ "$status" -eq 0 ]
  local detected=$(echo "$output" | jq -r '.oscillation_detected')
  local count=$(echo "$output" | jq -r '.count')
  [ "$detected" = "true" ]
  [ "$count" -ge 2 ]
  [[ "$(echo "$output" | jq -r '.action')" == "hard_wiggum_break" ]]
}

@test "oscillation: no detection when findings consistently resolve" {
  local n="$BATS_TEST_TMPDIR/cycle-n.json"
  local n1="$BATS_TEST_TMPDIR/cycle-n1.json"
  local n2="$BATS_TEST_TMPDIR/cycle-n2.json"

  _make_findings "$n2" "F-01" "F-02" "F-03"
  _make_findings "$n1" "F-02" "F-03"
  _make_findings "$n" "F-03"

  run "$LIB_DIR/archeflow-convergence.sh" oscillation "$n" "$n1" "$n2"
  [ "$status" -eq 1 ]
  local detected=$(echo "$output" | jq -r '.oscillation_detected')
  [ "$detected" = "false" ]
}

@test "oscillation: 1 oscillating is not enough (need 2+)" {
  local n="$BATS_TEST_TMPDIR/cycle-n.json"
  local n1="$BATS_TEST_TMPDIR/cycle-n1.json"
  local n2="$BATS_TEST_TMPDIR/cycle-n2.json"

  _make_findings "$n2" "F-01" "F-02"
  _make_findings "$n1" "F-02"
  _make_findings "$n" "F-01" "F-02"

  run "$LIB_DIR/archeflow-convergence.sh" oscillation "$n" "$n1" "$n2"
  [ "$status" -eq 1 ]
}

# ============================================================
# Wiggum Break — hard triggers
# ============================================================

@test "wiggum: hard break on 3+ shadow detections" {
  local run_dir="$BATS_TEST_TMPDIR/run-shadows"
  mkdir -p "$run_dir"

  printf '{"ts":"t1","run_id":"r1","seq":1,"type":"shadow.detected","phase":"check","agent":"guardian","data":{}}\n' > "$run_dir/events.jsonl"
  printf '{"ts":"t2","run_id":"r1","seq":2,"type":"shadow.detected","phase":"check","agent":"guardian","data":{}}\n' >> "$run_dir/events.jsonl"
  printf '{"ts":"t3","run_id":"r1","seq":3,"type":"shadow.detected","phase":"check","agent":"guardian","data":{}}\n' >> "$run_dir/events.jsonl"

  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check "$run_dir"
  [ "$status" -eq 0 ]
  local break_type=$(echo "$output" | jq -r '.type')
  [ "$break_type" = "hard" ]
}

@test "wiggum: hard break on post-merge test failure" {
  local run_dir="$BATS_TEST_TMPDIR/run-testfail"
  mkdir -p "$run_dir"
  echo "FAILED" > "$run_dir/post-merge-test-result"

  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check "$run_dir"
  [ "$status" -eq 0 ]
  local break_type=$(echo "$output" | jq -r '.type')
  [ "$break_type" = "hard" ]
}

@test "wiggum: hard break on 3+ agent failures" {
  local run_dir="$BATS_TEST_TMPDIR/run-failures"
  mkdir -p "$run_dir"

  printf '{"ts":"t1","run_id":"r1","seq":1,"type":"agent.failed","phase":"do","agent":"maker","data":{}}\n' > "$run_dir/events.jsonl"
  printf '{"ts":"t2","run_id":"r1","seq":2,"type":"agent.failed","phase":"do","agent":"maker","data":{}}\n' >> "$run_dir/events.jsonl"
  printf '{"ts":"t3","run_id":"r1","seq":3,"type":"agent.failed","phase":"do","agent":"maker","data":{}}\n' >> "$run_dir/events.jsonl"

  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check "$run_dir"
  [ "$status" -eq 0 ]
  local break_type=$(echo "$output" | jq -r '.type')
  [ "$break_type" = "hard" ]
}

# ============================================================
# Wiggum Break — soft triggers
# ============================================================

@test "wiggum: soft break on 2 consecutive diverging cycles" {
  local run_dir="$BATS_TEST_TMPDIR/run-diverge"
  mkdir -p "$run_dir"

  echo '{"convergence_score": 0.3, "status": "diverging"}' > "$run_dir/convergence.json"
  mkdir -p "$run_dir/cycle2"
  echo '{"convergence_score": 0.2, "status": "diverging"}' > "$run_dir/cycle2/convergence.json"

  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check "$run_dir"
  [ "$status" -eq 0 ]
  local break_type=$(echo "$output" | jq -r '.type')
  [ "$break_type" = "soft" ]
}

@test "wiggum: soft break on stale findings between cycles" {
  local run_dir="$BATS_TEST_TMPDIR/run-stale"
  mkdir -p "$run_dir"

  _make_findings "$run_dir/findings-cycle-1.json" "F-01" "F-02"
  _make_findings "$run_dir/findings-cycle-2.json" "F-01" "F-02"

  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check "$run_dir"
  [ "$status" -eq 0 ]
  local break_type=$(echo "$output" | jq -r '.type')
  [ "$break_type" = "soft" ]
}

@test "wiggum: no break on clean run" {
  local run_dir="$BATS_TEST_TMPDIR/run-clean"
  mkdir -p "$run_dir"

  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check "$run_dir"
  [ "$status" -eq 1 ]
  local wb=$(echo "$output" | jq -r '.wiggum_break')
  [ "$wb" = "false" ]
}

# ============================================================
# Evidence validation
# ============================================================

@test "evidence: downgrades hedging CRITICAL without evidence" {
  local review="$BATS_TEST_TMPDIR/review.md"
  cat > "$review" <<'EOF'
CRITICAL: This might be a security vulnerability in the auth module.
The code appears to have some issues that could potentially cause problems.
EOF

  run "$LIB_DIR/archeflow-evidence.sh" scan "$review"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOWNGRADE"* ]]
}

@test "evidence: keeps well-evidenced CRITICAL finding" {
  local review="$BATS_TEST_TMPDIR/review.md"
  cat > "$review" <<'EOF'
CRITICAL: SQL injection via string concatenation
  File: src/db.py line 42
  Code: query = f"SELECT * FROM users WHERE id = {user_input}"
  output: Running sqlmap shows injection at this endpoint
  fix: Use parameterized queries
EOF

  run "$LIB_DIR/archeflow-evidence.sh" scan "$review"
  [ "$status" -eq 1 ]
}

@test "evidence: downgrades WARNING with no evidence at all" {
  local review="$BATS_TEST_TMPDIR/review.md"
  cat > "$review" <<'EOF'
WARNING: The error handling strategy needs improvement across the codebase.
The current approach to logging is insufficient for production use.
EOF

  run "$LIB_DIR/archeflow-evidence.sh" scan "$review"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOWNGRADE"* ]]
  [[ "$output" == *"no_evidence"* ]]
}

# ============================================================
# Realistic multi-cycle scenario: converging run
# ============================================================

@test "multicycle: 3-cycle converging scenario exercises full machinery" {
  local cycle1_findings="$BATS_TEST_TMPDIR/c1.json"
  local cycle2_findings="$BATS_TEST_TMPDIR/c2.json"
  local cycle3_findings="$BATS_TEST_TMPDIR/c3.json"

  _make_findings "$cycle1_findings" "CRIT-auth-bypass" "CRIT-sqli" "warn-logging" "warn-timeout" "warn-headers"
  _make_findings "$cycle2_findings" "warn-logging" "warn-timeout"
  _make_findings "$cycle3_findings" "warn-timeout"

  # Cycle 1→2: convergence
  run "$LIB_DIR/archeflow-convergence.sh" score "$cycle2_findings" "$cycle1_findings"
  [ "$status" -eq 0 ]
  local s1=$(echo "$output" | jq -r '.convergence_score')
  local resolved1=$(echo "$output" | jq -r '.resolved')
  [ "$resolved1" -eq 3 ]
  # score = 3/(3+0+0) = 1.0
  [ "$s1" = "1" ] || [ "$s1" = "1.00" ]

  # Cycle 2→3: still converging
  run "$LIB_DIR/archeflow-convergence.sh" score "$cycle3_findings" "$cycle2_findings"
  [ "$status" -eq 0 ]
  local s2=$(echo "$output" | jq -r '.convergence_score')
  [ "$s2" = "1" ] || [ "$s2" = "1.00" ]

  # Oscillation check across 3 cycles: no oscillation
  run "$LIB_DIR/archeflow-convergence.sh" oscillation "$cycle3_findings" "$cycle2_findings" "$cycle1_findings"
  [ "$status" -eq 1 ]
}

# ============================================================
# Realistic multi-cycle scenario: oscillating run → Wiggum Break
# ============================================================

@test "multicycle: oscillating findings trigger hard Wiggum Break" {
  local c1="$BATS_TEST_TMPDIR/c1.json"
  local c2="$BATS_TEST_TMPDIR/c2.json"
  local c3="$BATS_TEST_TMPDIR/c3.json"

  # Cycle 1: Guardian finds auth-bypass and input-validation
  _make_findings "$c1" "auth-bypass" "input-validation" "missing-tests"
  # Cycle 2: Maker fixes auth-bypass and input-validation, but introduces new issue
  _make_findings "$c2" "missing-tests" "race-condition"
  # Cycle 3: auth-bypass and input-validation REAPPEAR (Maker's fix reverted by refactor)
  _make_findings "$c3" "auth-bypass" "input-validation" "missing-tests"

  # Oscillation detected: auth-bypass and input-validation oscillate
  run "$LIB_DIR/archeflow-convergence.sh" oscillation "$c3" "$c2" "$c1"
  [ "$status" -eq 0 ]
  local detected=$(echo "$output" | jq -r '.oscillation_detected')
  [ "$detected" = "true" ]
  [[ "$(echo "$output" | jq -r '.action')" == "hard_wiggum_break" ]]
}

# ============================================================
# Realistic multi-cycle scenario: diverging run
# ============================================================

@test "multicycle: diverging findings produce low convergence score" {
  local c1="$BATS_TEST_TMPDIR/c1.json"
  local c2="$BATS_TEST_TMPDIR/c2.json"

  # Cycle 1: 2 findings
  _make_findings "$c1" "F-01" "F-02"
  # Cycle 2: 1 resolved but 4 new (fix introduced regressions)
  _make_findings "$c2" "F-02" "F-03" "F-04" "F-05" "F-06"

  run "$LIB_DIR/archeflow-convergence.sh" score "$c2" "$c1"
  [ "$status" -eq 0 ]
  local score=$(echo "$output" | jq -r '.convergence_score')
  local status_val=$(echo "$output" | jq -r '.status')
  # resolved=1, new=4 → score = 1/5 = 0.2
  # resolved=1, new=4 -> 1/5 = 0.2 (asserted in jq: fails the test when out of range)
  jq -e '.convergence_score > 0.1 and .convergence_score < 0.3' <<<"$output"
  [ "$status_val" = "diverging" ]
}

# ============================================================
# End-to-end: shadow + convergence + evidence in sequence
# ============================================================

@test "e2e: shadow clean + evidence valid + converging = healthy run" {
  local guardian_review="$BATS_TEST_TMPDIR/guardian.md"
  cat > "$guardian_review" <<'EOF'
## Guardian Security Review

CRITICAL: Missing input validation on /api/upload endpoint
  File: src/routes/upload.py line 23
  Code: file = request.files['file']  # no size/type check
  fix: Add file type whitelist and size limit

WARNING: No rate limiting on authentication endpoints
  output: ab -n 1000 http://localhost/login shows all accepted
  fix: Add rate limiting middleware

APPROVED: CORS configuration is correct.
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect guardian "$guardian_review"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLEAN"* ]]

  run "$LIB_DIR/archeflow-evidence.sh" scan "$guardian_review"
  [ "$status" -eq 1 ]

  # Simulate cycle 1→2 convergence
  local c1="$BATS_TEST_TMPDIR/c1.json"
  local c2="$BATS_TEST_TMPDIR/c2.json"
  _make_findings "$c1" "CRIT-upload-validation" "warn-rate-limit"
  _make_findings "$c2" "warn-rate-limit"
  run "$LIB_DIR/archeflow-convergence.sh" score "$c2" "$c1"
  [ "$status" -eq 0 ]
  local score=$(echo "$output" | jq -r '.convergence_score')
  [ "$score" = "1" ] || [ "$score" = "1.00" ]
}

@test "e2e: shadow detected + evidence downgrade + diverging = escalation" {
  # Guardian in paranoid mode
  local guardian_review="$BATS_TEST_TMPDIR/guardian.md"
  cat > "$guardian_review" <<'EOF'
## Guardian Review

CRITICAL: Missing CSRF protection on all endpoints
CRITICAL: No Content-Security-Policy header
CRITICAL: Cookie without HttpOnly flag
CRITICAL: Using HTTP instead of HTTPS internally
CRITICAL: Missing Subresource Integrity checks
CRITICAL: No X-Content-Type-Options header
WARNING: Outdated dependency version
This might be a vulnerability that could potentially affect the system.
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect guardian "$guardian_review"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHADOW_DETECTED"* ]]
  [[ "$output" == *"paranoid"* ]]

  # Evidence: the hedging finding gets downgraded
  run "$LIB_DIR/archeflow-evidence.sh" scan "$guardian_review"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOWNGRADE"* ]]

  # Diverging convergence
  local c1="$BATS_TEST_TMPDIR/c1.json"
  local c2="$BATS_TEST_TMPDIR/c2.json"
  _make_findings "$c1" "F-01" "F-02"
  _make_findings "$c2" "F-01" "F-02" "F-03" "F-04" "F-05"
  run "$LIB_DIR/archeflow-convergence.sh" score "$c2" "$c1"
  [ "$status" -eq 0 ]
  local score=$(echo "$output" | jq -r '.convergence_score')
  local status_val=$(echo "$output" | jq -r '.status')
  # 0 resolved, 3 new → score=0 → stuck → stop immediately
  [ "$status_val" = "stuck" ] || [ "$status_val" = "diverging" ]
}
