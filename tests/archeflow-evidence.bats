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
  grep -qF '| src/auth/session.ts | INFO | reliability | Session cleanup is not robust enough for production | Add a TTL sweep |' review.md
  grep -qF '| src/cache/store.py | INFO | reliability | Cache might be stale under concurrent writes | Add a write lock |' review.md
  grep -qF '### Verdict: REJECTED' review.md
  # Only the two severity cells changed.
  [ "$(diff before.md review.md | grep -c '^>')" -eq 2 ]

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
  grep -qF '| 1 | guardian | src/auth | **INFO** | security |' review.md
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
  grep -qF '**Impact:** INFO' review.md
  grep -qF '**Impact:** CRITICAL' review.md
}

@test "line format: validate rewrites the severity in place" {
  cat > review.md <<'EOF2'
WARNING: This could potentially cause a memory leak
The allocation pattern looks unusual
EOF2
  run "$LIB_DIR/archeflow-evidence.sh" validate review.md
  [ "$status" -eq 0 ]
  [ "$(head -1 review.md)" = "INFO: This could potentially cause a memory leak" ]
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
