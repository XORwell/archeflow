# Tests for archeflow-git.sh — git branch/commit strategy for ArcheFlow runs.
#
# Validates: branch creation with correct naming, commit formatting,
# merge strategies, input validation, and safety guards.

setup() {
  load test_helper
  _common_setup
}

teardown() {
  _common_teardown
}

# --- Usage ---

@test "git: exits 1 with usage when called with fewer than 2 args" {
  run "$LIB_DIR/archeflow-git.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "git: exits 1 for unknown command" {
  run "$LIB_DIR/archeflow-git.sh" nonexistent test-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown command"* ]]
}

# --- init ---

@test "git init: creates branch with archeflow/ prefix" {
  run "$LIB_DIR/archeflow-git.sh" init test-run
  [ "$status" -eq 0 ]
  local current
  current=$(git branch --show-current)
  [ "$current" = "archeflow/test-run" ]
}

@test "git init: stores base branch in .archeflow/runs/<run_id>/base-branch" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  [ -f ".archeflow/runs/test-run/base-branch" ]
  local base
  base=$(cat ".archeflow/runs/test-run/base-branch")
  [ "$base" = "main" ]
}

@test "git init: fails if branch already exists" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  git checkout main --quiet
  run "$LIB_DIR/archeflow-git.sh" init test-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

# --- commit ---

@test "git commit: uses conventional commit format by default" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  # Create a file to commit
  mkdir -p .archeflow/events
  echo '{"test":true}' > .archeflow/events/test-run.jsonl
  "$LIB_DIR/archeflow-git.sh" commit test-run plan "initial plan" 2>/dev/null
  local msg
  msg=$(git log -1 --format=%s)
  [[ "$msg" == "archeflow(plan): initial plan" ]]
}

@test "git commit: stages event file automatically" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  mkdir -p .archeflow/events
  echo '{"test":true}' > .archeflow/events/test-run.jsonl
  "$LIB_DIR/archeflow-git.sh" commit test-run plan "test commit" 2>/dev/null

  # Verify the event file was committed
  local committed_files
  committed_files=$(git diff-tree --no-commit-id --name-only -r HEAD)
  [[ "$committed_files" == *"test-run.jsonl"* ]]
}

@test "git commit: stages extra files passed as arguments" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  echo "extra content" > extra.txt
  "$LIB_DIR/archeflow-git.sh" commit test-run do "with extras" extra.txt 2>/dev/null
  local committed_files
  committed_files=$(git diff-tree --no-commit-id --name-only -r HEAD)
  [[ "$committed_files" == *"extra.txt"* ]]
}

@test "git commit: reports nothing to commit when no changes" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  # Commit the init artifacts first so there's a clean state
  git add -A && git commit -m "init artifacts" --quiet 2>/dev/null || true
  run bash -c "cd '$BATS_TEST_TMPDIR' && '$LIB_DIR/archeflow-git.sh' commit test-run plan 'empty' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to commit"* ]]
}

@test "git commit: fails if not on the run branch" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  git checkout main --quiet
  run "$LIB_DIR/archeflow-git.sh" commit test-run plan "wrong branch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Expected to be on branch"* ]]
}

# --- phase-commit ---

@test "git phase-commit: creates commit with phase transition message" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  mkdir -p .archeflow/events
  echo '{"test":true}' > .archeflow/events/test-run.jsonl
  "$LIB_DIR/archeflow-git.sh" phase-commit test-run plan 2>/dev/null
  local msg
  msg=$(git log -1 --format=%s)
  # Should contain the phase transition arrow
  [[ "$msg" == *"plan"* ]]
  [[ "$msg" == *"do"* ]]
}

# --- merge ---

@test "git merge: no-ff is the default strategy (revertable merge commit)" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  mkdir -p .archeflow/events
  echo '{"test":true}' > .archeflow/events/test-run.jsonl
  "$LIB_DIR/archeflow-git.sh" commit test-run plan "test" 2>/dev/null
  "$LIB_DIR/archeflow-git.sh" merge test-run 2>/dev/null

  [ "$(git branch --show-current)" = "main" ]
  [ "$(git log -1 --format=%s)" = "feat: archeflow run test-run complete" ]
  [ "$(git cat-file -p HEAD | grep -c '^parent')" -eq 2 ]
}

@test "git merge: git.merge_strategy from config is honoured (squash)" {
  mkdir -p .archeflow
  printf 'git:\n  merge_strategy: squash\n' > .archeflow/config.yaml
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  echo work > work.txt && git add work.txt && git commit -q -m work
  run "$LIB_DIR/archeflow-git.sh" merge test-run
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = "main" ]
  [ "$(git cat-file -p HEAD | grep -c '^parent')" -eq 1 ]
  [ "$(git log -1 --format=%s)" = "feat: archeflow run test-run complete" ]
  [ -f work.txt ]
}

@test "git merge: --no-ff creates a merge commit" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  mkdir -p .archeflow/events
  echo '{"test":true}' > .archeflow/events/test-run.jsonl
  "$LIB_DIR/archeflow-git.sh" commit test-run plan "test" 2>/dev/null
  "$LIB_DIR/archeflow-git.sh" merge test-run --no-ff 2>/dev/null

  local current
  current=$(git branch --show-current)
  [ "$current" = "main" ]

  # no-ff merge commit should have 2 parents
  local parent_count
  parent_count=$(git cat-file -p HEAD | grep -c '^parent')
  [ "$parent_count" -eq 2 ]
}

@test "git merge: rejects unknown merge strategy" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  mkdir -p .archeflow/events
  echo '{"test":true}' > .archeflow/events/test-run.jsonl
  "$LIB_DIR/archeflow-git.sh" commit test-run plan "test" 2>/dev/null
  run "$LIB_DIR/archeflow-git.sh" merge test-run --fast-forward
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown merge strategy"* ]]
}

@test "git merge: fails with uncommitted changes" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  echo "dirty" > dirty.txt
  git add dirty.txt
  run "$LIB_DIR/archeflow-git.sh" merge test-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Uncommitted changes"* ]]
}

# --- format_message ---

@test "git commit: simple style uses 'phase: msg' format" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  # Create config with simple style
  mkdir -p .archeflow
  echo "commit_style: simple" > .archeflow/config.yaml
  mkdir -p .archeflow/events
  echo '{"test":true}' > .archeflow/events/test-run.jsonl
  "$LIB_DIR/archeflow-git.sh" commit test-run plan "simple test" 2>/dev/null
  local msg
  msg=$(git log -1 --format=%s)
  [ "$msg" = "plan: simple test" ]
}

# --- status ---

@test "git status: shows branch info for existing run" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  run "$LIB_DIR/archeflow-git.sh" status test-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Branch: archeflow/test-run"* ]]
  [[ "$output" == *"Base: main"* ]]
}

@test "git status: fails for nonexistent branch" {
  run "$LIB_DIR/archeflow-git.sh" status nonexistent
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

# --- cleanup ---

@test "git cleanup: fails if currently on the run branch" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  run "$LIB_DIR/archeflow-git.sh" cleanup test-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot delete"* ]]
}

@test "git: cleanup refuses a traversal run_id (no rm -rf outside .archeflow/runs)" {
  mkdir -p "$BATS_TEST_TMPDIR/victim"
  touch "$BATS_TEST_TMPDIR/victim/keep"
  run "$LIB_DIR/archeflow-git.sh" cleanup "../../victim"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid run_id"* ]]
  [ -f "$BATS_TEST_TMPDIR/victim/keep" ]
}

@test "git commit: signing_key from config cannot inject extra git -c options" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  cat > "$BATS_TEST_TMPDIR/evil.sh" <<SH
#!/bin/sh
touch "$BATS_TEST_TMPDIR/pwned"
SH
  chmod +x "$BATS_TEST_TMPDIR/evil.sh"
  echo "signing_key: nokey -c core.fsmonitor=$BATS_TEST_TMPDIR/evil.sh" > .archeflow/config.yaml
  mkdir -p .archeflow/events
  echo '{"test":true}' > .archeflow/events/test-run.jsonl
  run "$LIB_DIR/archeflow-git.sh" commit test-run plan "signed"
  # Signing with a bogus key fails the commit; what matters is no code ran.
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}


@test "git merge: --rebase replays the run branch onto base and never rewrites base" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  mkdir -p .archeflow/events
  echo '{"test":true}' > .archeflow/events/test-run.jsonl
  "$LIB_DIR/archeflow-git.sh" commit test-run plan "run work" 2>/dev/null
  # Base moves on independently after the run branch was cut.
  git checkout main --quiet
  echo "base" > base.txt && git add base.txt && git commit -q -m "base change"
  local base_head
  base_head=$(git rev-parse HEAD)
  git checkout archeflow/test-run --quiet

  run "$LIB_DIR/archeflow-git.sh" merge test-run --rebase
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = "main" ]
  # Old base tip is still in main's history (base not rewritten) ...
  git merge-base --is-ancestor "$base_head" main
  # ... main was fast-forwarded to the rebased run branch ...
  [ "$(git rev-parse main)" = "$(git rev-parse archeflow/test-run)" ]
  # ... history is linear and contains both changes.
  [ "$(git rev-list --merges main | wc -l | tr -d ' ')" = "0" ]
  git log --format=%s main | grep -q "base change"
  git log --format=%s main | grep -q "run work"
}

@test "git merge: --rebase aborts cleanly on conflict and leaves base untouched" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  echo "run" > README.md && git add README.md && git commit -q -m "run edit"
  git checkout main --quiet
  echo "base" > README.md && git add README.md && git commit -q -m "base edit"
  local base_head
  base_head=$(git rev-parse HEAD)
  git checkout archeflow/test-run --quiet

  run "$LIB_DIR/archeflow-git.sh" merge test-run --rebase
  [ "$status" -ne 0 ]
  [[ "$output" == *"aborted"* ]]
  [ "$(git rev-parse main)" = "$base_head" ]
  [ ! -d .git/rebase-merge ] && [ ! -d .git/rebase-apply ]
}


@test "git: works when the default branch is master (no 'main' assumption)" {
  git branch -m main master
  run "$LIB_DIR/archeflow-git.sh" init test-run
  [ "$status" -eq 0 ]
  [ "$(cat .archeflow/runs/test-run/base-branch)" = "master" ]
  mkdir -p .archeflow/events
  echo '{"test":true}' > .archeflow/events/test-run.jsonl
  "$LIB_DIR/archeflow-git.sh" commit test-run plan "on master" 2>/dev/null
  run "$LIB_DIR/archeflow-git.sh" merge test-run
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = "master" ]
  ! git show-ref --verify --quiet refs/heads/main
}

@test "git init: refuses to start from a detached HEAD" {
  git checkout --quiet --detach HEAD
  run "$LIB_DIR/archeflow-git.sh" init test-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Detached HEAD"* ]]
}


# --- Maker worktree + integrate (the run skill's Do phase) ---

_maker_commit() {  # <worktree> <file> <content>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -- "$2"
  git -C "$1" commit -q -m "feat: $2"
}

@test "git worktree: creates the Maker worktree from the run branch and prints its path" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  echo plan > plan.txt && git add plan.txt && git commit -q -m "run-branch commit"
  run "$LIB_DIR/archeflow-git.sh" worktree test-run
  [ "$status" -eq 0 ]
  local wt="${lines[${#lines[@]}-1]}"
  [ -d "$wt" ]
  [ "$wt" = "$(pwd -P)/.archeflow/worktrees/test-run" ] || [ "$wt" = "$(pwd)/.archeflow/worktrees/test-run" ]
  [ "$(git -C "$wt" branch --show-current)" = "archeflow/test-run-maker" ]
  [ -f "$wt/plan.txt" ]                       # based on the run branch, not on main
  [ -z "$(git status --porcelain --untracked-files=all -- .archeflow/worktrees)" ]   # ignored
  # idempotent
  run "$LIB_DIR/archeflow-git.sh" worktree test-run
  [ "$status" -eq 0 ]
}

@test "git integrate: merges Maker commits, writes do-maker.diff/files, removes the worktree" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  wt=$("$LIB_DIR/archeflow-git.sh" worktree test-run 2>/dev/null)
  _maker_commit "$wt" feature.py "print(1)"
  _maker_commit "$wt" test_feature.py "assert True"
  run "$LIB_DIR/archeflow-git.sh" integrate test-run
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = "archeflow/test-run" ]
  [ -f feature.py ] && [ -f test_feature.py ]
  grep -q '^+++ b/feature.py' .archeflow/artifacts/test-run/do-maker.diff
  [ "$(sort .archeflow/artifacts/test-run/do-maker-files.txt | tr '\n' ' ')" = "feature.py test_feature.py " ]
  [ ! -d "$wt" ]
  ! git show-ref --verify --quiet refs/heads/archeflow/test-run-maker
}

@test "git integrate: refuses when the Maker left uncommitted changes" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  wt=$("$LIB_DIR/archeflow-git.sh" worktree test-run 2>/dev/null)
  _maker_commit "$wt" a.py "a"
  echo dirty >> "$wt/a.py"
  run "$LIB_DIR/archeflow-git.sh" integrate test-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted changes"* ]]
  [ -d "$wt" ]
}

@test "git integrate: fails clearly when the Maker made no commits" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  "$LIB_DIR/archeflow-git.sh" worktree test-run >/dev/null 2>&1
  run "$LIB_DIR/archeflow-git.sh" integrate test-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"no commits"* ]]
}

@test "git merge: refuses while Maker work is not integrated" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  wt=$("$LIB_DIR/archeflow-git.sh" worktree test-run 2>/dev/null)
  _maker_commit "$wt" a.py "a"
  run "$LIB_DIR/archeflow-git.sh" merge test-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"not integrated"* ]]
  [ "$(git branch --show-current)" = "archeflow/test-run" ]
}

@test "git merge: conflict aborts cleanly and returns to the run branch" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  echo run > README.md && git commit -qam "run edit"
  git checkout -q main && echo base > README.md && git commit -qam "base edit" && git checkout -q archeflow/test-run
  local base_head; base_head=$(git rev-parse main)
  run "$LIB_DIR/archeflow-git.sh" merge test-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"conflicts"* ]]
  [ "$(git branch --show-current)" = "archeflow/test-run" ]
  [ "$(git rev-parse main)" = "$base_head" ]
  [ ! -f .git/MERGE_HEAD ]
}

# --- cleanup / rollback never hang on a prompt ---

@test "git cleanup: after a squash merge deletes the branch without prompting" {
  mkdir -p .archeflow
  printf 'git:\n  merge_strategy: squash\n' > .archeflow/config.yaml
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  echo w > w.txt && git add w.txt && git commit -q -m w
  "$LIB_DIR/archeflow-git.sh" merge test-run 2>/dev/null
  run "$LIB_DIR/archeflow-git.sh" cleanup test-run </dev/null
  [ "$status" -eq 0 ]
  ! git show-ref --verify --quiet refs/heads/archeflow/test-run
  [ ! -d .archeflow/runs/test-run ]
}

@test "git cleanup: unmerged branch needs --yes in a non-interactive session" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  echo w > w.txt && git add w.txt && git commit -q -m w
  git checkout -q main
  run "$LIB_DIR/archeflow-git.sh" cleanup test-run </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"--yes"* ]]
  git show-ref --verify --quiet refs/heads/archeflow/test-run
  run "$LIB_DIR/archeflow-git.sh" cleanup test-run --yes </dev/null
  [ "$status" -eq 0 ]
  ! git show-ref --verify --quiet refs/heads/archeflow/test-run
}

@test "git rollback: needs --yes without a terminal, resets with it" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  echo p > p.txt && "$LIB_DIR/archeflow-git.sh" commit test-run plan "plan" p.txt 2>/dev/null
  echo d > d.txt && "$LIB_DIR/archeflow-git.sh" commit test-run do "do" d.txt 2>/dev/null
  run "$LIB_DIR/archeflow-git.sh" rollback test-run --to plan </dev/null
  [ "$status" -ne 0 ]
  [ -f d.txt ]
  run "$LIB_DIR/archeflow-git.sh" rollback test-run --to plan --yes </dev/null
  [ "$status" -eq 0 ]
  [ ! -f d.txt ]
  [ "$(git log -1 --format=%s)" = "archeflow(plan): plan" ]
}

# --- config hardening ---

@test "git init: refuses a dirty tree instead of silently stashing it" {
  echo changed >> README.md
  run "$LIB_DIR/archeflow-git.sh" init test-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Uncommitted changes"* ]]
  [ "$(git branch --show-current)" = "main" ]
  [ -z "$(git stash list)" ]
  grep -q changed README.md
}

@test "git: branch_prefix starting with + or - is rejected (no forced push, no option)" {
  mkdir -p .archeflow
  for p in '+archeflow/' '-archeflow/' 'a..b/'; do
    printf 'git:\n  branch_prefix: "%s"\n' "$p" > .archeflow/config.yaml
    run "$LIB_DIR/archeflow-git.sh" init test-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid git.branch_prefix"* ]]
  done
  ! git for-each-ref --format='%(refname)' | grep -q 'test-run'
}

@test "git: config keys are read from the git: block, not from other nested sections" {
  mkdir -p .archeflow
  cat > .archeflow/config.yaml <<'YAML'
variables:
  branch_prefix: "wrong/"
git:
  branch_prefix: "af/"   # comment
YAML
  run "$LIB_DIR/archeflow-git.sh" init test-run
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = "af/test-run" ]
}

@test "git: a base-branch file starting with '-' is rejected before it reaches git" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  echo "--output=/tmp/x" > .archeflow/runs/test-run/base-branch
  run "$LIB_DIR/archeflow-git.sh" merge test-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid base branch"* ]]
  [ "$(git branch --show-current)" = "archeflow/test-run" ]
}

@test "git: --help exits 0" {
  run "$LIB_DIR/archeflow-git.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"integrate"* ]]
}

@test "git integrate: untracked files in the worktree are named, not silently dropped" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  wt=$("$LIB_DIR/archeflow-git.sh" worktree test-run 2>/dev/null)
  _maker_commit "$wt" a.py "a"
  mkdir -p "$wt/__pycache__" && echo x > "$wt/__pycache__/a.pyc"
  run "$LIB_DIR/archeflow-git.sh" integrate test-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"__pycache__/a.pyc"* ]]
  rm -rf "$wt/__pycache__"
  run "$LIB_DIR/archeflow-git.sh" integrate test-run
  [ "$status" -eq 0 ]
}

@test "git merge: refuses a second merge of an already merged run (no silent no-op after a revert)" {
  "$LIB_DIR/archeflow-git.sh" init test-run 2>/dev/null
  echo w > w.txt && git add w.txt && git commit -q -m w
  "$LIB_DIR/archeflow-git.sh" merge test-run 2>/dev/null
  git revert --no-edit -m 1 HEAD >/dev/null
  git checkout -q archeflow/test-run
  run "$LIB_DIR/archeflow-git.sh" merge test-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"already"* ]]
  [ "$(git branch --show-current)" = "archeflow/test-run" ]
}
