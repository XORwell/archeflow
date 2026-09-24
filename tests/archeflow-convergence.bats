# Tests for archeflow-convergence.sh — convergence score, oscillation, Wiggum Break.

setup() {
  load test_helper
  _common_setup
}

teardown() {
  _common_teardown
}

# ── score ──────────────────────────────────────────────────────

@test "score: exits 2 with usage on no args" {
  run "$LIB_DIR/archeflow-convergence.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage"* ]]
}

@test "score: exits 2 with usage when only subcommand given" {
  run "$LIB_DIR/archeflow-convergence.sh" score
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage"* ]]
}

@test "score: computes correct score with resolved and new findings" {
  cat > prev.json <<'EOF'
[{"id":"f1","file":"a.sh","category":"style","severity":"warning"},
 {"id":"f2","file":"b.sh","category":"bug","severity":"critical"},
 {"id":"f3","file":"c.sh","category":"style","severity":"info"}]
EOF
  cat > curr.json <<'EOF'
[{"id":"f2","file":"b.sh","category":"bug","severity":"critical"},
 {"id":"f4","file":"d.sh","category":"perf","severity":"warning"}]
EOF

  run "$LIB_DIR/archeflow-convergence.sh" score curr.json prev.json
  [ "$status" -eq 0 ]
  local score
  score=$(echo "$output" | jq -r '.convergence_score')
  [ "$score" = "0.67" ]
}

@test "score: resolved findings counted correctly" {
  cat > prev.json <<'EOF'
[{"id":"f1","file":"a.sh","category":"style","severity":"warning"},
 {"id":"f2","file":"b.sh","category":"bug","severity":"critical"}]
EOF
  cat > curr.json <<'EOF'
[{"id":"f2","file":"b.sh","category":"bug","severity":"critical"}]
EOF

  run "$LIB_DIR/archeflow-convergence.sh" score curr.json prev.json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.resolved')" -eq 1 ]
}

@test "score: new findings counted correctly" {
  cat > prev.json <<'EOF'
[{"id":"f1","file":"a.sh","category":"style","severity":"warning"}]
EOF
  cat > curr.json <<'EOF'
[{"id":"f1","file":"a.sh","category":"style","severity":"warning"},
 {"id":"f2","file":"b.sh","category":"bug","severity":"critical"}]
EOF

  run "$LIB_DIR/archeflow-convergence.sh" score curr.json prev.json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.new')" -eq 1 ]
}

@test "score: persistent findings counted correctly" {
  cat > prev.json <<'EOF'
[{"id":"f1","file":"a.sh","category":"style","severity":"warning"},
 {"id":"f2","file":"b.sh","category":"bug","severity":"critical"}]
EOF
  cat > curr.json <<'EOF'
[{"id":"f1","file":"a.sh","category":"style","severity":"warning"},
 {"id":"f2","file":"b.sh","category":"bug","severity":"critical"}]
EOF

  run "$LIB_DIR/archeflow-convergence.sh" score curr.json prev.json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.persistent')" -eq 2 ]
}

@test "score: empty findings produce score 1" {
  echo '[]' > prev.json
  echo '[]' > curr.json

  run "$LIB_DIR/archeflow-convergence.sh" score curr.json prev.json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.convergence_score >= 1')" = "true" ]
}

@test "score: all resolved yields score 1" {
  cat > prev.json <<'EOF'
[{"id":"f1","file":"a.sh","category":"style","severity":"warning"}]
EOF
  echo '[]' > curr.json

  run "$LIB_DIR/archeflow-convergence.sh" score curr.json prev.json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.convergence_score >= 1')" = "true" ]
  [ "$(echo "$output" | jq -r '.status')" = "converging" ]
}

# ── oscillation ────────────────────────────────────────────────

@test "oscillation: detects oscillating findings across 3 cycles" {
  cat > cycle_n2.json <<'EOF'
[{"id":"f1","file":"a.sh","category":"style","severity":"warning"},
 {"id":"f2","file":"b.sh","category":"bug","severity":"critical"}]
EOF
  echo '[]' > cycle_n1.json
  cat > cycle_n.json <<'EOF'
[{"id":"f1","file":"a.sh","category":"style","severity":"warning"},
 {"id":"f2","file":"b.sh","category":"bug","severity":"critical"}]
EOF

  run "$LIB_DIR/archeflow-convergence.sh" oscillation cycle_n.json cycle_n1.json cycle_n2.json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.oscillation_detected')" = "true" ]
  [ "$(echo "$output" | jq -r '.count')" -eq 2 ]
  [[ "$output" == *"hard_wiggum_break"* ]]
}

@test "oscillation: no detection when findings are stable" {
  cat > stable.json <<'EOF'
[{"id":"f1","file":"a.sh","category":"style","severity":"warning"}]
EOF

  run "$LIB_DIR/archeflow-convergence.sh" oscillation stable.json stable.json stable.json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.oscillation_detected')" = "false" ]
}

# ── wiggum-check ───────────────────────────────────────────────

@test "wiggum-check: returns false when no break conditions met" {
  mkdir -p run_dir

  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check run_dir
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.wiggum_break')" = "false" ]
}

@test "wiggum-check: exits 2 (error, not 'no break') on missing run dir" {
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check nonexistent_dir
  [ "$status" -eq 2 ]
  [[ "$output" == *"not found"* ]]
}


# ── wiggum-check semantics (2026-09 review) ───────────────────

_ev() { printf '%s\n' "$@" > run_dir/events.jsonl; }

@test "wiggum-check: 3 different shadows in one cycle do NOT hard-break" {
  mkdir -p run_dir
  _ev '{"type":"shadow.detected","data":{"archetype":"guardian","shadow":"paranoid"}}' \
      '{"type":"shadow.detected","data":{"archetype":"skeptic","shadow":"paralytic"}}' \
      '{"type":"shadow.detected","data":{"archetype":"sage","shadow":"bureaucrat"}}'
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check run_dir
  [ "$status" -eq 1 ]
  jq -e '.wiggum_break == false' <<<"$output"
}

@test "wiggum-check: same shadow 3x in one cycle hard-breaks" {
  mkdir -p run_dir
  _ev '{"type":"shadow.detected","data":{"archetype":"guardian","shadow":"paranoid","cycle":2}}' \
      '{"type":"shadow.detected","data":{"archetype":"guardian","shadow":"paranoid","cycle":2}}' \
      '{"type":"shadow.detected","data":{"archetype":"guardian","shadow":"paranoid","cycle":2}}'
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check run_dir
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.type')" = "hard" ]
  [[ "$output" == *"guardian/paranoid x3 in cycle 2"* ]]
}

@test "wiggum-check: same shadow 3x spread over cycles does NOT hard-break" {
  mkdir -p run_dir
  _ev '{"type":"shadow.detected","data":{"archetype":"guardian","shadow":"paranoid","cycle":1}}' \
      '{"type":"shadow.detected","data":{"archetype":"guardian","shadow":"paranoid","cycle":2}}' \
      '{"type":"shadow.detected","data":{"archetype":"guardian","shadow":"paranoid","cycle":3}}'
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check run_dir
  [ "$status" -eq 1 ]
  jq -e '.wiggum_break == false' <<<"$output"
}

@test "wiggum-check: 3 non-consecutive agent failures do NOT hard-break" {
  mkdir -p run_dir
  _ev '{"type":"agent.failed"}' '{"type":"agent.complete"}' \
      '{"type":"agent.timeout"}' '{"type":"agent.complete"}' '{"type":"agent.failed"}'
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check run_dir
  [ "$status" -eq 1 ]
  jq -e '.wiggum_break == false' <<<"$output"
}

@test "wiggum-check: 3 consecutive agent failures/timeouts hard-break" {
  mkdir -p run_dir
  _ev '{"type":"agent.complete"}' '{"type":"agent.failed"}' '{"type":"phase.transition"}' \
      '{"type":"agent.timeout"}' '{"type":"agent.failed"}'
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check run_dir
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 consecutive agent failures"* ]]
}

@test "wiggum-check: null convergence scores are not treated as diverging" {
  mkdir -p run_dir/cycle-1 run_dir/cycle-2
  echo '{"convergence_score":null}' > run_dir/cycle-1/convergence.json
  echo '{"convergence_score":null}' > run_dir/cycle-2/convergence.json
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check run_dir
  [ "$status" -eq 1 ]
  jq -e '.wiggum_break == false' <<<"$output"
}

@test "wiggum-check: budget soft break reads costs.budget_usd from YAML config" {
  mkdir -p .archeflow/runs/r1
  printf 'costs:\n  budget_usd: 10.00\n' > .archeflow/config.yaml
  printf '%s\n' '{"type":"cost.recorded","data":{"estimated_cost_usd":9.70}}' > .archeflow/runs/r1/events.jsonl
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check .archeflow/runs/r1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Budget >95% spent"* ]]
}

# ── wiggum-check on the layout a real run writes ──────────────
# Fixtures come from the real emitters (archeflow-event.sh, archeflow-shadow.sh),
# not from files hand-placed where wiggum-check happens to look.

@test "wiggum-check <run_id>: 3 identical shadow events from archeflow-event.sh hard-break" {
  for _ in 1 2 3; do
    "$LIB_DIR/archeflow-event.sh" r-shadow shadow.detected check guardian \
      '{"archetype":"guardian","shadow":"paranoid","trigger":"t","cycle":1}' >/dev/null
  done
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check r-shadow
  [ "$status" -eq 0 ]
  jq -e '.wiggum_break == true and .type == "hard"' <<<"$output"
  [[ "$output" == *"guardian/paranoid x3 in cycle 1"* ]]
}

@test "wiggum-check <artifact dir>: resolves .archeflow/events/<run_id>.jsonl" {
  mkdir -p .archeflow/artifacts/r-dir
  for _ in 1 2 3; do
    "$LIB_DIR/archeflow-event.sh" r-dir shadow.detected check sage \
      '{"archetype":"sage","shadow":"bureaucrat","trigger":"t"}' >/dev/null
  done
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check .archeflow/artifacts/r-dir
  [ "$status" -eq 0 ]
  jq -e '.wiggum_break == true and .type == "hard"' <<<"$output"
}

@test "wiggum-check: shadow.detected events written by archeflow-shadow.sh detect count" {
  cat > guardian.md <<'MD'
- CRITICAL: token logged in plain text at auth.py:10
- CRITICAL: SQL built by string concatenation at db.py:22
- CRITICAL: session id not rotated at login.py:5
REJECTED
MD
  for _ in 1 2 3; do
    run "$LIB_DIR/archeflow-shadow.sh" detect guardian guardian.md --run-id r-detect --cycle 2
    [ "$status" -eq 0 ]
  done
  [ "$(wc -l < .archeflow/events/r-detect.jsonl | tr -d ' ')" -eq 3 ]
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check r-detect
  [ "$status" -eq 0 ]
  jq -e '.type == "hard"' <<<"$output"
  [[ "$output" == *"in cycle 2"* ]]
}

@test "wiggum-check <run_id>: post-merge revert decision event hard-breaks" {
  "$LIB_DIR/archeflow-event.sh" r-revert decision act "" \
    '{"what":"post_merge_test","chosen":"revert","rationale":"test suite failed after merge"}' >/dev/null
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check r-revert
  [ "$status" -eq 0 ]
  jq -e '.type == "hard"' <<<"$output"
  [[ "$output" == *"Test suite broken after merge"* ]]
}

@test "wiggum-check <run_id>: convergence-cycle-N.json in the artifact dir soft-break" {
  mkdir -p .archeflow/artifacts/r-conv
  echo '{"convergence_score":0.3}' > .archeflow/artifacts/r-conv/convergence-cycle-2.json
  echo '{"convergence_score":0.2}' > .archeflow/artifacts/r-conv/convergence-cycle-3.json
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check r-conv
  [ "$status" -eq 0 ]
  jq -e '.type == "soft"' <<<"$output"
}

@test "wiggum-check <run_id>: clean run reports no break (exit 1, valid JSON)" {
  "$LIB_DIR/archeflow-event.sh" r-clean run.start plan "" '{"task":"x"}' >/dev/null
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check r-clean
  [ "$status" -eq 1 ]
  jq -e '.wiggum_break == false' <<<"$output"
}

@test "convergence: --help exits 0" {
  run "$LIB_DIR/archeflow-convergence.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"wiggum-check"* ]]
}

@test "wiggum-check: two cycles without open findings are not 'unchanged findings'" {
  mkdir -p .archeflow/artifacts/r-empty
  echo '[]' > .archeflow/artifacts/r-empty/findings-cycle-1.json
  echo '[]' > .archeflow/artifacts/r-empty/findings-cycle-2.json
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check r-empty
  [ "$status" -eq 1 ]
  jq -e '.wiggum_break == false' <<<"$output"
}
