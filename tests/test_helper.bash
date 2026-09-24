# test_helper.bash — Shared setup/teardown for ArcheFlow bats tests.
#
# Usage in .bats files:
#   setup()    { load test_helper; _common_setup; }
#   teardown() { _common_teardown; }
#
# Provides:
#   - BATS_TEST_TMPDIR: unique temp directory per test
#   - Mock .archeflow/ structure via a git repo
#   - LIB_DIR: path to the lib/ scripts under test

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"

_common_setup() {
  # Create a unique temp directory for this test
  BATS_TEST_TMPDIR="$(mktemp -d)"
  export BATS_TEST_TMPDIR

  # Work inside the temp dir so scripts create .archeflow/ there
  cd "$BATS_TEST_TMPDIR"

  # Initialize a minimal git repo (many scripts need it)
  git init --quiet
  # Pin the initial branch: CI runners default to "master" (init.defaultBranch unset).
  git symbolic-ref HEAD refs/heads/main
  git config user.email "test@test.com"
  git config user.name "Test User"
  # Disable commit signing in tests (global config may have it enabled)
  git config commit.gpgsign false
  git config tag.gpgsign false

  # Create an initial commit so HEAD exists
  echo "init" > README.md
  git add README.md
  git commit -m "init" --quiet
}

_common_teardown() {
  # Return to a safe directory before cleanup
  cd /tmp
  rm -rf "$BATS_TEST_TMPDIR"
}
