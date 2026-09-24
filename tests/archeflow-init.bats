# Tests for archeflow-init.sh — project initialization from templates.
#
# Validates: usage output, --list, --from (clone), and argument parsing.

setup() {
  load test_helper
  _common_setup
}

teardown() {
  _common_teardown
}

@test "init: shows usage when called with no args" {
  run "$LIB_DIR/archeflow-init.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"bundle-name"* ]]
}

@test "init: --list shows template listing without errors" {
  run "$LIB_DIR/archeflow-init.sh" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"Templates"* ]]
  [[ "$output" == *"Bundles"* ]]
}

@test "init: --from fails when source has no .archeflow dir" {
  local source_dir
  source_dir=$(mktemp -d)
  run "$LIB_DIR/archeflow-init.sh" --from "$source_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No .archeflow/"* ]]
  rm -rf "$source_dir"
}

@test "init: --from clones setup from another project" {
  # Create a source project with .archeflow structure
  local source_dir
  source_dir=$(mktemp -d)
  mkdir -p "$source_dir/.archeflow/teams" "$source_dir/.archeflow/workflows"
  echo "name: test-team" > "$source_dir/.archeflow/teams/test.yaml"
  echo "name: test-workflow" > "$source_dir/.archeflow/workflows/test.yaml"
  echo "bundle: test" > "$source_dir/.archeflow/config.yaml"

  run "$LIB_DIR/archeflow-init.sh" --from "$source_dir"
  [ "$status" -eq 0 ]
  [ -f ".archeflow/teams/test.yaml" ]
  [ -f ".archeflow/workflows/test.yaml" ]
  [ -f ".archeflow/config.yaml" ]
  rm -rf "$source_dir"
}

@test "init: --from skips events and artifacts directories" {
  local source_dir
  source_dir=$(mktemp -d)
  mkdir -p "$source_dir/.archeflow/events" "$source_dir/.archeflow/artifacts"
  mkdir -p "$source_dir/.archeflow/teams"
  echo "name: test" > "$source_dir/.archeflow/teams/t.yaml"
  echo '{"test":true}' > "$source_dir/.archeflow/events/run.jsonl"
  echo "artifact" > "$source_dir/.archeflow/artifacts/test.txt"

  run "$LIB_DIR/archeflow-init.sh" --from "$source_dir"
  [ "$status" -eq 0 ]
  [ ! -f ".archeflow/events/run.jsonl" ]
  [ ! -f ".archeflow/artifacts/test.txt" ]
  [[ "$output" == *"skipped events"* ]]
  rm -rf "$source_dir"
}

@test "init: rejects unknown options" {
  run "$LIB_DIR/archeflow-init.sh" --nonexistent
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "init: --save fails with no .archeflow directory" {
  run "$LIB_DIR/archeflow-init.sh" --save test-save
  [ "$status" -ne 0 ]
  [[ "$output" == *"No .archeflow/"* ]]
}

@test "init: rejects bundle names with path traversal" {
  run "$LIB_DIR/archeflow-init.sh" "../../etc"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid bundle name"* ]]
}

@test "init: --save rejects traversal names before touching the filesystem" {
  mkdir -p .archeflow/teams
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.archeflow/templates/bundles" "$BATS_TEST_TMPDIR/victim"
  touch "$BATS_TEST_TMPDIR/victim/keep"
  run "$LIB_DIR/archeflow-init.sh" --save "../../../victim"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid bundle name"* ]]
  [ -f "$BATS_TEST_TMPDIR/victim/keep" ]
}

@test "init: --share rejects traversal names" {
  run "$LIB_DIR/archeflow-init.sh" --share "../x" "$BATS_TEST_TMPDIR/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid bundle name"* ]]
}

@test "init: finds bundles shipped with the plugin" {
  export HOME="$BATS_TEST_TMPDIR/home"
  run "$LIB_DIR/archeflow-init.sh" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"quick-fix"*"built-in"* ]]
  run "$LIB_DIR/archeflow-init.sh" quick-fix
  [ "$status" -eq 0 ]
  [ -f .archeflow/config.yaml ]
  # Nested includes.* must resolve without yq (awk fallback).
  [ -f .archeflow/teams/team.yaml ]
  [ -f .archeflow/workflows/workflow.yaml ]
  [ -f .archeflow/domains/domain.yaml ]
  # Variables with trailing "# comment: with colons" parse to clean keys.
  grep -qx '  max_cycles: 1' .archeflow/config.yaml
  grep -q '^  lint_command:' .archeflow/config.yaml
  ! grep -q 'Override' .archeflow/config.yaml
}

@test "init: --set override wins over manifest default" {
  export HOME="$BATS_TEST_TMPDIR/home"
  run "$LIB_DIR/archeflow-init.sh" quick-fix --set max_cycles=3
  [ "$status" -eq 0 ]
  grep -qx '  max_cycles: 3' .archeflow/config.yaml
}

@test "init: ignores manifest includes that escape the bundle dir" {
  export HOME="$BATS_TEST_TMPDIR/home"
  local b="$HOME/.archeflow/templates/bundles/evil"
  mkdir -p "$b"
  printf 'secret\n' > "$BATS_TEST_TMPDIR/secret.yaml"
  cat > "$b/manifest.yaml" <<'YAML'
name: evil
description: "x"
includes:
  team: ../../../../../secret.yaml
requires: []
variables: {}
YAML
  run "$LIB_DIR/archeflow-init.sh" evil
  [ "$status" -eq 0 ]
  [[ "$output" == *"unsafe includes.team"* ]]
  [ -z "$(ls -A .archeflow/teams/)" ]
}

@test "version: prints the latest CHANGELOG version without grep -P" {
  run "$LIB_DIR/archeflow-version.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  ! grep -qE '^[^#]*grep[^#]* -P' "$LIB_DIR/archeflow-version.sh"
}

@test "init: writes .archeflow/.gitignore that keeps secrets out of git" {
  run "$LIB_DIR/archeflow-init.sh" quick-fix
  [ "$status" -eq 0 ]
  grep -qxF 'langfuse.env' .archeflow/.gitignore
  grep -qxF '*.errors.log' .archeflow/.gitignore
  # idempotent: a second init does not duplicate rules
  rm -rf .archeflow/teams .archeflow/workflows .archeflow/domains
  "$LIB_DIR/archeflow-init.sh" quick-fix >/dev/null 2>&1
  [ "$(grep -cxF 'langfuse.env' .archeflow/.gitignore)" -eq 1 ]
  touch .archeflow/langfuse.env
  [ -z "$(git status --porcelain --untracked-files=all -- .archeflow/langfuse.env)" ]
}

@test "init: warns when a project-local bundle is used" {
  mkdir -p .archeflow/templates/bundles/quick-fix
  cp -r "$LIB_DIR/../templates/bundles/quick-fix/." .archeflow/templates/bundles/quick-fix/
  run "$LIB_DIR/archeflow-init.sh" quick-fix
  [ "$status" -eq 0 ]
  [[ "$output" == *"project-local bundle"* ]]
}

@test "init: carries the bundle's costs.budget_usd into .archeflow/config.yaml" {
  export HOME="$BATS_TEST_TMPDIR/home"
  run "$LIB_DIR/archeflow-init.sh" backend-feature
  [ "$status" -eq 0 ]
  grep -qx 'costs:' .archeflow/config.yaml
  grep -qx '  budget_usd: 5' .archeflow/config.yaml
  # and wiggum-check reads it: $4.80 of $5 spent is a soft break
  "$LIB_DIR/archeflow-event.sh" r-budget agent.complete do maker '{"estimated_cost_usd":4.80}' >/dev/null
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check r-budget
  [ "$status" -eq 0 ]
  [[ "$output" == *"Budget >95% spent"* ]]
}
