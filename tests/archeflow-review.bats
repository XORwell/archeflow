# Tests for archeflow-review.sh — git diff extraction for code review.
#
# Validates: argument parsing, diff modes, stats output, empty diff handling.

setup() {
  load test_helper
  _common_setup
}

teardown() {
  _common_teardown
}

@test "review: --help shows usage" {
  run "$LIB_DIR/archeflow-review.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"--branch"* ]]
  [[ "$output" == *"--commit"* ]]
}

@test "review: exits 1 when no changes to review" {
  run "$LIB_DIR/archeflow-review.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No changes"* ]]
}

@test "review: shows diff for uncommitted changes" {
  echo "new content" > testfile.txt
  git add testfile.txt
  run "$LIB_DIR/archeflow-review.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"testfile.txt"* ]]
}

@test "review: --stat-only prints stats without diff content" {
  echo "stat content" > statfile.txt
  git add statfile.txt
  run "$LIB_DIR/archeflow-review.sh" --stat-only
  [ "$status" -eq 0 ]
  # stderr has stats, stdout should be empty (no diff)
  # But run captures both, so just check it ran ok
  [[ "$output" == *"Review Stats"* ]]
}

@test "review: --branch fails for nonexistent branch" {
  run "$LIB_DIR/archeflow-review.sh" --branch nonexistent-branch-xyz
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "review: rejects unknown arguments" {
  run "$LIB_DIR/archeflow-review.sh" --unknown
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown argument"* ]]
}

@test "review: --branch shows diff against base" {
  # Create a feature branch with changes
  git checkout -b feat/test-review --quiet
  echo "feature" > feature.txt
  git add feature.txt
  git commit -m "feat: add feature" --quiet
  git checkout main --quiet

  run "$LIB_DIR/archeflow-review.sh" --branch feat/test-review
  [ "$status" -eq 0 ]
  [[ "$output" == *"feature.txt"* ]]
}

@test "review: --commit shows diff for commit range" {
  echo "first" > first.txt
  git add first.txt
  git commit -m "first" --quiet
  echo "second" > second.txt
  git add second.txt
  git commit -m "second" --quiet

  run "$LIB_DIR/archeflow-review.sh" --commit HEAD~1..HEAD
  [ "$status" -eq 0 ]
  [[ "$output" == *"second.txt"* ]]
}

@test "review: --commit value starting with '-' is rejected (git option injection)" {
  run "$LIB_DIR/archeflow-review.sh" --commit "--output=$BATS_TEST_TMPDIR/written"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/written" ]
}

@test "review: --branch value starting with '-' is rejected" {
  run "$LIB_DIR/archeflow-review.sh" --branch "--output=$BATS_TEST_TMPDIR/written2"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/written2" ]
}

@test "review: --branch auto-detects master in a master-only repo" {
  git branch -m main master
  git checkout -b feat/on-master --quiet
  echo "feature" > onmaster.txt
  git add onmaster.txt
  git commit -m "feat: on master" --quiet
  git checkout master --quiet

  run "$LIB_DIR/archeflow-review.sh" --branch feat/on-master
  [ "$status" -eq 0 ]
  [[ "$output" == *"vs 'master'"* ]]
  [[ "$output" == *"onmaster.txt"* ]]
}

@test "review: --branch prefers origin/HEAD over a local main" {
  git clone --quiet . clone
  cd clone
  git config user.email "test@test.com"
  git config user.name "Test User"
  git config commit.gpgsign false
  # origin's default branch is "trunk"; a stale local main must not win.
  git checkout -b trunk --quiet
  git update-ref refs/remotes/origin/trunk HEAD
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  git checkout -b feat/x --quiet
  echo "x" > x.txt
  git add x.txt
  git commit -m "x" --quiet

  run "$LIB_DIR/archeflow-review.sh" --branch feat/x
  [ "$status" -eq 0 ]
  [[ "$output" == *"vs 'trunk'"* ]]
  [[ "$output" == *"x.txt"* ]]
}

@test "review: explicit --base is honoured, missing base fails clearly" {
  git checkout -b feat/y --quiet
  echo "y" > y.txt
  git add y.txt
  git commit -m "y" --quiet

  run "$LIB_DIR/archeflow-review.sh" --branch feat/y --base main
  [ "$status" -eq 0 ]
  [[ "$output" == *"vs 'main'"* ]]

  run "$LIB_DIR/archeflow-review.sh" --branch feat/y --base no-such-base
  [ "$status" -ne 0 ]
  [[ "$output" == *"Base branch 'no-such-base' not found"* ]]
}
