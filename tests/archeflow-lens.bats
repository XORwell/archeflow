# Tests for archeflow-lens.sh — lens resolution and merging.

setup() {
  load test_helper
  _common_setup
}

teardown() {
  _common_teardown
}

@test "lens: built-in security lens validates and merges to JSON" {
  run "$LIB_DIR/archeflow-lens.sh" validate security
  [ "$status" -eq 0 ]
  run "$LIB_DIR/archeflow-lens.sh" merge security
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
}

@test "lens: project lens overrides built-in" {
  mkdir -p .archeflow/lenses
  cp "$LIB_DIR/../lenses/security.yaml" .archeflow/lenses/security.yaml
  run "$LIB_DIR/archeflow-lens.sh" resolve security
  [ "$status" -eq 0 ]
  [ "$output" = ".archeflow/lenses/security.yaml" ]
}

@test "lens: rejects path traversal in lens names" {
  run "$LIB_DIR/archeflow-lens.sh" show "../templates/bundles/quick-fix/team"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid lens name"* ]]
}


@test "lens: merge works without yq or PyYAML (built-in YAML fallback)" {
  mkdir -p "$BATS_TEST_TMPDIR/stub"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/stub/yq"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/stub/python3"
  chmod +x "$BATS_TEST_TMPDIR/stub/yq" "$BATS_TEST_TMPDIR/stub/python3"
  run env PATH="$BATS_TEST_TMPDIR/stub:$PATH" "$LIB_DIR/archeflow-lens.sh" merge security compliance-gdpr
  [ "$status" -eq 0 ]
  [ "$(jq -c '.lenses' <<<"$output")" = '["security","compliance-gdpr"]' ]
  [ "$(jq '.attention.guardian.weight' <<<"$output")" = "1.3" ]
  [ "$(jq -r '.evidence_rules | map(.category) | join(",")' <<<"$output")" = "auth-bypass,consent-missing,cve,data-leak,injection,pii-exposure,retention-violation,secrets-exposure" ]
  [ "$(jq '.shadow_overrides.guardian.paranoid_ratio_threshold' <<<"$output")" = "4" ]
}

@test "yaml: fallback converter handles the lens/pattern subset" {
  cat > "$BATS_TEST_TMPDIR/t.yaml" <<'YAML'
# comment
name: demo   # trailing comment
version: "1.0"
quoted: 'it''s # not a comment'
num: 3
float: 1.5
flag: true
empty_map: {}
nothing:
list:
  - a
  - "b c"
flow: [x, "y z", 2]
seq_of_maps:
  - category: one
    requires: [p, q]
  - category: two
nested:
  inner:
    deep: value
same_indent_list:
- first
- second
after: done
YAML
  run "$LIB_DIR/archeflow-yaml.sh" "$BATS_TEST_TMPDIR/t.yaml"
  [ "$status" -eq 0 ]
  expected='{"after":"done","empty_map":{},"flag":true,"float":1.5,"flow":["x","y z",2],"list":["a","b c"],"name":"demo","nested":{"inner":{"deep":"value"}},"nothing":null,"num":3,"quoted":"it'"'"'s # not a comment","same_indent_list":["first","second"],"seq_of_maps":[{"category":"one","requires":["p","q"]},{"category":"two"}],"version":"1.0"}'
  [ "$(jq -cS . <<<"$output")" = "$expected" ]
}

@test "yaml: fallback converter rejects unsupported block scalars" {
  printf 'text: |\n  multi\n  line\n' > "$BATS_TEST_TMPDIR/b.yaml"
  run "$LIB_DIR/archeflow-yaml.sh" "$BATS_TEST_TMPDIR/b.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported"* ]]
}

# --- context_inject paths must stay inside the project -----------------------

project_lens() {  # project_lens <yaml-list-for-always>
  mkdir -p .archeflow/lenses
  printf 'name: evil\ndescription: d\nversion: 1\ncontext_inject:\n  always:\n%s\n' "$1" > .archeflow/lenses/evil.yaml
}

@test "lens: merge rejects absolute context_inject paths" {
  project_lens '    - /etc/passwd'
  run "$LIB_DIR/archeflow-lens.sh" merge evil
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe context_inject path"* ]]
}

@test "lens: merge rejects home and parent-directory context_inject paths" {
  for p in '~/.ssh/id_ed25519' '../../.aws/credentials' 'docs/../../secret' '..'; do
    project_lens "    - \"$p\""
    run "$LIB_DIR/archeflow-lens.sh" merge evil
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsafe context_inject path"* ]]
  done
}

@test "lens: merge rejects a symlink that escapes the project" {
  mkdir -p docs
  ln -s "$HOME" docs/home-link
  project_lens '    - docs/home-link'
  run "$LIB_DIR/archeflow-lens.sh" merge evil
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside the project root"* ]]
}

@test "lens: merge accepts relative project paths, existing or not" {
  mkdir -p docs && echo v > docs/voice.md
  project_lens '    - docs/voice.md
    - .archeflow/checklists/missing.md'
  run "$LIB_DIR/archeflow-lens.sh" merge evil
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.context_inject.always == [".archeflow/checklists/missing.md", "docs/voice.md"]'
}
