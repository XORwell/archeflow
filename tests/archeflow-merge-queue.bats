# Tests for archeflow-merge-queue.sh — enqueue, conflict check, merge, summary.

setup() {
  load test_helper
  _common_setup
  MQ="$LIB_DIR/archeflow-merge-queue.sh"
}

teardown() {
  _common_teardown
}

# make_branch <name> <file> <content>: branch off main with one commit.
make_branch() {
  git checkout --quiet -b "$1" main
  echo "$3" > "$2"
  git add "$2"
  git commit --quiet -m "change $2 on $1"
  git checkout --quiet main
}

@test "merge-queue: no args prints usage and fails" {
  run "$MQ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"enqueue"* ]]
}

@test "merge-queue: enqueue records the branch with priority, files and commits" {
  make_branch feat-a a.txt a
  run "$MQ" enqueue feat-a --priority 2
  [ "$status" -eq 0 ]
  jq -e '.branch == "feat-a" and .priority == 2 and .files_changed == 1 and .commits == 1 and .state == "pending"' \
    .archeflow/merge-queue/queue.jsonl
}

@test "merge-queue: enqueue rejects missing branches, option-like names and non-integer priority" {
  run "$MQ" enqueue does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
  make_branch feat-a a.txt a
  run "$MQ" enqueue feat-a --priority '1+1'
  [ "$status" -ne 0 ]
  [[ "$output" == *"integer"* ]]
  run "$MQ" enqueue --output=/tmp/x
  [ "$status" -ne 0 ]
  [ ! -f .archeflow/merge-queue/queue.jsonl ] || ! grep -q -- '--output' .archeflow/merge-queue/queue.jsonl
}

@test "merge-queue: unknown strategy is rejected and nothing is marked merged" {
  make_branch feat-a a.txt a
  "$MQ" enqueue feat-a
  run "$MQ" merge --strategy rebase
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown merge strategy"* ]]
  ! jq -e 'select(.state == "merged")' .archeflow/merge-queue/queue.jsonl
  [ ! -f a.txt ]
}

@test "merge-queue: squash merge lands the change and the summary counts it" {
  make_branch feat-a a.txt a
  make_branch feat-b b.txt b
  "$MQ" enqueue feat-a --priority 1
  "$MQ" enqueue feat-b --priority 2
  run "$MQ" merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"Merge run complete: 2 merged, 0 failed"* ]]
  [ -f a.txt ] && [ -f b.txt ]
  [ "$(git log -1 --format=%s)" = "feat: merge feat-b" ]
  [ "$(jq -s '[.[] | select(.state == "merged")] | length' .archeflow/merge-queue/queue.jsonl)" -eq 2 ]
}

@test "merge-queue: no-ff merge creates a merge commit" {
  make_branch feat-a a.txt a
  "$MQ" enqueue feat-a
  run "$MQ" merge --strategy no-ff
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 merged, 0 failed"* ]]
  git rev-parse --verify --quiet HEAD^2 >/dev/null
}

@test "merge-queue: check blocks branches touching the same file" {
  make_branch feat-a shared.txt a
  make_branch feat-b shared.txt b
  "$MQ" enqueue feat-a
  "$MQ" enqueue feat-b
  run "$MQ" check
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFLICT: feat-a <-> feat-b"* ]]
  [ "$(jq -s '[.[] | select(.state == "blocked")] | length' .archeflow/merge-queue/queue.jsonl)" -eq 2 ]
}

@test "merge-queue: a failed squash merge is counted and leaves a clean tree" {
  make_branch feat-a shared.txt a
  echo main-change > shared.txt
  git add shared.txt && git commit --quiet -m "main edits shared"
  "$MQ" enqueue feat-a
  run "$MQ" merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 merged, 1 failed"* ]]
  jq -e 'select(.branch == "feat-a") | .state == "blocked"' .archeflow/merge-queue/queue.jsonl
  git diff --quiet && git diff --cached --quiet
  [ "$(cat shared.txt)" = "main-change" ]
}

@test "merge-queue: option-like branch names read from the queue file are never merged" {
  # refs/heads/--output=... can exist (update-ref); it must not reach git as an option.
  git update-ref "refs/heads/--output=$BATS_TEST_TMPDIR/owned" HEAD
  mkdir -p .archeflow/merge-queue
  jq -cn --arg b "--output=$BATS_TEST_TMPDIR/owned" \
    '{branch:$b, priority:1, state:"ready", files_changed:0, commits:0, conflicts_with:[]}' \
    > .archeflow/merge-queue/queue.jsonl
  run "$MQ" merge
  [ ! -e "$BATS_TEST_TMPDIR/owned" ]
  [[ "$output" == *"0 merged, 0 failed"* ]]
}

@test "merge-queue: reset clears the queue" {
  make_branch feat-a a.txt a
  "$MQ" enqueue feat-a
  run "$MQ" reset
  [ "$status" -eq 0 ]
  [ ! -s .archeflow/merge-queue/queue.jsonl ]
}

@test "merge-queue: merge switches to the base branch first" {
  make_branch feat-a a.txt a
  "$MQ" enqueue feat-a
  git checkout --quiet -b elsewhere
  # base = current branch unless origin/HEAD exists; point origin/HEAD at main.
  git update-ref refs/remotes/origin/main main
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  run "$MQ" merge
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = "main" ]
  [ -f a.txt ]
}
