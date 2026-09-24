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

# The Maker check reads the changed files from the run diff (--diff, as the run
# skill passes do-maker.diff) and the test evidence from the Maker's report.

# _diff <file> <n-lines> ...: a unified diff adding n lines to each file.
_diff() {
  while [[ $# -gt 0 ]]; do
    printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1 +1,%s @@\n' "$1" "$1" "$1" "$1" "$2"
    for ((k = 0; k < $2; k++)); do printf '+line %s\n' "$k"; done
    shift 2
  done
}

@test "maker: detects rogue when >=3 code files changed with 0 tests (files from --diff)" {
  echo "Implemented authentication flow. All tests passed." > "$BATS_TEST_TMPDIR/do-maker.md"
  _diff src/auth.py 2 src/config.py 2 src/main.py 2 > "$BATS_TEST_TMPDIR/do-maker.diff"

  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$BATS_TEST_TMPDIR/do-maker.md" --diff "$BATS_TEST_TMPDIR/do-maker.diff"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rogue"* ]]
  [[ "$output" == *"No test file changed with 3 code files"* ]]
}

@test "maker: clean when the diff has a test file and the report shows tests ran" {
  echo "Added login and a test. pytest: 4 passed." > "$BATS_TEST_TMPDIR/do-maker.md"
  _diff src/auth.py 30 tests/test_auth.py 10 > "$BATS_TEST_TMPDIR/do-maker.diff"

  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$BATS_TEST_TMPDIR/do-maker.md" --diff "$BATS_TEST_TMPDIR/do-maker.diff"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLEAN"* ]]
}

@test "maker: a prose report that lists files but no diff cannot fire (regression: the report was read as a diff)" {
  printf 'Changed src/a.py src/b.py src/c.py src/d.py. Did not write tests.\n' > "$BATS_TEST_TMPDIR/do-maker.md"
  : > "$BATS_TEST_TMPDIR/empty.diff"
  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$BATS_TEST_TMPDIR/do-maker.md" --diff "$BATS_TEST_TMPDIR/empty.diff"
  [ "$status" -eq 1 ]
  # ... while the same report with the real diff does fire
  _diff src/a.py 3 src/b.py 3 src/c.py 3 src/d.py 3 > "$BATS_TEST_TMPDIR/do-maker.diff"
  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$BATS_TEST_TMPDIR/do-maker.md" --diff "$BATS_TEST_TMPDIR/do-maker.diff"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rogue"* ]]
}

@test "maker: without --diff it is a usage error (exit 2), not a silent CLEAN" {
  echo "report" > "$BATS_TEST_TMPDIR/do-maker.md"
  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$BATS_TEST_TMPDIR/do-maker.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs --diff"* ]]
  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$BATS_TEST_TMPDIR/do-maker.md" --diff "$BATS_TEST_TMPDIR/missing.diff"
  [ "$status" -eq 2 ]
}

@test "maker: a one-line README change never needs test evidence" {
  echo "Fixed a typo in the README." > "$BATS_TEST_TMPDIR/do-maker.md"
  _diff README.md 1 > "$BATS_TEST_TMPDIR/do-maker.diff"
  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$BATS_TEST_TMPDIR/do-maker.md" --diff "$BATS_TEST_TMPDIR/do-maker.diff"
  [ "$status" -eq 1 ]
  # docs in bulk do not count as code either
  _diff docs/guide.md 200 CHANGELOG.md 20 README.md 40 > "$BATS_TEST_TMPDIR/do-maker.diff"
  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$BATS_TEST_TMPDIR/do-maker.md" --diff "$BATS_TEST_TMPDIR/do-maker.diff"
  [ "$status" -eq 1 ]
}

@test "maker: the test-evidence rule scales with the code change" {
  echo "Renamed a variable." > "$BATS_TEST_TMPDIR/do-maker.md"
  _diff src/a.py 4 > "$BATS_TEST_TMPDIR/do-maker.diff"           # small code change: no evidence needed
  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$BATS_TEST_TMPDIR/do-maker.md" --diff "$BATS_TEST_TMPDIR/do-maker.diff"
  [ "$status" -eq 1 ]
  _diff src/a.py 25 tests/test_a.py 5 > "$BATS_TEST_TMPDIR/do-maker.diff"   # 25 code lines, no evidence
  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$BATS_TEST_TMPDIR/do-maker.md" --diff "$BATS_TEST_TMPDIR/do-maker.diff"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No evidence in the report that tests ran (25 code lines"* ]]
  echo "Ran the suite: 12 passed." > "$BATS_TEST_TMPDIR/do-maker.md"
  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$BATS_TEST_TMPDIR/do-maker.md" --diff "$BATS_TEST_TMPDIR/do-maker.diff"
  [ "$status" -eq 1 ]
}

@test "maker: code files the proposal does not mention are out of scope (tests and docs are not)" {
  echo "pytest: 3 passed" > "$BATS_TEST_TMPDIR/do-maker.md"
  echo "Change calc.py and add tests." > "$BATS_TEST_TMPDIR/plan-creator.md"
  _diff src/calc.py 3 tests/test_calc.py 3 README.md 2 > "$BATS_TEST_TMPDIR/do-maker.diff"
  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$BATS_TEST_TMPDIR/do-maker.md" \
    --diff "$BATS_TEST_TMPDIR/do-maker.diff" --proposal "$BATS_TEST_TMPDIR/plan-creator.md"
  [ "$status" -eq 1 ]
  _diff src/calc.py 3 src/extra.py 3 > "$BATS_TEST_TMPDIR/do-maker.diff"
  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$BATS_TEST_TMPDIR/do-maker.md" \
    --diff "$BATS_TEST_TMPDIR/do-maker.diff" --proposal "$BATS_TEST_TMPDIR/plan-creator.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 code files changed outside proposal scope"* ]]
}

@test "maker: a detection is logged in phase do, with the cycle derived from the log" {
  "$LIB_DIR/archeflow-event.sh" mk-run run.start plan "" '{}' 2>/dev/null
  "$LIB_DIR/archeflow-event.sh" mk-run cycle.boundary act "" '{"cycle":1}' 2>/dev/null
  echo "done" > "$BATS_TEST_TMPDIR/do-maker.md"
  _diff src/a.py 1 src/b.py 1 src/c.py 1 > "$BATS_TEST_TMPDIR/do-maker.diff"
  run "$LIB_DIR/archeflow-shadow.sh" detect maker "$BATS_TEST_TMPDIR/do-maker.md" --diff "$BATS_TEST_TMPDIR/do-maker.diff" --run-id mk-run
  [ "$status" -eq 0 ]
  jq -se 'last | .type == "shadow.detected" and .phase == "do" and .data.cycle == 2' .archeflow/events/mk-run.jsonl
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

# ============================================================
# Tunnel Vision (from findings-cycle-<N>.json, 2+ reviewers, 3+ findings)
# ============================================================

_tv_run() {  # <run> <n-reviewers> <findings json>
  mkdir -p ".archeflow/artifacts/$1"
  local r
  for r in guardian skeptic sage trickster; do
    [[ "$2" -gt 0 ]] || break
    printf '## Review\n| a.py:1 | WARNING | security | x |\nREJECTED\n' > ".archeflow/artifacts/$1/check-$r.md"
    set -- "$1" "$(( $2 - 1 ))" "$3"
  done
  printf '%s\n' "$3" > ".archeflow/artifacts/$1/findings-cycle-1.json"
}

@test "check-system: approved run with no findings is CLEAN (regression: tunnel_vision with 0 categories)" {
  mkdir -p .archeflow/artifacts/tv-clean
  printf '## Review\nNo findings. Security and design look fine.\n\nAPPROVED\n' > .archeflow/artifacts/tv-clean/check-guardian.md
  echo '[]' > .archeflow/artifacts/tv-clean/findings-cycle-1.json
  run "$LIB_DIR/archeflow-shadow.sh" check-system tv-clean
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLEAN"* ]]
}

@test "check-system: a single reviewer never shows tunnel vision" {
  _tv_run tv-one 1 '[{"id":"a:security","category":"security"},{"id":"b:security","category":"security"},{"id":"c:security","category":"security"}]'
  run "$LIB_DIR/archeflow-shadow.sh" check-system tv-one
  [ "$status" -eq 1 ]
}

@test "check-system: 2 reviewers, 3 findings, one category -> tunnel_vision" {
  _tv_run tv-yes 2 '[{"id":"a:security","category":"security"},{"id":"b:security","category":"Security"},{"id":"c:security","category":"security"}]'
  run "$LIB_DIR/archeflow-shadow.sh" check-system tv-yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"tunnel_vision"*"3 findings of 2 reviewers"*"security"* ]]
  # logged as a system shadow of cycle 1
  jq -se 'map(select(.type == "shadow.detected")) | length == 1 and .[0].data.archetype == "system" and .[0].data.shadow == "tunnel_vision" and .[0].data.cycle == 1' .archeflow/events/tv-yes.jsonl
}

@test "check-system: 2 reviewers with mixed categories, or fewer than 3 findings, are CLEAN" {
  _tv_run tv-mixed 2 '[{"id":"a:security","category":"security"},{"id":"b:testing","category":"testing"},{"id":"c:security","category":"security"}]'
  run "$LIB_DIR/archeflow-shadow.sh" check-system tv-mixed
  [ "$status" -eq 1 ]
  _tv_run tv-few 3 '[{"id":"a:security","category":"security"},{"id":"b:security","category":"security"}]'
  run "$LIB_DIR/archeflow-shadow.sh" check-system tv-few
  [ "$status" -eq 1 ]
}

@test "check-system: --cycle picks that cycle's findings file and is recorded" {
  _tv_run tv-cyc 2 '[]'
  printf '%s\n' '[{"id":"a:x","category":"design"},{"id":"b:x","category":"design"},{"id":"c:x","category":"design"}]' \
    > .archeflow/artifacts/tv-cyc/findings-cycle-2.json
  run "$LIB_DIR/archeflow-shadow.sh" check-system tv-cyc --cycle 1
  [ "$status" -eq 1 ]
  run "$LIB_DIR/archeflow-shadow.sh" check-system tv-cyc --cycle 2
  [ "$status" -eq 0 ]
  jq -e 'select(.type == "shadow.detected") | .data.cycle == 2' .archeflow/events/tv-cyc.jsonl
  run "$LIB_DIR/archeflow-shadow.sh" check-system tv-cyc --cycle zero
  [ "$status" -eq 2 ]
}

@test "check-system: echo chamber counts only the current cycle's review.verdict events" {
  "$LIB_DIR/archeflow-event.sh" r-ec review.verdict check guardian '{"archetype":"guardian","verdict":"APPROVED","findings":[]}' 2>/dev/null
  "$LIB_DIR/archeflow-event.sh" r-ec cycle.boundary act "" '{"cycle":1}' 2>/dev/null
  "$LIB_DIR/archeflow-event.sh" r-ec review.verdict check guardian '{"archetype":"guardian","verdict":"APPROVED","findings":[]}' 2>/dev/null
  run "$LIB_DIR/archeflow-shadow.sh" check-system r-ec
  [ "$status" -eq 1 ]
  "$LIB_DIR/archeflow-event.sh" r-ec review.verdict check sage '{"archetype":"sage","verdict":"APPROVED","findings":[]}' 2>/dev/null
  run "$LIB_DIR/archeflow-shadow.sh" check-system r-ec
  [ "$status" -eq 0 ]
  [[ "$output" == *"echo_chamber"*"2 reviewers"* ]]
}

@test "check-system: a reviewer with findings breaks the echo chamber" {
  "$LIB_DIR/archeflow-event.sh" r-ec2 review.verdict check guardian '{"archetype":"guardian","verdict":"APPROVED","findings":[]}' 2>/dev/null
  "$LIB_DIR/archeflow-event.sh" r-ec2 review.verdict check sage '{"archetype":"sage","verdict":"APPROVED","findings":[{"severity":"INFO","description":"naming"}]}' 2>/dev/null
  run "$LIB_DIR/archeflow-shadow.sh" check-system r-ec2
  [ "$status" -eq 1 ]
}
