# End-to-end test of the run skill's command sequence.
#
# The commands are NOT copied into this file: they are extracted from
# skills/run/SKILL.md (every `<archeflow-root>/lib/...` code span, plus the index
# append), placeholders are substituted, and the result is executed in a temp repo.
# The agents' work (proposal, Maker commits, reviews, findings) is simulated
# between the steps. So if the skill prescribes a command, argument or file layout
# the scripts do not support, this test fails.
#
# E2E_KEYS lists every command the skill prescribes; the lint test at the bottom
# fails if SKILL.md gains, loses or duplicates a command without this file
# being updated, and the flow tests assert that every key was executed.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILL="$ROOT/skills/run/SKILL.md"
  WORK="$(mktemp -d)"
  cd "$WORK"
  git init --quiet
  git config user.email "e2e@test"
  git config user.name "e2e"
  git config commit.gpgsign false
  git config tag.gpgsign false
  EXECUTED="$(mktemp)"
  : > "$EXECUTED"
}

teardown() {
  cd /
  rm -rf "$WORK" "$EXECUTED"
}

# Every command in skills/run/SKILL.md, by key (script + subcommand).
E2E_KEYS=(
  "archeflow-git.sh init"
  "archeflow-memory.sh inject"
  "archeflow-event.sh"
  "archeflow-git.sh worktree"
  "archeflow-git.sh integrate"
  "archeflow-evidence.sh validate"
  "archeflow-shadow.sh detect"
  "archeflow-shadow.sh check-system"
  "archeflow-convergence.sh score"
  "archeflow-convergence.sh oscillation"
  "archeflow-convergence.sh wiggum-check"
  "archeflow-git.sh merge"
  "archeflow-rollback.sh"
  "archeflow-git.sh cleanup"
  "archeflow-memory.sh regression-check"
  "archeflow-memory.sh extract"
  "archeflow-memory.sh decay"
  "archeflow-score.sh extract"
  "index-append"
  "archeflow-report.sh"
)

# All commands from SKILL.md, in document order, one per line.
_skill_commands() {
  grep -oE '`<archeflow-root>/lib/archeflow-[a-z-]+\.sh[^`]*`|`jq -cn [^`]*index\.jsonl`' "$SKILL" | sed 's/^`//; s/`$//'
}

# Key of a command: script name + first argument if it is a plain subcommand word.
_key() {
  local cmd="$1" script word
  if [[ "$cmd" == jq\ * ]]; then echo "index-append"; return; fi
  script="${cmd%% *}"; script="${script##*/}"
  word="$(awk '{print $2}' <<<"$cmd")"
  if [[ "$word" =~ ^[a-z][a-z-]*$ ]]; then echo "$script $word"; else echo "$script"; fi
}

# Look up the command for <key> in SKILL.md, substitute placeholders, run it from
# the repo root. Extra substitutions: VAR=value pairs for <var> placeholders.
# Sets $status/$output via bats `run`.
step() {
  local key="$1"; shift
  local cmd="" c
  while IFS= read -r c; do
    [[ "$(_key "$c")" == "$key" ]] && { cmd="$c"; break; }
  done < <(_skill_commands)
  [[ -n "$cmd" ]] || { echo "SKILL.md has no command for key '$key'" >&2; return 1; }
  printf '%s\n' "$key" >> "$EXECUTED"

  local n="${N:-1}"
  cmd="${cmd//<archeflow-root>/$ROOT}"
  cmd="${cmd//<run_id>/$RUN_ID}"
  cmd="${cmd//<N-1>/$((n - 1))}"
  cmd="${cmd//<N-2>/$((n - 2))}"
  cmd="${cmd//<N>/$n}"
  cmd="${cmd//<domain>/code}"
  local kv
  for kv in "$@"; do
    cmd="${cmd//<${kv%%=*}>/${kv#*=}}"
  done
  local ph_re='<[a-zA-Z_-]+>'
  [[ ! "$cmd" =~ $ph_re ]] || { echo "unsubstituted placeholder in: $cmd" >&2; return 1; }
  run bash -c "$cmd"
}

# Event helper: data object written to event.json (as the skill says), then the event command.
emit() {  # <type> <phase> <agent> <json>
  printf '%s\n' "$4" > ".archeflow/artifacts/$RUN_ID/event.json"
  step "archeflow-event.sh" "type=$1" "phase=$2" "agent=$3"
  [ "$status" -eq 0 ]
}

# Simulated agents ---------------------------------------------------------------

_repo() {  # <base-branch>: a small project with a test script
  git symbolic-ref HEAD "refs/heads/$1"
  mkdir -p src tests
  echo 'def add(a, b): return a + b' > src/calc.py
  printf '#!/bin/sh\ngrep -q "def add" src/calc.py\n' > tests/run.sh
  chmod +x tests/run.sh
  git add -A && git commit -q -m "initial"
  mkdir -p .archeflow
  cat > .archeflow/config.yaml <<'YAML'
git:
  auto_merge: true
costs:
  budget_usd: 10
test_command: "sh tests/run.sh"
YAML
}

_maker() {  # <worktree> <file> <content>: the Maker commits in its worktree
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -- "$2"
  git -C "$1" commit -q -m "feat: $2"
}

_review() {  # <role> <verdict> [finding line]
  printf '## Review\n%s\n\n%s\n\nSTATUS: DONE\n' "${3:-No findings.}" "$2" > ".archeflow/artifacts/$RUN_ID/check-$1.md"
}

_findings() {  # <N> <json array>
  printf '%s\n' "$2" > ".archeflow/artifacts/$RUN_ID/findings-cycle-$1.json"
}

# One full cycle of Do + Check + Act commands.
_cycle() {  # <N> <maker-file> <maker-content> <guardian verdict> <finding line> <findings json>
  N="$1"
  step "archeflow-git.sh worktree"; [ "$status" -eq 0 ]
  local wt="${lines[${#lines[@]}-1]}"
  [ -d "$wt" ]
  _maker "$wt" "$2" "$3"
  _maker "$wt" "tests/test_$(basename "$2" .py).sh" "echo ok"
  echo "Implemented $2" > ".archeflow/artifacts/$RUN_ID/do-maker.md"
  step "archeflow-git.sh integrate"; [ "$status" -eq 0 ]
  [ -s ".archeflow/artifacts/$RUN_ID/do-maker.diff" ]
  grep -qx "$2" ".archeflow/artifacts/$RUN_ID/do-maker-files.txt"
  [ ! -d "$wt" ]
  [ "$(git branch --show-current)" = "archeflow/$RUN_ID" ]

  _review guardian "$4" "$5"
  step "archeflow-evidence.sh validate" "role=guardian"   # 0 = downgrades listed, 1 = none
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" == *"Findings:"* ]]
  step "archeflow-shadow.sh detect" "role=guardian" "artifact=check-guardian"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

  _findings "$N" "$6"
  step "archeflow-shadow.sh check-system"; [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  if (( N >= 2 )); then
    step "archeflow-convergence.sh score"; [ "$status" -eq 0 ]
    jq -e '.convergence_score | numbers' ".archeflow/artifacts/$RUN_ID/convergence-cycle-$N.json"
  fi
  if (( N >= 3 )); then
    step "archeflow-convergence.sh oscillation"; [ "$status" -eq 1 ]
    jq -e '.oscillation_detected == false' <<<"$output"
  fi
  step "archeflow-convergence.sh wiggum-check"
  [ "$status" -eq 1 ]
  jq -e '.wiggum_break == false' <<<"$output"
  emit cycle.boundary act "" "{\"cycle\":$N,\"max_cycles\":3}"
}

# The whole run, in the order of SKILL.md.
_run_flow() {  # <base-branch>
  local base="$1"
  _repo "$base"
  RUN_ID="2026-09-24-add-subtract"

  # 0. Start
  step "archeflow-git.sh init"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git branch --show-current)" = "archeflow/$RUN_ID" ]
  mkdir -p ".archeflow/artifacts/$RUN_ID"
  printf "Add subtract() to calc.py; it's used by the 'report' module.\n" > ".archeflow/artifacts/$RUN_ID/task.md"
  step "archeflow-memory.sh inject"; [ "$status" -eq 0 ]
  emit run.start plan "" "$(jq -cn --rawfile task ".archeflow/artifacts/$RUN_ID/task.md" '{task: $task, workflow: "thorough", max_cycles: 3}')"

  # 1. Plan (simulated Creator)
  printf '## Proposal\nChange src/calc.py and tests/test_calc.sh.\n### Confidence\n| task understanding | 0.9 |\nSTATUS: DONE\n' \
    > ".archeflow/artifacts/$RUN_ID/plan-creator.md"

  # 2-4. Three cycles: a WARNING, then a new WARNING, then approval.
  _cycle 1 src/calc.py $'def add(a, b): return a + b\ndef subtract(a, b): return a - b' REJECTED \
    "| src/calc.py:2 | WARNING | testing | no test for negative numbers, ran tests/run.sh: exit 0 | add test |" \
    '[{"id":"src/calc.py:testing","file":"src/calc.py","category":"testing","severity":"WARNING"}]'
  _cycle 2 src/negative.py 'NEG = True' REJECTED \
    "| src/negative.py:1 | WARNING | quality | unused constant NEG at src/negative.py:1 | remove |" \
    '[{"id":"src/negative.py:quality","file":"src/negative.py","category":"quality","severity":"WARNING"}]'
  _cycle 3 src/cleanup.py 'X = 1' APPROVED "" '[]'

  # Merge (config: git.auto_merge true = confirmation given; test_command set)
  step "archeflow-git.sh merge"; [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = "$base" ]
  [ "$(git log -1 --format=%s)" = "feat: archeflow run $RUN_ID complete" ]
  step "archeflow-rollback.sh"; [ "$status" -eq 0 ]
  step "archeflow-git.sh cleanup"; [ "$status" -eq 0 ]
  ! git show-ref --verify --quiet "refs/heads/archeflow/$RUN_ID"
  ! git show-ref --verify --quiet "refs/heads/archeflow/$RUN_ID-maker"
  [ "$(git worktree list | wc -l | tr -d ' ')" -eq 1 ]

  # 5. Completion
  emit run.complete act "" '{"status":"merged","cycles":3,"agents_total":9,"fixes_total":2}'
  step "archeflow-memory.sh regression-check"; [ "$status" -eq 0 ]
  step "archeflow-memory.sh extract"; [ "$status" -eq 0 ]
  step "archeflow-memory.sh decay"; [ "$status" -eq 0 ]
  step "archeflow-score.sh extract"; [ "$status" -eq 0 ]
  step "index-append" "status=merged"; [ "$status" -eq 0 ]
  step "archeflow-report.sh"; [ "$status" -eq 0 ]
  [ -n "$output" ]

  # Outcome on the base branch
  grep -q "def subtract" src/calc.py
  [ -f src/negative.py ] && [ -f src/cleanup.py ]
  [ "$(git cat-file -p HEAD | grep -c '^parent')" -eq 2 ]
  [ -z "$(git ls-files .archeflow)" ]                  # run state never lands in the base branch
  [ -z "$(git status --porcelain --untracked-files=no)" ]
  jq -e --arg id "$RUN_ID" 'select(.run_id == $id and .status == "merged") | .task | test("subtract")' .archeflow/events/index.jsonl
  jq -se 'map(.type) | index("run.start") != null and index("run.complete") != null' ".archeflow/events/$RUN_ID.jsonl"

  # Every command the skill prescribes was executed.
  local k
  for k in "${E2E_KEYS[@]}"; do
    grep -qxF "$k" "$EXECUTED" || { echo "not executed: $k"; return 1; }
  done
}

@test "e2e run flow (skill commands verbatim): base branch main" {
  _run_flow main
}

@test "e2e run flow (skill commands verbatim): base branch master" {
  _run_flow master
}

@test "e2e: failing post-merge tests revert the merge and trigger a hard Wiggum Break" {
  _repo main
  RUN_ID="2026-09-24-break-tests"
  step "archeflow-git.sh init"; [ "$status" -eq 0 ]
  mkdir -p ".archeflow/artifacts/$RUN_ID"
  N=1
  step "archeflow-git.sh worktree"; [ "$status" -eq 0 ]
  wt="${lines[${#lines[@]}-1]}"
  _maker "$wt" src/calc.py 'def broken(): pass'          # removes add(): tests/run.sh fails
  step "archeflow-git.sh integrate"; [ "$status" -eq 0 ]
  step "archeflow-git.sh merge"; [ "$status" -eq 0 ]
  step "archeflow-rollback.sh"
  [ "$status" -eq 1 ]
  grep -q "def add" src/calc.py                          # merge reverted on main
  step "archeflow-convergence.sh wiggum-check"
  [ "$status" -eq 0 ]
  jq -e '.wiggum_break == true and .type == "hard"' <<<"$output"
  git show-ref --verify --quiet "refs/heads/archeflow/$RUN_ID"   # branch kept
}

@test "e2e: the same failure mode detected 3 times in a cycle triggers a hard Wiggum Break" {
  _repo main
  RUN_ID="2026-09-24-paranoid"
  mkdir -p ".archeflow/artifacts/$RUN_ID"
  N=1
  printf -- '- CRITICAL: token logged at a.py:1\n- CRITICAL: SQL concatenation at b.py:2\n- CRITICAL: no CSRF check at c.py:3\nREJECTED\n' \
    > ".archeflow/artifacts/$RUN_ID/check-guardian.md"
  for _ in 1 2 3; do
    step "archeflow-shadow.sh detect" "role=guardian" "artifact=check-guardian"
    [ "$status" -eq 0 ]
  done
  step "archeflow-convergence.sh wiggum-check"
  [ "$status" -eq 0 ]
  jq -e '.wiggum_break == true and .type == "hard"' <<<"$output"
}

@test "e2e: 3 identical shadow.detected events via archeflow-event.sh give wiggum_break true" {
  _repo main
  RUN_ID="2026-09-24-events"
  mkdir -p ".archeflow/artifacts/$RUN_ID"
  for _ in 1 2 3; do
    emit shadow.detected check sage '{"archetype":"sage","shadow":"bureaucrat","trigger":"t"}'
  done
  step "archeflow-convergence.sh wiggum-check"
  [ "$status" -eq 0 ]
  jq -e '.wiggum_break == true' <<<"$output"
}

# --- lint: SKILL.md and this file must not diverge --------------------------------

@test "lint: every command in skills/run/SKILL.md is covered by this e2e test (and nothing else)" {
  local keys c
  keys="$(while IFS= read -r c; do _key "$c"; done < <(_skill_commands))"
  # each command appears once (a second, different spelling would go untested)
  local dups
  dups="$(sort <<<"$keys" | uniq -d)"
  [ -z "$dups" ] || { echo "duplicate commands in SKILL.md: $dups"; return 1; }
  [ "$(sort <<<"$keys")" = "$(printf '%s\n' "${E2E_KEYS[@]}" | sort)" ] || {
    echo "SKILL.md: $(sort <<<"$keys" | tr '\n' ',')"
    echo "E2E_KEYS: $(printf '%s\n' "${E2E_KEYS[@]}" | sort | tr '\n' ',')"
    return 1
  }
}

@test "lint: SKILL.md commands only use placeholders this test substitutes" {
  local c ph
  while IFS= read -r c; do
    while IFS= read -r ph; do
      case "$ph" in
        '<archeflow-root>'|'<run_id>'|'<N>'|'<N-1>'|'<N-2>'|'<domain>'|'<type>'|'<phase>'|'<agent>'|'<role>'|'<artifact>'|'<status>') ;;
        *) echo "unknown placeholder $ph in: $c"; return 1 ;;
      esac
    done < <(grep -oE '<[a-zA-Z_-]+(-[0-9])?>' <<<"$c")
  done < <(_skill_commands)
}
