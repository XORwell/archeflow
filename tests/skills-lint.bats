# Static checks on skills/: frontmatter and script references.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "skills: every SKILL.md has frontmatter with name (matching dir) and description" {
  for f in "$ROOT"/skills/*/SKILL.md; do
    head -1 "$f" | grep -qx -- '---' || { echo "no frontmatter: $f"; return 1; }
    fm="$(awk 'NR>1 && $0=="---"{exit} NR>1{print}' "$f")"
    name="$(grep -m1 '^name:' <<<"$fm" | sed 's/^name:[[:space:]]*//')"
    [ "$name" = "$(basename "$(dirname "$f")")" ] || { echo "name mismatch: $f ($name)"; return 1; }
    grep -q '^description:' <<<"$fm" || { echo "no description: $f"; return 1; }
  done
}

@test "skills: script paths use <archeflow-root>/lib, never CWD-relative ./lib" {
  run grep -rnE '(^|[^A-Za-z0-9_>/-])(\./)?lib/archeflow-' "$ROOT/skills"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "skills: every referenced <archeflow-root>/lib script exists" {
  while IFS= read -r ref; do
    [ -f "$ROOT/lib/${ref##*/}" ] || { echo "missing: $ref"; return 1; }
  done < <(grep -rhoE '<archeflow-root>/lib/archeflow-[a-z-]+\.sh' "$ROOT/skills" | sort -u)
}

# Subcommands: `archeflow-<x>.sh <word>` in a skill must be a subcommand the script
# dispatches on (a "<word>)" or "<word>|" case label). Catches calls like "score.sh list".
@test "skills: every <archeflow-root>/lib script subcommand exists in that script" {
  local bad=0
  while IFS= read -r ref; do
    script="${ref%% *}"; script="${script##*/}"
    word="${ref#* }"
    [ "$script" = "archeflow-init.sh" ] && continue   # first argument is a bundle name
    grep -qE "(^|[[:space:](|])${word}([|)])" "$ROOT/lib/$script" \
      || { echo "unknown subcommand: $script $word"; bad=1; }
  done < <(grep -rhoE '<archeflow-root>/lib/archeflow-[a-z-]+\.sh [a-z][a-z-]+' "$ROOT/skills" "$ROOT/.cursor" | sort -u)
  [ "$bad" -eq 0 ]
}

# Command names: docs/COMMANDS.md is the list of user-facing commands. Every
# /archeflow:<name> (and {{CMD:<name>}} placeholder) in user-facing text must be a
# shipped, user-invocable skill, and the old workspace-only /af-* names must be gone.
_user_commands() {
  for f in "$ROOT"/skills/*/SKILL.md; do
    fm="$(awk 'NR>1 && $0=="---"{exit} NR>1{print}' "$f")"
    grep -q '^user-invocable:[[:space:]]*false' <<<"$fm" && continue
    basename "$(dirname "$f")"
  done
}

_user_facing_files() {
  local f
  for f in "$ROOT"/README.md "$ROOT"/CLAUDE.md "$ROOT"/CONTRIBUTING.md "$ROOT"/docs/*.md; do
    [ -f "$f" ] && echo "$f"
  done
  find "$ROOT/skills" "$ROOT/agents" "$ROOT/.cursor" "$ROOT/hooks" "$ROOT/examples" -type f 2>/dev/null
}

@test "commands: every /archeflow:<name> in docs and skills is a shipped user-invocable skill" {
  cmds="$(_user_commands)"
  local bad=0
  while IFS= read -r hit; do
    name="${hit##*/archeflow:}"; name="${name#\{\{CMD:}"; name="${name%\}\}}"
    grep -qx -- "$name" <<<"$cmds" || { echo "not a command: $hit"; bad=1; }
  done < <(_user_facing_files | xargs grep -hoE '/archeflow:[a-z][a-z-]*|\{\{CMD:[a-z-]+\}\}' | sort -u)
  [ "$bad" -eq 0 ]
}

@test "commands: no workspace-only /af-<command> names remain" {
  local files=()
  mapfile -t files < <(_user_facing_files)
  run grep -nE '(^|[^A-Za-z0-9_-])/af-(run|sprint|review|init|memory|status|report|dag|score|replay|scan)([^A-Za-z0-9-]|$)' "${files[@]}"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "commands: docs/COMMANDS.md lists exactly the user-invocable skills" {
  [ -f "$ROOT/docs/COMMANDS.md" ]
  listed="$(grep -oE '^\| `/archeflow:[a-z-]+' "$ROOT/docs/COMMANDS.md" | sed 's/.*archeflow://' | sort -u)"
  [ "$listed" = "$(_user_commands | sort -u)" ] || { echo "listed: $listed"; echo "skills: $(_user_commands | sort -u)"; return 1; }
}

@test "skills: no skill asks for a permission bypass or an owner-only agent type" {
  run grep -rnE 'bypassPermissions|dangerously-skip-permissions|subagent_type: *"code-reviewer"' "$ROOT/skills" "$ROOT/agents" "$ROOT/.cursor"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "skills: shell templates never wrap placeholders in single quotes" {
  # '<json>' / '<summary>' style templates break as soon as the pasted text contains a quote.
  run grep -rnE "'<[a-z_ -]+>'" "$ROOT/skills" "$ROOT/.cursor"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "skills: 'Wiggum Break' is spelled consistently" {
  run grep -rniE 'wiggum[ -]?brake' "$ROOT/skills" "$ROOT/agents" "$ROOT/lib" "$ROOT/README.md" "$ROOT/CLAUDE.md"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}
