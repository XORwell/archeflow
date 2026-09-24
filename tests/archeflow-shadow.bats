# Tests for archeflow-shadow.sh — shadow detection engine.
#
# Validates: per-archetype shadow triggers, clean-pass conditions,
# usage/error handling, ARCHEFLOW_SHADOWS=off, event emission.

setup() {
  load test_helper
  _common_setup
}

teardown() {
  _common_teardown
}

# ============================================================
# Usage / error handling
# ============================================================

@test "shadow: exits 2 with usage when no args" {
  run "$LIB_DIR/archeflow-shadow.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage"* ]]
}

@test "shadow: exits 2 for unknown archetype" {
  echo "some content" > "$BATS_TEST_TMPDIR/artifact.txt"
  run "$LIB_DIR/archeflow-shadow.sh" detect unknown "$BATS_TEST_TMPDIR/artifact.txt"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown archetype"* ]]
}

@test "shadow: exits 2 when artifact file missing" {
  run "$LIB_DIR/archeflow-shadow.sh" detect explorer "/nonexistent/file.txt"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not found"* ]]
}

# ============================================================
# Explorer — rabbit_hole
# ============================================================

@test "explorer: detects rabbit_hole when >2000 words without recommendation" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  for i in $(seq 1 300); do
    echo "This is analysis line number $i with some extra words here"
  done > "$artifact"

  run "$LIB_DIR/archeflow-shadow.sh" detect explorer "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHADOW_DETECTED"* ]]
  [[ "$output" == *"rabbit_hole"* ]]
  [[ "$output" == *">2000 words"* ]]
}

@test "explorer: detects rabbit_hole when >3 tangents" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  cat > "$artifact" <<'EOF'
Main analysis of the codebase structure.
Tangent: we should also look at the build system.
Aside: the logging framework is worth examining.
By the way, the CI pipeline has issues too.
Incidentally, the Docker setup is outdated.
Also worth mentioning the monitoring gaps.
Recommendation: fix the above items.
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect explorer "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHADOW_DETECTED"* ]]
  [[ "$output" == *"rabbit_hole"* ]]
  [[ "$output" == *"tangent"* ]]
}

@test "explorer: detects rabbit_hole when >15 files without pattern synthesis" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  for i in $(seq 1 20); do
    echo "Analyzed src/module${i}.py for issues"
  done > "$artifact"
  echo "Recommendation: refactor modules" >> "$artifact"

  run "$LIB_DIR/archeflow-shadow.sh" detect explorer "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHADOW_DETECTED"* ]]
  [[ "$output" == *"rabbit_hole"* ]]
  [[ "$output" == *">15 files"* ]]
}

@test "explorer: clean when short focused output with recommendations" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  cat > "$artifact" <<'EOF'
Analysis of auth module.
The code follows standard conventions.
Recommendation: add input validation to login endpoint.
Summary: solid architecture with minor improvements needed.
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect explorer "$artifact"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLEAN"* ]]
}

# ============================================================
# Creator — over_architect
# ============================================================

@test "creator: detects over_architect when >2 abstractions" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  cat > "$artifact" <<'EOF'
Proposal: implement user management.
Create an interface for data access layer.
Add an abstract class for entity processing.
Use factory for instance creation.
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect creator "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHADOW_DETECTED"* ]]
  [[ "$output" == *"over_architect"* ]]
  [[ "$output" == *"abstraction"* ]]
}

@test "creator: detects over_architect with excessive future-proofing" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  cat > "$artifact" <<'EOF'
This design is extensible for future use.
In case we need to scale horizontally.
We should anticipate multi-region deployments.
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect creator "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHADOW_DETECTED"* ]]
  [[ "$output" == *"over_architect"* ]]
  [[ "$output" == *"future-proofing"* ]]
}

@test "creator: clean when focused proposal" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  cat > "$artifact" <<'EOF'
Implement login endpoint.
Add password hashing with bcrypt.
Return JWT token on success.
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect creator "$artifact"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLEAN"* ]]
}

# ============================================================
# Maker — rogue
# ============================================================

@test "maker: detects rogue when >=3 files changed with 0 tests" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  cat > "$artifact" <<'EOF'
+++ b/src/auth.py
+++ b/src/config.py
+++ b/src/main.py
Implemented authentication flow.
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHADOW_DETECTED"* ]]
  [[ "$output" == *"rogue"* ]]
}

@test "maker: clean when diff includes test files and evidence" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  cat > "$artifact" <<'EOF'
+++ b/src/auth.py
+++ b/tests/test_auth.py
All tests PASSED successfully.
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$artifact"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLEAN"* ]]
}

# ============================================================
# Guardian — paranoid
# ============================================================

@test "guardian: detects paranoid when CRITICAL:WARNING ratio >2:1" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  cat > "$artifact" <<'EOF'
CRITICAL: SQL injection in auth module
CRITICAL: Unvalidated input in API handler
CRITICAL: Missing authentication check on admin route
CRITICAL: Buffer overflow risk in parser
WARNING: Unused import in utils
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect guardian "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHADOW_DETECTED"* ]]
  [[ "$output" == *"paranoid"* ]]
  [[ "$output" == *"CRITICAL:WARNING"* ]]
}

@test "guardian: clean when balanced findings with fixes" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  cat > "$artifact" <<'EOF'
WARNING: Missing input validation
fix: Add input sanitization
APPROVED: overall design is solid
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect guardian "$artifact"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLEAN"* ]]
}

@test "guardian: detects paranoid when <50% findings have fix" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  cat > "$artifact" <<'EOF'
WARNING: Missing input validation in handler
WARNING: No error handling in module A
WARNING: No error handling in module B
CRITICAL: Missing CSRF protection
fix: Add CSRF token middleware
APPROVED: architecture
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect guardian "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHADOW_DETECTED"* ]]
  [[ "$output" == *"paranoid"* ]]
  [[ "$output" == *"<50%"* ]]
}

# ============================================================
# Skeptic — paralytic
# ============================================================

@test "skeptic: detects paralytic when >7 challenges with <50% alternatives" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  cat > "$artifact" <<'EOF'
There is a concern about scalability of the current design.
A major risk of data loss exists in the pipeline.
The assumption about latency needs validation.
We challenge the threading model fundamentals.
The issue with memory usage is problematic for production.
A question about the API design surfaces here.
Another concern about error handling coverage.
A risk with the deployment strategy remains.
This is also a problematic issue with logging retention.
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect skeptic "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHADOW_DETECTED"* ]]
  [[ "$output" == *"paralytic"* ]]
}

# ============================================================
# Trickster — false_alarm
# ============================================================

@test "trickster: detects false_alarm for findings in untouched files" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  local diff_file="$BATS_TEST_TMPDIR/changes.diff"

  cat > "$diff_file" <<'EOF'
+++ b/src/main.py
@@ -1,2 +1,3 @@
 print("hello")
+print("world")
EOF

  cat > "$artifact" <<'EOF'
finding: vulnerability in src/auth.py at line 42
issue: bug in src/config.py at line 15
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect trickster "$artifact" --diff "$diff_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHADOW_DETECTED"* ]]
  [[ "$output" == *"false_alarm"* ]]
  [[ "$output" == *"untouched"* ]]
}

# ============================================================
# Sage — bureaucrat
# ============================================================

@test "sage: detects bureaucrat when review >2x diff length" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  local diff_file="$BATS_TEST_TMPDIR/changes.diff"

  cat > "$diff_file" <<'EOF'
--- a/main.py
+++ b/main.py
@@ -1,2 +1,3 @@
 print("hello")
+print("world")
EOF

  cat > "$artifact" <<'EOF'
This code change adds a print statement which outputs the word world to the console window after the existing hello message is displayed to the user in the terminal for debugging and user information purposes during runtime
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect sage "$artifact" --diff "$diff_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHADOW_DETECTED"* ]]
  [[ "$output" == *"bureaucrat"* ]]
}

# ============================================================
# Guardian: prose false-positive regression test
# ============================================================

@test "guardian: does NOT trigger on prose discussing severity levels" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  cat > "$artifact" <<'EOF'
## Security Review of Documentation

The document correctly defines CRITICAL severity as "system compromise"
and WARNING severity as "degraded functionality." These definitions align
with industry standards. The CRITICAL category is well-scoped.

Each CRITICAL finding should include reproduction steps per the team's
security policy. WARNING items may be deferred to the next sprint.

Assessment: The severity taxonomy is sound. No issues found.

APPROVED: documentation meets standards.
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect guardian "$artifact"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLEAN"* ]]
}

@test "guardian: does NOT trigger on review with balanced structured findings" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  cat > "$artifact" <<'EOF'
## Guardian Review

CRITICAL: SQL injection via unsanitized user input in query builder
fix: Use parameterized queries instead of string concatenation

WARNING: Missing rate limiting on login endpoint
fix: Add rate limiter middleware (e.g., express-rate-limit)

WARNING: Session tokens not rotated after privilege change
fix: Rotate session after role elevation

APPROVED: Authentication flow is otherwise solid.
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect guardian "$artifact"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLEAN"* ]]
}

@test "guardian: triggers on genuine paranoid structured findings" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  cat > "$artifact" <<'EOF'
## Security Review

CRITICAL: Missing CSRF token on all forms
CRITICAL: No Content-Security-Policy header
CRITICAL: Using MD5 for password hashing
CRITICAL: Secrets in environment variables exposed
CRITICAL: No input validation on file upload
CRITICAL: XSS via reflected query parameters
WARNING: Missing X-Frame-Options header
EOF

  run "$LIB_DIR/archeflow-shadow.sh" detect guardian "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHADOW_DETECTED"* ]]
  [[ "$output" == *"paranoid"* ]]
}

# ============================================================
# ARCHEFLOW_SHADOWS=off
# ============================================================

@test "shadow: ARCHEFLOW_SHADOWS=off disables detection" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  for i in $(seq 1 300); do
    echo "This is analysis line number $i with some extra words here"
  done > "$artifact"

  export ARCHEFLOW_SHADOWS=off
  run "$LIB_DIR/archeflow-shadow.sh" detect explorer "$artifact"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIPPED"* ]]
}

# ============================================================
# Event emission
# ============================================================

@test "shadow: emits event via archeflow-event.sh when --run-id is set" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  for i in $(seq 1 300); do
    echo "This is analysis line number $i with some extra words here"
  done > "$artifact"

  run "$LIB_DIR/archeflow-shadow.sh" detect explorer "$artifact" --run-id test-shadow-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHADOW_DETECTED"* ]]
  [ -f ".archeflow/events/test-shadow-run.jsonl" ]
  local event_type
  event_type=$(head -1 ".archeflow/events/test-shadow-run.jsonl" | jq -r '.type')
  [ "$event_type" = "shadow.detected" ]
}

# ============================================================
# Regression tests (2026-09 detector review)
# ============================================================

@test "trickster: e.g. / i.e. are not counted as file references" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  local diff="$BATS_TEST_TMPDIR/change.diff"
  printf '%s\n' \
    "Finding: the handler in src/auth.py trusts user input, e.g. the token header." \
    "Reproduction: send a forged header, i.e. one without a signature. Done.The end." > "$artifact"
  printf '+++ b/src/auth.py\n@@ -1 +1 @@\n+x\n' > "$diff"
  run "$LIB_DIR/archeflow-shadow.sh" detect trickster "$artifact" --diff "$diff"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLEAN"* ]]
}

@test "trickster: still flags genuinely untouched files" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  local diff="$BATS_TEST_TMPDIR/change.diff"
  echo "Finding: race condition in src/other.py, e.g. under load." > "$artifact"
  printf '+++ b/src/auth.py\n' > "$diff"
  run "$LIB_DIR/archeflow-shadow.sh" detect trickster "$artifact" --diff "$diff"
  [ "$status" -eq 0 ]
  [[ "$output" == *"untouched files (1)"* ]]
}

@test "skeptic: bare fragments like 'issues.' are not repeated concerns" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  printf '%s\n' \
    "There are several issues. The first has no alternative listed yet." \
    "Formatting has minor issues. Consider a linter instead." \
    "Naming issue (e.g. getData) is minor. Consider renaming." \
    "Spacing issue (e.g. tabs) is minor. Consider an editorconfig." \
    "The test risk. Another risk. Also a problem. One more problem." > "$artifact"
  run "$LIB_DIR/archeflow-shadow.sh" detect skeptic "$artifact"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLEAN"* ]]
}

@test "skeptic: fires when 2+ distinct concerns are each repeated" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  printf '%s\n' \
    "My concern is that the cache is never invalidated after writes." \
    "Alternative: use a TTL." \
    "My **concern** is that the cache is never invalidated after writes." \
    "The risk is that retries will duplicate payment requests downstream." \
    "The risk is that retries will duplicate payment requests downstream." > "$artifact"
  run "$LIB_DIR/archeflow-shadow.sh" detect skeptic "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"paralytic"*"2 concerns repeated"* ]]
}

@test "skeptic: a single repeated concern does not fire (threshold is 2 distinct)" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  printf '%s\n' \
    "The risk is that retries will duplicate payment requests downstream." \
    "The risk is that retries will duplicate payment requests downstream." > "$artifact"
  run "$LIB_DIR/archeflow-shadow.sh" detect skeptic "$artifact"
  [ "$status" -eq 1 ]
}

@test "creator: scope check is skipped without a task size (no hard-coded default)" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  for i in $(seq 1 120); do echo "Step $i modifies the handler to return early on empty input."; done > "$artifact"
  run env -u ARCHEFLOW_TASK_WORDS "$LIB_DIR/archeflow-shadow.sh" detect creator "$artifact"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLEAN"* ]]
}

@test "creator: --task-words enables the >50% scope check" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  for i in $(seq 1 120); do echo "Step $i modifies the handler to return early on empty input."; done > "$artifact"
  run "$LIB_DIR/archeflow-shadow.sh" detect creator "$artifact" --task-words 500
  [ "$status" -eq 0 ]
  [[ "$output" == *"exceeds task by >50%"* ]]
  run "$LIB_DIR/archeflow-shadow.sh" detect creator "$artifact" --task-words 2000
  [ "$status" -eq 1 ]
  run env ARCHEFLOW_TASK_WORDS=500 "$LIB_DIR/archeflow-shadow.sh" detect creator "$artifact"
  [ "$status" -eq 0 ]
  run "$LIB_DIR/archeflow-shadow.sh" detect creator "$artifact" --task-words abc
  [ "$status" -ne 0 ]
}

@test "guardian: exactly 2:1 does NOT fire (rule is strictly >2:1)" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  printf '%s\n' \
    "CRITICAL: SQL injection in auth module" \
    "CRITICAL: Unvalidated input in API handler" \
    "CRITICAL: Missing authentication check on admin route" \
    "CRITICAL: Buffer overflow risk in parser" \
    "WARNING: Unused import in utils" \
    "WARNING: Missing docstring in helper" \
    "fix: parameterise queries" "fix: validate input" "fix: add auth guard" "fix: bounds check" \
    "APPROVED: rest of the change" > "$artifact"
  run "$LIB_DIR/archeflow-shadow.sh" detect guardian "$artifact"
  [ "$status" -eq 1 ]
}

@test "guardian: 5:2 fires (>2:1) and 3:0 fires (min 3 criticals, no warnings)" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  printf 'CRITICAL: a one\nCRITICAL: b two\nCRITICAL: c three\nCRITICAL: d four\nCRITICAL: e five\nWARNING: f six\nWARNING: g seven\n' > "$artifact"
  run "$LIB_DIR/archeflow-shadow.sh" detect guardian "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(5:2)"* ]]
  printf 'CRITICAL: a one\nCRITICAL: b two\nCRITICAL: c three\n' > "$artifact"
  run "$LIB_DIR/archeflow-shadow.sh" detect guardian "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(3:0)"* ]]
}

@test "shadow: event data is built with jq (valid JSON)" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  printf 'CRITICAL: a one\nCRITICAL: b two\nCRITICAL: c three\n' > "$artifact"
  run "$LIB_DIR/archeflow-shadow.sh" detect guardian "$artifact" --run-id ev-run
  [ "$status" -eq 0 ]
  jq -e '.data.trigger | contains("3:0")' .archeflow/events/ev-run.jsonl
}

@test "shadow: --cycle is recorded in the event so wiggum-check can group by cycle" {
  local artifact="$BATS_TEST_TMPDIR/artifact.txt"
  printf 'CRITICAL: a one\nCRITICAL: b two\nCRITICAL: c three\n' > "$artifact"
  run "$LIB_DIR/archeflow-shadow.sh" detect guardian "$artifact" --run-id cyc-run --cycle 2
  [ "$status" -eq 0 ]
  jq -e '.data.cycle == 2' .archeflow/events/cyc-run.jsonl
  run "$LIB_DIR/archeflow-shadow.sh" detect guardian "$artifact" --cycle x
  [ "$status" -ne 0 ]
}

# ============================================================
# check-system on the layout a real run writes
# ============================================================

@test "check-system <run_id>: scope creep from do-maker.diff in the artifact dir" {
  mkdir -p .archeflow/artifacts/r-sys
  echo "Change src/a.py only." > .archeflow/artifacts/r-sys/plan-creator.md
  {
    for f in a b c d e; do printf 'diff --git a/src/%s.py b/src/%s.py\n+++ b/src/%s.py\n+x\n' "$f" "$f" "$f"; done
  } > .archeflow/artifacts/r-sys/do-maker.diff
  run "$LIB_DIR/archeflow-shadow.sh" check-system r-sys
  [ "$status" -eq 0 ]
  [[ "$output" == *"scope_creep"* ]]
}

@test "check-system <run_id>: echo chamber from events written by archeflow-event.sh" {
  "$LIB_DIR/archeflow-event.sh" r-echo agent.complete check guardian '{"summary":"APPROVED"}' >/dev/null
  "$LIB_DIR/archeflow-event.sh" r-echo agent.complete check sage '{"summary":"APPROVED"}' >/dev/null
  run "$LIB_DIR/archeflow-shadow.sh" check-system r-echo
  [ "$status" -eq 0 ]
  [[ "$output" == *"echo_chamber"* ]]
}

@test "check-system: unknown run exits 2 (error), not 1 (clean)" {
  run "$LIB_DIR/archeflow-shadow.sh" check-system no-such-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"not found"* ]]
}

@test "check-system <run_id>: clean run exits 1 with CLEAN" {
  mkdir -p .archeflow/artifacts/r-clean
  run "$LIB_DIR/archeflow-shadow.sh" check-system r-clean
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLEAN"* ]]
}
