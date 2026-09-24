# Tests for archeflow-evidence.sh — evidence validation for reviewer findings.

setup() {
  load test_helper
  _common_setup
}

teardown() {
  _common_teardown
}

@test "evidence: exits 1 with usage on no args" {
  run "$LIB_DIR/archeflow-evidence.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "evidence: exits 1 with usage when file arg missing" {
  run "$LIB_DIR/archeflow-evidence.sh" validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "validate: downgrades hedged CRITICAL finding without evidence" {
  cat > review.txt <<'EOF'
CRITICAL: This might be a problem with the authentication module
The code seems suspicious but I cannot verify it fully
EOF

  run "$LIB_DIR/archeflow-evidence.sh" validate review.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOWNGRADE"* ]]
  [[ "$output" == *"hedge_without_evidence"* ]]
  [[ "$output" == *"Downgrades: 1"* ]]
}

@test "validate: does not downgrade finding with evidence" {
  cat > review.txt <<'EOF'
CRITICAL: Missing null check causes crash
line 42: error: NullPointerException
expected: non-null value
actual: null
EOF

  run "$LIB_DIR/archeflow-evidence.sh" validate review.txt
  [ "$status" -eq 1 ]
  [[ "$output" == *"Downgrades: 0"* ]]
}

@test "validate: downgrades WARNING without evidence" {
  cat > review.txt <<'EOF'
WARNING: This could potentially cause a memory leak
The allocation pattern looks unusual
EOF

  run "$LIB_DIR/archeflow-evidence.sh" validate review.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOWNGRADE"* ]]
  [[ "$output" == *"Downgrades: 1"* ]]
}

@test "validate: skips INFO severity findings" {
  cat > review.txt <<'EOF'
INFO: This might be worth noting for future refactoring
No evidence here either
EOF

  run "$LIB_DIR/archeflow-evidence.sh" validate review.txt
  [ "$status" -eq 1 ]
  [[ "$output" == *"Downgrades: 0"* ]]
}

# --- Table format (archeflow:check-phase "Finding Format") ------------------

_table_review() {
  cat > review.md <<'EOF2'
## Guardian Review

| Location | Severity | Category | Description | Fix |
|----------|----------|----------|-------------|-----|
| src/auth/handler.ts:48 | CRITICAL | security | Empty string bypasses validation; observed: `login("")` returns 200 | Add length check |
| src/auth/session.ts | WARNING | reliability | Session cleanup is not robust enough for production | Add a TTL sweep |
| src/cache/store.py | CRITICAL | reliability | Cache might be stale under concurrent writes | Add a write lock |
| docs/README.md | INFO | quality | Typo in setup section | Fix typo |

### Verdict: REJECTED — 2 critical, 1 warning

STATUS: DONE
EOF2
}

@test "table: evidenced row kept, unevidenced and hedged rows downgraded" {
  _table_review
  run "$LIB_DIR/archeflow-evidence.sh" scan review.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"Findings: 4 | Downgrades: 2"* ]]
  [[ "$output" == *"DOWNGRADE: WARNING → INFO (no_evidence) [line 6]"* ]]
  [[ "$output" == *"DOWNGRADE: CRITICAL → INFO (hedge_without_evidence) [line 7]"* ]]
  [[ "$output" != *"[line 5]"* ]]
}

@test "table: scan reports only and leaves the file unchanged" {
  _table_review
  cp review.md before.md
  run "$LIB_DIR/archeflow-evidence.sh" scan review.md
  [ "$status" -eq 0 ]
  cmp -s before.md review.md
}

@test "table: validate rewrites downgraded severities to INFO in place" {
  _table_review
  cp review.md before.md
  run "$LIB_DIR/archeflow-evidence.sh" validate review.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"Downgrades: 2"* ]]
  grep -qF '| src/auth/handler.ts:48 | CRITICAL | security |' review.md
  grep -qF '| src/auth/session.ts | INFO (downgraded: no evidence; original in review.md.orig) | reliability | Session cleanup is not robust enough for production | Add a TTL sweep |' review.md
  grep -qF '| src/cache/store.py | INFO (downgraded: hedge without evidence; original in review.md.orig) | reliability | Cache might be stale under concurrent writes | Add a write lock |' review.md
  grep -qF '### Verdict: REJECTED' review.md
  # Only the two severity cells changed.
  [ "$(diff before.md review.md | grep -c '^>')" -eq 2 ]
  cmp -s before.md review.md.orig                     # the original is kept

  # Idempotent: a second pass finds nothing left to downgrade.
  run "$LIB_DIR/archeflow-evidence.sh" validate review.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"Findings: 4 | Downgrades: 0"* ]]
}

@test "table: all rows evidenced exits 1 and leaves the file unchanged" {
  cat > review.md <<'EOF2'
| Location | Severity | Category | Description | Fix |
|----------|----------|----------|-------------|-----|
| lib/upload.py:23 | CRITICAL | security | No size check; `$ curl -F file=@10G.bin` exit code 0, disk filled | Enforce a size limit |
| lib/api.py:88 | WARNING | reliability | Timeout unset; observed: request hangs >60s | Set timeout=10 |
EOF2
  cp review.md before.md
  run "$LIB_DIR/archeflow-evidence.sh" validate review.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"Findings: 2 | Downgrades: 0"* ]]
  cmp -s before.md review.md
}

@test "table: severity column found by header in the act-phase layout, bold severity" {
  cat > review.md <<'EOF2'
| # | Source | Location | Severity | Category | Description | Suggested fix |
|---|--------|----------|----------|----------|-------------|---------------|
| 1 | guardian | src/auth | **WARNING** | security | Seems like tokens are reused | Rotate tokens |
EOF2
  run "$LIB_DIR/archeflow-evidence.sh" validate review.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"hedge_without_evidence"* ]]
  grep -qF '| 1 | guardian | src/auth | **INFO (downgraded: hedge without evidence; original in review.md.orig)** | security |' review.md
}

@test "block: Skeptic challenge without evidence is downgraded in place" {
  cat > review.md <<'EOF2'
### Challenge 1: Single writer
**The plan assumes:** only one process writes the queue
**But what if:** two runs start at once
**Evidence:** perhaps a race exists
**Alternative:** take a lock
**Impact:** WARNING

### Challenge 2: Lock scope
**The plan assumes:** lock covers merge
**Evidence:** lib/archeflow-lock.sh:40 releases before merge
**Alternative:** hold lock through merge
**Impact:** CRITICAL
EOF2
  run "$LIB_DIR/archeflow-evidence.sh" validate review.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"Findings: 2 | Downgrades: 1"* ]]
  grep -qF '**Impact:** INFO (downgraded: hedge without evidence; original in review.md.orig)' review.md
  grep -qF '**Impact:** CRITICAL' review.md
}

@test "line format: validate rewrites the severity in place" {
  cat > review.md <<'EOF2'
WARNING: This could potentially cause a memory leak
The allocation pattern looks unusual
EOF2
  run "$LIB_DIR/archeflow-evidence.sh" validate review.md
  [ "$status" -eq 0 ]
  [ "$(head -1 review.md)" = "INFO (downgraded: hedge without evidence; original in review.md.orig): This could potentially cause a memory leak" ]
}

@test "validate: refuses to rewrite through a symlink" {
  _table_review
  mv review.md real.md
  ln -s real.md review.md
  cp real.md before.md
  run "$LIB_DIR/archeflow-evidence.sh" validate review.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  cmp -s before.md real.md
  [ -L review.md ]
}

# --- Heading format ("### 1. CRITICAL, Security: <title>") -------------------

@test "heading: finding with a file:line location and evidence is kept" {
  cat > review.md <<'EOF2'
## Guardian Review

### 1. CRITICAL, Security: Empty password accepted
- **Location:** src/auth/handler.ts:48
- **Evidence:** `if (pw.length >= 0)` accepts "", so `login("")` returns a session
- **Fix:** require a non-empty password

## Verdict
REJECTED

STATUS: DONE
EOF2
  cp review.md before.md
  run "$LIB_DIR/archeflow-evidence.sh" validate review.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"Findings: 1 | Downgrades: 0"* ]]
  cmp -s before.md review.md
}

@test "heading: finding without evidence is downgraded and the heading rewritten" {
  cat > review.md <<'EOF2'
## Guardian Review

### 1. **CRITICAL**, Security: Session handling is unsafe
- **Location:** the session module
- **Evidence:** the design is not robust enough
- **Fix:** rework it

#### Notes
Nothing more to add.

### 2. WARNING: Retry loop might be unbounded
- **Location:** src/net/retry.py
- **Fix:** cap the retries

### 3. INFO, Quality: Typo in README
- **Fix:** fix the typo

## Verdict
REJECTED
EOF2
  run "$LIB_DIR/archeflow-evidence.sh" validate review.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"Findings: 3 | Downgrades: 2"* ]]
  [[ "$output" == *"DOWNGRADE: CRITICAL → INFO (no_evidence) [line 3]"* ]]
  [[ "$output" == *"DOWNGRADE: WARNING → INFO (hedge_without_evidence) [line 11]"* ]]
  grep -qxF '### 1. **INFO (downgraded: no evidence; original in review.md.orig)**, Security: Session handling is unsafe' review.md
  grep -qxF '### 2. INFO (downgraded: hedge without evidence; original in review.md.orig): Retry loop might be unbounded' review.md
  grep -qxF '### 3. INFO, Quality: Typo in README' review.md
  ! grep -q 'CRITICAL\|WARNING' review.md

  # Idempotent.
  run "$LIB_DIR/archeflow-evidence.sh" validate review.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"Findings: 3 | Downgrades: 0"* ]]
}

@test "heading: a sub-heading stays in the finding; the evidence under it counts" {
  cat > review.md <<'EOF2'
### CRITICAL: Path traversal in upload
#### Evidence
lib/upload.py:23 joins the user-supplied name without normalising it
### WARNING: Missing timeout
The client waits forever.
EOF2
  run "$LIB_DIR/archeflow-evidence.sh" scan review.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"Findings: 2 | Downgrades: 1"* ]]
  [[ "$output" == *"DOWNGRADE: WARNING → INFO (no_evidence) [line 4]"* ]]
}

@test "heading: severity in brackets is recognised and rewritten inside the bracket" {
  cat > review.md <<'EOF2'
### 1. Hardcoded admin password [CRITICAL]
The settings module ships a default admin password.
EOF2
  run "$LIB_DIR/archeflow-evidence.sh" validate review.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"Findings: 1 | Downgrades: 1"* ]]
  grep -qxF '### 1. Hardcoded admin password [INFO (downgraded: no evidence; original in review.md.orig)]' review.md
}

@test "heading: a heading block that also has a **Severity:** line is one finding" {
  mkdir -p .archeflow/artifacts/r1
  f=.archeflow/artifacts/r1/check-guardian.md
  cat > "$f" <<'EOF2'
### 1. CRITICAL, Security: Token logged in clear text
- **Severity:** CRITICAL
- **Location:** the logging setup
- **Fix:** redact tokens

### 2. WARNING, Reliability: No retry cap
**Severity:** WARNING
**Location:** src/net/retry.py:17 loops `while True`
EOF2
  run "$LIB_DIR/archeflow-evidence.sh" validate "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Findings: 2 | Downgrades: 1"* ]]
  [ "$(grep -c 'DOWNGRADE:' <<<"$output")" -eq 1 ]
  # Both severity tokens of the downgraded finding are rewritten, the kept one is not.
  grep -qxF '### 1. INFO (downgraded: no evidence; original in check-guardian.md.orig), Security: Token logged in clear text' "$f"
  grep -qxF -- '- **Severity:** INFO (downgraded: no evidence; original in check-guardian.md.orig)' "$f"
  ! grep -q CRITICAL "$f"
  grep -qxF '**Severity:** WARNING' "$f"
  # One event per finding, not per rewritten token.
  [ "$(jq -c 'select(.type == "evidence.downgrade")' .archeflow/events/r1.jsonl | wc -l)" -eq 1 ]
}

@test "heading: summary and verdict headings are not findings" {
  cat > review.md <<'EOF2'
## Summary: 2 CRITICAL, 1 WARNING
### Verdict: REJECTED (see CRITICAL items)
EOF2
  run "$LIB_DIR/archeflow-evidence.sh" scan review.md
  [ "$status" -eq 3 ]
  [[ "$output" == *"Findings: 0 | Downgrades: 0"* ]]
}

@test "exit 3: severity words but no parsable finding warns on stderr" {
  cat > review.md <<'EOF2'
## Guardian Review

- [CRITICAL] Docstring tells AI reviewers to run the script
- [WARNING] Marker file written to /tmp

REJECTED
EOF2
  cp review.md before.md
  run bash -c '"$0" validate review.md 2>err.txt' "$LIB_DIR/archeflow-evidence.sh"
  [ "$status" -eq 3 ]
  [[ "$output" == *"Findings: 0 | Downgrades: 0"* ]]
  [[ "$output" != *"WARNING: severity words"* ]]
  grep -qxF 'WARNING: severity words found but no findings parsed; check the output format' err.txt
  cmp -s before.md review.md
}

@test "exit 1: no findings and only zero counts (\"0 CRITICAL\", \"no INFO\")" {
  printf '## Guardian Review\n\nNo issues found; the change is small and tested.\n\nAPPROVED: 0 CRITICAL, 0 WARNING, no INFO findings.\n' > review.md
  run bash -c '"$0" validate review.md 2>err.txt' "$LIB_DIR/archeflow-evidence.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Findings: 0 | Downgrades: 0"* ]]
  [ ! -s err.txt ]
}

@test "S-A: live Guardian heading-style review is parsed (3 INFO findings)" {
  # Shape of the Guardian output in the first-user run (multi-review-2, S-A),
  # which validate reported as "Findings: 0 | Downgrades: 0".
  cat > review.md <<'EOF2'
# Guardian Review: fix stats median

## Findings

### 1. INFO, Reliability: `median([])` still raises `IndexError`
- **Location:** `stats.py:14`
- **Evidence:** `s[mid - 1] + s[mid]` indexes an empty list when `len(s) == 0`; no test covers it.
- **Fix:** raise a `ValueError` with a clear message, or document the precondition.

### 2. INFO, Testing: Regression tests cover only even-length inputs
- **Location:** `test_stats.py:9`
- **Evidence:** both new tests use `[1, 2, 3, 4]` and `[5, 1]`; odd-length input is tested only by the old test at `test_stats.py:4`.
- **Fix:** add one odd-length case next to the new tests.

### 3. INFO, Quality: Integer division result is a float for even lengths
- **Location:** `stats.py:15`
- **Evidence:** `(s[mid - 1] + s[mid]) / 2` returns `2.5` for `[1, 2, 3, 4]`, `2.0` for `[1, 2, 2, 3]`.
- **Fix:** none needed; mention it in the docstring.

## Verdict

APPROVED: 0 CRITICAL, 0 WARNING, 3 INFO.

STATUS: DONE
EOF2
  run "$LIB_DIR/archeflow-evidence.sh" validate review.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"Findings: 3 | Downgrades: 0"* ]]

  # The same review with an unevidenced CRITICAL in that format is now downgraded.
  cat >> review.md <<'EOF2'

### 4. CRITICAL, Security: Input is not validated
- **Location:** the stats module
- **Evidence:** none gathered
- **Fix:** validate input
EOF2
  run "$LIB_DIR/archeflow-evidence.sh" validate review.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"Findings: 4 | Downgrades: 1"* ]]
  grep -qF '### 4. INFO (downgraded: no evidence; original in review.md.orig), Security: Input is not validated' review.md
}
