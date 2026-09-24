# Tests for hooks/session-start — SessionStart context injection (Bash + jq).

setup() {
  load test_helper
  _common_setup
  HOOK_SRC="$(cd "$LIB_DIR/../hooks" && pwd)/session-start"
  REAL_ROOT="$(cd "$LIB_DIR/.." && pwd)"
  # Fake plugin root so each test controls ACTIVATION.md.
  PLUG="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$PLUG/hooks" "$PLUG/skills/using-archeflow"
  cp "$HOOK_SRC" "$PLUG/hooks/session-start"
  PLUG_REAL="$(cd "$PLUG" && pwd -P)"
  unset CLAUDE_PLUGIN_ROOT
}

teardown() {
  _common_teardown
}

_activation() {
  printf '%s' "$1" > "$PLUG/skills/using-archeflow/ACTIVATION.md"
}

@test "hook: hooks.json invokes the hook via bash, not node" {
  run jq -r '.hooks.SessionStart[0].hooks[0].command' "$REAL_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [[ "$output" == bash\ * ]]
  [[ "$output" != *node* ]]
}

@test "hook: real plugin emits SessionStart additionalContext" {
  run bash "$HOOK_SRC"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")" = "SessionStart" ]
  ctx="$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")"
  [[ "$ctx" == *"ArcheFlow"* ]]
}

@test "hook: strips YAML frontmatter and preserves body verbatim" {
  _activation $'---\nname: using-archeflow\ndescription: x\n---\n# Title\n"quoted" \\ tab\there\n'
  run bash "$PLUG/hooks/session-start"
  [ "$status" -eq 0 ]
  # jq -j + trailing sentinel so $(...) does not eat the final newline.
  actual="$(jq -j '.hookSpecificOutput.additionalContext + "|"' <<<"$output")"
  [ "$actual" = "ArcheFlow root: $PLUG_REAL"$'\n\n# Title\n"quoted" \\ tab\there\n|' ]
  [[ "$output" != *"description: x"* ]]
}

@test "hook: output is compact single-line JSON" {
  _activation $'line1\nline2\n'
  run bash "$PLUG/hooks/session-start"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"ArcheFlow root: '"$PLUG_REAL"'\n\nline1\nline2\n"}}' ]
}

@test "hook: missing ACTIVATION.md emits {} and exits 0" {
  rm -f "$PLUG/skills/using-archeflow/ACTIVATION.md"
  run bash "$PLUG/hooks/session-start"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "hook: frontmatter-only / whitespace-only file emits {}" {
  _activation $'---\nname: x\n---\n   \n\n'
  run bash "$PLUG/hooks/session-start"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "hook: missing jq degrades to {} instead of failing" {
  # PATH with bash builtins only (dirname via coreutils symlink), no jq.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for t in dirname; do ln -s "$(command -v "$t")" "$BATS_TEST_TMPDIR/bin/$t"; done
  _activation $'hello\n'
  run env PATH="$BATS_TEST_TMPDIR/bin" "$(command -v bash)" "$PLUG/hooks/session-start"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "hook: real plugin advertises its own root for <archeflow-root> paths" {
  run bash "$HOOK_SRC"
  [ "$status" -eq 0 ]
  root_line="$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output" | head -1)"
  [ "$root_line" = "ArcheFlow root: $REAL_ROOT" ] || [ "$root_line" = "ArcheFlow root: $(cd "$REAL_ROOT" && pwd -P)" ]
  [ -x "${root_line#ArcheFlow root: }/lib/archeflow-event.sh" ]
}

@test "hook: uses CLAUDE_PLUGIN_ROOT as the advertised root when it is an ArcheFlow dir" {
  mkdir -p "$PLUG/lib" && touch "$PLUG/lib/archeflow-event.sh"
  _activation $'x\n'
  run env CLAUDE_PLUGIN_ROOT="$PLUG" bash "$PLUG/hooks/session-start"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == "ArcheFlow root: $PLUG_REAL"* ]]
}

@test "hook: ignores CLAUDE_PLUGIN_ROOT / cwd (no traversal via env)" {
  _activation $'from-script-location\n'
  mkdir -p "$BATS_TEST_TMPDIR/evil/skills/using-archeflow"
  printf 'evil\n' > "$BATS_TEST_TMPDIR/evil/skills/using-archeflow/ACTIVATION.md"
  cd "$BATS_TEST_TMPDIR/evil"
  run env CLAUDE_PLUGIN_ROOT="$BATS_TEST_TMPDIR/evil" bash "$PLUG/hooks/session-start"
  [ "$status" -eq 0 ]
  [[ "$output" == *"from-script-location"* ]]
  # evil dir has no lib/archeflow-event.sh, so it is neither read nor advertised
  [[ "$output" != *"evil"* ]]
}
