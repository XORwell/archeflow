# Fuzz-style injection tests: malicious values in repository-supplied JSON
# (event logs, lessons, effectiveness scores, GNAP tasks, merge queue, agent
# card, index.jsonl, audit.jsonl) must never execute code.
#
# Bash evaluates $(( x )), (( x )) and [[ x -gt y ]] recursively, so a field
# like 'a[$(cmd)]' runs cmd if it reaches shell arithmetic. Every payload below
# tries to create $MARK; each test asserts it never appears.

setup() {
  load test_helper
  _common_setup
  MARK="$BATS_TEST_TMPDIR/pwned"
  PAYLOADS=(
    'BASH_VERSINFO[$(touch '"$MARK"')0]'
    'a[$(touch '"$MARK"')]'
    'x[`touch '"$MARK"'`]'
    '1+a[$(touch '"$MARK"')]'
    '$(touch '"$MARK"')'
    'm-1+BASH_VERSINFO[$(touch '"$MARK"')0]'
  )
  mkdir -p .archeflow/events .archeflow/memory
  # No network: a fake curl for the Langfuse bridge.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nprintf 200\n' > "$BATS_TEST_TMPDIR/bin/curl"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
}

teardown() {
  _common_teardown
}

assert_not_pwned() {
  if [[ -e "$MARK" ]]; then
    echo "code execution via payload: $1 ($2)" >&2
    return 1
  fi
}

# write_events <payload> <file> [seq_mode]
# Every numeric field carries the payload. seq_mode=bad also poisons seq/parent.
write_events() {
  local p="$1" f="$2" mode="${3:-ok}"
  jq -cn --arg p "$p" --arg mode "$mode" '
    def ev($seq; $parent; $type; $phase; $agent; $data):
      {ts:"2026-09-24T10:00:00Z", run_id:"r1",
       seq: (if $mode == "bad" then $p else $seq end),
       parent: (if $mode == "bad" then [$p] else $parent end),
       type:$type, phase:$phase, agent:$agent, data:$data};
    ev(1; []; "run.start"; "plan"; null;
       {task:"t", workflow:"fast", budget_usd:$p, max_cycles:$p}),
    ev(2; [1]; "agent.start"; "plan"; "creator"; {archetype:"creator"}),
    ev(3; [2]; "agent.complete"; "plan"; "creator";
       {archetype:"creator", duration_ms:$p, tokens:$p, start_seq:$p,
        tokens_input:$p, tokens_output:$p, estimated_cost_usd:$p}),
    ev(4; [3]; "decision.point"; "check"; "guardian";
       {archetype:"guardian", decision:"needs_changes", confidence:$p}),
    ev(5; [3]; "review.verdict"; "check"; "guardian";
       {archetype:"guardian", verdict:"needs_changes", critical:$p, warnings:$p, score:$p,
        findings:[{severity:"critical", description:"sql injection in login handler", category:"security"}]}),
    ev(6; [5]; "fix.applied"; "act"; null; {source:"guardian", finding:"sql injection in login handler", line:$p}),
    ev(7; [6]; "shadow.detected"; "check"; "guardian"; {archetype:"guardian", shadow:"paranoia", cycle:$p}),
    ev(8; [6]; "cycle.boundary"; "act"; null; {cycle:$p, max_cycles:$p, met:false, next_action:"continue"}),
    ev(9; [8]; "cost.recorded"; "act"; "maker";
       {model:"m", input_tokens:$p, output_tokens:$p, total_tokens:$p, tokens:$p}),
    ev(10; [9]; "run.complete"; "act"; null;
       {status:"ok", cycles:$p, duration_ms:$p, agents_total:$p, fixes_total:$p, shadows:$p})
  ' > "$f"
}

@test "fuzz: report/dag/progress/replay never evaluate event fields" {
  for mode in ok bad; do
    for p in "${PAYLOADS[@]}"; do
      write_events "$p" .archeflow/events/r1.jsonl "$mode"
      "$LIB_DIR/archeflow-report.sh" .archeflow/events/r1.jsonl >/dev/null 2>&1 || true
      "$LIB_DIR/archeflow-report.sh" .archeflow/events/r1.jsonl --summary >/dev/null 2>&1 || true
      "$LIB_DIR/archeflow-dag.sh" .archeflow/events/r1.jsonl --no-color >/dev/null 2>&1 || true
      "$LIB_DIR/archeflow-progress.sh" r1 >/dev/null 2>&1 || true
      "$LIB_DIR/archeflow-progress.sh" r1 --json >/dev/null 2>&1 || true
      "$LIB_DIR/archeflow-replay.sh" timeline r1 >/dev/null 2>&1 || true
      "$LIB_DIR/archeflow-replay.sh" whatif r1 >/dev/null 2>&1 || true
      "$LIB_DIR/archeflow-replay.sh" compare r1 --json >/dev/null 2>&1 || true
      assert_not_pwned "$p" "report/dag/progress/replay mode=$mode"
    done
  done
}

@test "fuzz: memory extract/regression-check/audit-check never evaluate event fields" {
  for mode in ok bad; do
    for p in "${PAYLOADS[@]}"; do
      rm -rf .archeflow/memory; mkdir -p .archeflow/memory
      write_events "$p" .archeflow/events/r1.jsonl "$mode"
      write_events "$p" .archeflow/events/r0.jsonl "$mode"
      jq -cn --arg p "$p" '{run_id:"r0"}, {run_id:$p}, {run_id:"../../etc/passwd"}, {run_id:"r1"}' \
        > .archeflow/events/index.jsonl
      "$LIB_DIR/archeflow-memory.sh" extract .archeflow/events/r1.jsonl >/dev/null 2>&1 || true
      "$LIB_DIR/archeflow-memory.sh" regression-check .archeflow/events/r1.jsonl >/dev/null 2>&1 || true
      jq -cn --arg p "$p" '{run_id:"r1", lessons_injected:["m-001", $p]}' > .archeflow/memory/audit.jsonl
      "$LIB_DIR/archeflow-memory.sh" audit-check r1 >/dev/null 2>&1 || true
      assert_not_pwned "$p" "memory extract/regression/audit mode=$mode"
    done
  done
}

@test "fuzz: memory decay/add/inject/list/forget never evaluate lesson fields" {
  for p in "${PAYLOADS[@]}"; do
    jq -cn --arg p "$p" '
      {id:$p, type:"pattern", description:"d1", frequency:$p, runs_since_last_seen:$p, domain:"general", source:"s"},
      {id:"m-7", type:"pattern", description:"d2", frequency:$p, runs_since_last_seen:9, domain:"general", source:"s"},
      {id:("m-1+" + $p), type:"pattern", description:"d3", frequency:3, runs_since_last_seen:$p, domain:"general", source:"s"}
    ' > .archeflow/memory/lessons.jsonl
    "$LIB_DIR/archeflow-memory.sh" decay >/dev/null 2>&1 || true
    "$LIB_DIR/archeflow-memory.sh" add pattern "new lesson" >/dev/null 2>&1 || true
    "$LIB_DIR/archeflow-memory.sh" inject general guardian >/dev/null 2>&1 || true
    "$LIB_DIR/archeflow-memory.sh" list >/dev/null 2>&1 || true
    "$LIB_DIR/archeflow-memory.sh" forget "$p" >/dev/null 2>&1 || true
    assert_not_pwned "$p" "memory lifecycle"
  done
}

@test "fuzz: memory next_id ignores non-numeric ids and keeps counting" {
  jq -cn --arg p "${PAYLOADS[5]}" '{id:$p}, {id:"m-004"}, {id:"m-010"}' > .archeflow/memory/lessons.jsonl
  run "$LIB_DIR/archeflow-memory.sh" add pattern "another lesson"
  [ "$status" -eq 0 ]
  [ ! -e "$MARK" ]
  # m-010 is decimal 10 (not octal), so the next id is m-011.
  tail -1 .archeflow/memory/lessons.jsonl | jq -e '.id == "m-011"'
}

@test "fuzz: score extract/report/recommend never evaluate event or score fields" {
  printf 'archetypes:\n  - guardian\n  - sage\n' > team.yaml
  for p in "${PAYLOADS[@]}"; do
    rm -f .archeflow/memory/effectiveness.jsonl
    write_events "$p" .archeflow/events/r1.jsonl
    "$LIB_DIR/archeflow-score.sh" extract .archeflow/events/r1.jsonl >/dev/null 2>&1 || true
    jq -cn --arg p "$p" '{archetype:"guardian", composite_score:$p, model:"haiku", run_id:"r1"},
                         {archetype:"sage", composite_score:0.9, model:$p, run_id:$p}' \
      >> .archeflow/memory/effectiveness.jsonl
    "$LIB_DIR/archeflow-score.sh" report >/dev/null 2>&1 || true
    "$LIB_DIR/archeflow-score.sh" recommend team.yaml >/dev/null 2>&1 || true
    assert_not_pwned "$p" "score"
  done
}

@test "fuzz: langfuse bridge and backfill never evaluate event fields" {
  mkdir -p "$HOME/.config/archeflow"
  printf 'LANGFUSE_ENABLED=true\nLANGFUSE_HOST=http://127.0.0.1:9\nLANGFUSE_PUBLIC_KEY=a\nLANGFUSE_SECRET_KEY=b\n' \
    > "$HOME/.config/archeflow/langfuse.env"
  for mode in ok bad; do
    for p in "${PAYLOADS[@]}"; do
      write_events "$p" .archeflow/events/r1.jsonl "$mode"
      while IFS= read -r line; do
        printf '%s\n' "$line" | "$LIB_DIR/archeflow-langfuse.sh" >/dev/null 2>&1 || true
      done < .archeflow/events/r1.jsonl
      "$LIB_DIR/archeflow-langfuse-backfill.sh" r1 >/dev/null 2>&1 || true
      assert_not_pwned "$p" "langfuse mode=$mode"
    done
  done
}

@test "fuzz: convergence wiggum-check and shadow check-system never evaluate run data" {
  mkdir -p run/cycle-1
  for p in "${PAYLOADS[@]}"; do
    write_events "$p" run/events.jsonl
    jq -cn --arg p "$p" '{score:$p, cycle:$p, resolved:$p, new:$p}' > run/cycle-1/convergence.json
    jq -cn --arg p "$p" '[{id:$p, file:"a", category:"c", severity:"critical", line:$p}]' > run/findings-cycle-1.json
    printf '%s\n' "$p" > run/post-merge-test-result
    "$LIB_DIR/archeflow-convergence.sh" wiggum-check run >/dev/null 2>&1 || true
    "$LIB_DIR/archeflow-shadow.sh" check-system run >/dev/null 2>&1 || true
    assert_not_pwned "$p" "convergence/shadow"
  done
}

@test "fuzz: gnap import, merge-queue and a2a validate never evaluate file fields" {
  mkdir -p .gnap/tasks docs/orchestra .archeflow/merge-queue
  for p in "${PAYLOADS[@]}"; do
    echo '{"items":[]}' > docs/orchestra/queue.json
    jq -n --arg p "$p" '{id:$p, title:$p, state:$p, priority:$p, assigned_to:[$p], metadata:{project:$p}}' \
      > .gnap/tasks/evil.json
    "$LIB_DIR/archeflow-gnap.sh" import >/dev/null 2>&1 || true
    "$LIB_DIR/archeflow-gnap.sh" export >/dev/null 2>&1 || true
    "$LIB_DIR/archeflow-gnap.sh" status >/dev/null 2>&1 || true

    jq -cn --arg p "$p" '{branch:$p, priority:$p, state:"ready", files_changed:$p, commits:$p, conflicts_with:[]}' \
      > .archeflow/merge-queue/queue.jsonl
    "$LIB_DIR/archeflow-merge-queue.sh" status >/dev/null 2>&1 || true
    "$LIB_DIR/archeflow-merge-queue.sh" merge >/dev/null 2>&1 || true

    jq -n --arg p "$p" '{name:"n", description:"d", url:"u", version:"1", skills:$p}' > card.json
    "$LIB_DIR/archeflow-a2a.sh" validate card.json >/dev/null 2>&1 || true
    assert_not_pwned "$p" "gnap/merge-queue/a2a"
  done
}
