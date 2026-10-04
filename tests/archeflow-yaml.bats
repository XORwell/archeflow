# Tests for lib/archeflow-yaml.sh and the af_yaml_* / af_config_* helpers in
# archeflow-common.sh: the one YAML parser every lib script reads through.

setup() {
  load test_helper
  _common_setup
  ROOT="$(cd "$LIB_DIR/.." && pwd)"
  # shellcheck source=lib/archeflow-common.sh
  source "$LIB_DIR/archeflow-common.sh"
}

teardown() {
  _common_teardown
}

# Characterization: every key the lib scripts read from the shipped config,
# bundles, examples and lenses, with the value the pre-consolidation readers
# (init yaml_value/yaml_list, git and a2a yaml_get, the convergence budget grep,
# af_config_test_command, af_config_json, lens list) returned.
# Format: reader|file|key|value
_expected_values() {
  cat <<'TABLE'
init.value|templates/bundles/backend-feature/manifest.yaml|name|backend-feature
init.value|templates/bundles/backend-feature/manifest.yaml|description|Backend feature implementation — API, DB migration, tests (standard PDCA)
init.value|templates/bundles/backend-feature/manifest.yaml|version|1.0.0
init.value|templates/bundles/backend-feature/manifest.yaml|domain|code
init.value|templates/bundles/backend-feature/manifest.yaml|includes.team|team.yaml
init.value|templates/bundles/backend-feature/manifest.yaml|includes.workflow|workflow.yaml
init.value|templates/bundles/backend-feature/manifest.yaml|includes.domain|domain.yaml
init.value|templates/bundles/backend-feature/manifest.yaml|includes.config|config.yaml
init.list|templates/bundles/backend-feature/manifest.yaml|requires|
init.value|templates/bundles/quick-fix/manifest.yaml|name|quick-fix
init.value|templates/bundles/quick-fix/manifest.yaml|description|Small bug fix or patch — minimal team, 1 fast cycle, low overhead
init.value|templates/bundles/quick-fix/manifest.yaml|version|1.0.0
init.value|templates/bundles/quick-fix/manifest.yaml|domain|code
init.value|templates/bundles/quick-fix/manifest.yaml|includes.team|team.yaml
init.value|templates/bundles/quick-fix/manifest.yaml|includes.workflow|workflow.yaml
init.value|templates/bundles/quick-fix/manifest.yaml|includes.domain|domain.yaml
init.value|templates/bundles/quick-fix/manifest.yaml|includes.config|config.yaml
init.list|templates/bundles/quick-fix/manifest.yaml|requires|
init.value|templates/bundles/security-review/manifest.yaml|name|security-review
init.value|templates/bundles/security-review/manifest.yaml|description|Security-focused code review — full team with Trickster, 3 thorough cycles
init.value|templates/bundles/security-review/manifest.yaml|version|1.0.0
init.value|templates/bundles/security-review/manifest.yaml|domain|code
init.value|templates/bundles/security-review/manifest.yaml|includes.team|team.yaml
init.value|templates/bundles/security-review/manifest.yaml|includes.workflow|workflow.yaml
init.value|templates/bundles/security-review/manifest.yaml|includes.domain|domain.yaml
init.value|templates/bundles/security-review/manifest.yaml|includes.config|config.yaml
init.list|templates/bundles/security-review/manifest.yaml|requires|
init.value|templates/bundles/backend-feature/domain.yaml|name|code
init.value|templates/bundles/quick-fix/domain.yaml|name|code
init.value|templates/bundles/security-review/domain.yaml|name|code
init.value|.archeflow/config.yaml|workflow|
init.value|.archeflow/config.yaml|costs.budget_usd|10.00
init.value|.archeflow/config.yaml|costs.warn_at_percent|80
git|.archeflow/config.yaml|branch_prefix|archeflow/
git|.archeflow/config.yaml|commit_style|conventional
git|.archeflow/config.yaml|merge_strategy|no-ff
git|.archeflow/config.yaml|auto_push|false
git|.archeflow/config.yaml|signing_key|DEF
a2a|.archeflow/config.yaml|version|@VERSION@
conv|.archeflow/config.yaml|budget_usd|10.00
testcmd|.archeflow/config.yaml|test_command|
cfgjson|.archeflow/config.yaml|.lenses|
cfgjson|.archeflow/config.yaml|.models.mapping.haiku|
cfgjson|.archeflow/config.yaml|.models.mapping.sonnet|
cfgjson|.archeflow/config.yaml|.models.mapping.opus|
cfgjson|.archeflow/config.yaml|.models.ollama.base_url|
init.value|examples/config-local-ollama.yaml|workflow|
init.value|examples/config-local-ollama.yaml|costs.budget_usd|
init.value|examples/config-local-ollama.yaml|costs.warn_at_percent|
git|examples/config-local-ollama.yaml|branch_prefix|DEF
git|examples/config-local-ollama.yaml|commit_style|DEF
git|examples/config-local-ollama.yaml|merge_strategy|DEF
git|examples/config-local-ollama.yaml|auto_push|DEF
git|examples/config-local-ollama.yaml|signing_key|DEF
a2a|examples/config-local-ollama.yaml|version|0.9.0
conv|examples/config-local-ollama.yaml|budget_usd|
testcmd|examples/config-local-ollama.yaml|test_command|
cfgjson|examples/config-local-ollama.yaml|.lenses|
cfgjson|examples/config-local-ollama.yaml|.models.mapping.haiku|qwen3:8b
cfgjson|examples/config-local-ollama.yaml|.models.mapping.sonnet|qwen3:14b
cfgjson|examples/config-local-ollama.yaml|.models.mapping.opus|qwen3:14b
cfgjson|examples/config-local-ollama.yaml|.models.ollama.base_url|http://127.0.0.1:11434
init.value|templates/bundles/backend-feature/config.yaml|workflow|standard
init.value|templates/bundles/backend-feature/config.yaml|costs.budget_usd|5
init.value|templates/bundles/backend-feature/config.yaml|costs.warn_at_percent|80
git|templates/bundles/backend-feature/config.yaml|branch_prefix|DEF
git|templates/bundles/backend-feature/config.yaml|commit_style|DEF
git|templates/bundles/backend-feature/config.yaml|merge_strategy|DEF
git|templates/bundles/backend-feature/config.yaml|auto_push|DEF
git|templates/bundles/backend-feature/config.yaml|signing_key|DEF
a2a|templates/bundles/backend-feature/config.yaml|version|0.9.0
conv|templates/bundles/backend-feature/config.yaml|budget_usd|5
testcmd|templates/bundles/backend-feature/config.yaml|test_command|
cfgjson|templates/bundles/backend-feature/config.yaml|.lenses|
cfgjson|templates/bundles/backend-feature/config.yaml|.models.mapping.haiku|
cfgjson|templates/bundles/backend-feature/config.yaml|.models.mapping.sonnet|
cfgjson|templates/bundles/backend-feature/config.yaml|.models.mapping.opus|
cfgjson|templates/bundles/backend-feature/config.yaml|.models.ollama.base_url|
init.value|templates/bundles/quick-fix/config.yaml|workflow|fast
init.value|templates/bundles/quick-fix/config.yaml|costs.budget_usd|2
init.value|templates/bundles/quick-fix/config.yaml|costs.warn_at_percent|80
git|templates/bundles/quick-fix/config.yaml|branch_prefix|DEF
git|templates/bundles/quick-fix/config.yaml|commit_style|DEF
git|templates/bundles/quick-fix/config.yaml|merge_strategy|DEF
git|templates/bundles/quick-fix/config.yaml|auto_push|DEF
git|templates/bundles/quick-fix/config.yaml|signing_key|DEF
a2a|templates/bundles/quick-fix/config.yaml|version|0.9.0
conv|templates/bundles/quick-fix/config.yaml|budget_usd|2
testcmd|templates/bundles/quick-fix/config.yaml|test_command|
cfgjson|templates/bundles/quick-fix/config.yaml|.lenses|
cfgjson|templates/bundles/quick-fix/config.yaml|.models.mapping.haiku|
cfgjson|templates/bundles/quick-fix/config.yaml|.models.mapping.sonnet|
cfgjson|templates/bundles/quick-fix/config.yaml|.models.mapping.opus|
cfgjson|templates/bundles/quick-fix/config.yaml|.models.ollama.base_url|
init.value|templates/bundles/security-review/config.yaml|workflow|thorough
init.value|templates/bundles/security-review/config.yaml|costs.budget_usd|15
init.value|templates/bundles/security-review/config.yaml|costs.warn_at_percent|70
git|templates/bundles/security-review/config.yaml|branch_prefix|DEF
git|templates/bundles/security-review/config.yaml|commit_style|DEF
git|templates/bundles/security-review/config.yaml|merge_strategy|DEF
git|templates/bundles/security-review/config.yaml|auto_push|DEF
git|templates/bundles/security-review/config.yaml|signing_key|DEF
a2a|templates/bundles/security-review/config.yaml|version|0.9.0
conv|templates/bundles/security-review/config.yaml|budget_usd|15
testcmd|templates/bundles/security-review/config.yaml|test_command|
cfgjson|templates/bundles/security-review/config.yaml|.lenses|
cfgjson|templates/bundles/security-review/config.yaml|.models.mapping.haiku|
cfgjson|templates/bundles/security-review/config.yaml|.models.mapping.sonnet|
cfgjson|templates/bundles/security-review/config.yaml|.models.mapping.opus|
cfgjson|templates/bundles/security-review/config.yaml|.models.ollama.base_url|
lens.desc|lenses/compliance-gdpr.yaml|description|Flag personal data handling, consent gaps, and retention violations
lens.desc|lenses/prose-voice.yaml|description|Enforce voice consistency, dialect authenticity, and narrative coherence
lens.desc|lenses/security.yaml|description|Sharpen review for vulnerabilities, auth issues, and data exposure
TABLE
}

@test "yaml: characterization, every key read from the shipped YAML keeps its value" {
  local kind f k want got n=0
  while IFS='|' read -r kind f k want; do
    f="$ROOT/$f"
    [[ "$want" == "@VERSION@" ]] && want="$("$LIB_DIR/archeflow-version.sh")"
    case "$kind" in
      init.value|lens.desc) got=$(af_yaml_get "$f" "$k") ;;             # init.sh, lens.sh list
      init.list) got=$(af_yaml_list "$f" "$k" | paste -sd, -) ;;        # init.sh requires
      git) got=$(af_yaml_get "$f" "git.$k|$k" DEF) ;;                    # git.sh load_config
      a2a) got=$(AF_CONFIG_FILE=$f af_config_get version 0.9.0) ;;       # a2a.sh generate
      conv) got=$(af_yaml_get "$f" "costs.budget_usd|budget_usd") ;;     # convergence.sh wiggum-check
      testcmd) got=$(AF_CONFIG_FILE=$f af_config_test_command) ;;        # git.sh init, rollback.sh
      cfgjson) got=$(AF_CONFIG_FILE=$f af_config_get "${k#.}") ;;        # ollama.sh
      *) echo "unknown reader $kind"; return 1 ;;
    esac
    [[ "$got" == "$want" ]] || { echo "$kind $f $k: expected '$want', got '$got'"; return 1; }
    n=$((n + 1))
  done < <(_expected_values)
  [ "$n" -gt 100 ]
}

@test "yaml: init writes config.yaml from a bundle (manifest variables, workflow, costs)" {
  export HOME="$BATS_TEST_TMPDIR/home"
  run "$LIB_DIR/archeflow-init.sh" security-review
  [ "$status" -eq 0 ]
  [[ "$output" == *"Variables: max_cycles=3, target_paths=, threat_model="* ]]
  diff <(sed '/^initialized:/d' .archeflow/config.yaml) - <<'CFG'
# Generated by archeflow init from bundle: security-review
bundle: security-review
bundle_version: 1.0.0
variables:
  max_cycles: 3
  target_paths: 
  threat_model: 
workflow: thorough
costs:
  budget_usd: 15
  warn_at_percent: 70
CFG
}

@test "yaml: init --save writes a manifest that init reads back" {
  export HOME="$BATS_TEST_TMPDIR/home"
  "$LIB_DIR/archeflow-init.sh" backend-feature >/dev/null
  "$LIB_DIR/archeflow-init.sh" --save mine >/dev/null
  local m="$HOME/.archeflow/templates/bundles/mine/manifest.yaml"
  [ "$(af_yaml_get "$m" includes.team)" = "team.yaml" ]
  [ "$(af_yaml_get "$m" domain)" = "code" ]
  rm -rf .archeflow
  run "$LIB_DIR/archeflow-init.sh" mine
  [ "$status" -eq 0 ]
  [[ "$output" == *"Variables: lint_command=, max_cycles=2"* ]]
  grep -qx '  max_cycles: 2' .archeflow/config.yaml
}

# The converter must agree with a full YAML parser on every YAML file ArcheFlow
# ships, including block scalars in workflows and the agents' and skills'
# frontmatter. Numbers are compared by value (10.00 == 10.0).
@test "yaml: converter matches PyYAML on all shipped YAML and frontmatter" {
  command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML not installed"
  local norm='walk(if type == "number" then . + 0 else . end) | tojson'
  local f n=0
  mkdir -p fm
  # Frontmatter of the agents and skills, as plain YAML files.
  for f in "$ROOT"/agents/*.md "$ROOT"/skills/*/SKILL.md; do
    n=$((n + 1))
    awk '/^---$/{n++; next} n==1' "$f" > "fm/$n.yaml"
  done
  local -a files=("$ROOT"/.archeflow/*.yaml "$ROOT"/lenses/*.yaml "$ROOT"/patterns/*.yaml
                  "$ROOT"/templates/bundles/*/*.yaml "$ROOT"/examples/*.yaml fm/*.yaml)
  # One python process for all files: one JSON document per line, in order.
  python3 -c 'import sys, json, yaml
for p in sys.argv[1:]:
    print(json.dumps(yaml.safe_load(open(p))))' "${files[@]}" | jq -S "$norm" > expected.jsonl
  for f in "${files[@]}"; do
    "$LIB_DIR/archeflow-yaml.sh" "$f" | jq -S "$norm" || { echo "converter failed on $f"; return 1; }
  done > actual.jsonl
  local i=0 a b
  while IFS= read -r a && IFS= read -r b <&3; do
    [ "$a" = "$b" ] || { echo "differs: ${files[$i]}"; return 1; }
    i=$((i + 1))
  done < expected.jsonl 3< actual.jsonl
  [ "$i" -eq "${#files[@]}" ] && [ "$i" -gt 30 ]
}

@test "yaml: block scalars (| > with - and + chomping) as YAML defines them" {
  cat > b.yaml <<'YAML'
lit: |
  line one
    indented # not a comment

  after blank
strip: |-
  a
  b
keep: |+
  x

fold: >
  one
  two

  three
    more
  four
list:
  - |
    item block
  - name: n
    body: >-
      folded
      text
    after: 1
top: end
YAML
  run "$LIB_DIR/archeflow-yaml.sh" b.yaml
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"lit":"line one\n  indented # not a comment\n\nafter blank\n","strip":"a\nb","keep":"x\n\n","fold":"one two\nthree\n  more\nfour\n","list":["item block\n",{"name":"n","body":"folded text","after":1}],"top":"end"}' ]
}

@test "yaml: --text keeps the spelling of numbers and booleans" {
  printf 'a: 10.00\nb: .5\nc: 010\nd: true\ne: ~\nf: "10.00"\ng: [1.0, x]\n' > t.yaml
  run "$LIB_DIR/archeflow-yaml.sh" --text t.yaml
  [ "$status" -eq 0 ]
  [ "$output" = '{"a":"10.00","b":".5","c":"010","d":"true","e":null,"f":"10.00","g":["1.0","x"]}' ]
}

@test "yaml: typed mode rejects over-indented keys; --text skips them with their continuation lines" {
  printf 'a: 1\n  b: 2\nc: {x: 1}\n  d: 3\ne: ok\n' > t.yaml
  run "$LIB_DIR/archeflow-yaml.sh" t.yaml
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected indentation at line 2"* ]]
  run "$LIB_DIR/archeflow-yaml.sh" --text t.yaml
  [ "$status" -eq 0 ]
  [ "$output" = '{"a":"1","c":null,"e":"ok"}' ]
}

@test "af_yaml_get: dotted paths, alternatives, defaults and quoting" {
  cat > c.yaml <<'YAML'
top: plain value   # comment
quoted: "a \"b\" # c"
single: 'it''s'
empty: ""
nul: ~
num: 10.00
nested:
  key: inner
  deeper:
    leaf: 3
multi: |
  two
  lines
list: [a, b]
git:
  branch_prefix: from-git/
branch_prefix: top-level/
commit_style: top-only
YAML
  [ "$(af_yaml_get c.yaml top)" = "plain value" ]
  [ "$(af_yaml_get c.yaml quoted)" = 'a "b" # c' ]
  [ "$(af_yaml_get c.yaml single)" = "it's" ]
  [ "$(af_yaml_get c.yaml num)" = "10.00" ]
  [ "$(af_yaml_get c.yaml nested.key)" = "inner" ]
  [ "$(af_yaml_get c.yaml nested.deeper.leaf)" = "3" ]
  [ "$(af_yaml_get c.yaml empty DEF)" = "DEF" ]
  [ "$(af_yaml_get c.yaml nul DEF)" = "DEF" ]
  [ "$(af_yaml_get c.yaml missing DEF)" = "DEF" ]
  [ "$(af_yaml_get c.yaml top.below DEF)" = "DEF" ]      # path through a scalar
  [ "$(af_yaml_get c.yaml nested DEF)" = "DEF" ]         # a map is not a scalar
  [ "$(af_yaml_get c.yaml list DEF)" = "DEF" ]
  [ "$(af_yaml_get c.yaml multi DEF)" = "DEF" ]          # never spans lines
  [ "$(af_yaml_get no-such-file.yaml top DEF)" = "DEF" ]
  [ "$(af_yaml_get c.yaml 'git.branch_prefix|branch_prefix')" = "from-git/" ]
  [ "$(af_yaml_get c.yaml 'git.commit_style|commit_style')" = "top-only" ]
  [ "$(af_yaml_list c.yaml list | paste -sd, -)" = "a,b" ]
  [ -z "$(af_yaml_list c.yaml top)" ]
}

@test "af_yaml_map: scalar entries as NUL-separated pairs, nested and multi-line values skipped" {
  printf 'variables:\n  a: 1\n  b: ""\n  c:\n  d: [x]\n  e: |\n    two\n    lines\n  f: "x y"\nother: 1\n' > m.yaml
  local k v out=""
  while IFS= read -r -d '' k && IFS= read -r -d '' v; do out+="$k=$v;"; done < <(af_yaml_map m.yaml variables)
  [ "$out" = "a=1;b=;c=;f=x y;" ]
}

@test "af_yaml_get: values are data, never evaluated; keys never reach jq as code" {
  printf 'cmd: $(touch pwned1)\nq: "`touch pwned2`"\n' > s.yaml
  [ "$(af_yaml_get s.yaml cmd)" = '$(touch pwned1)' ]
  [ "$(af_yaml_get s.yaml q)" = '`touch pwned2`' ]
  run af_yaml_get s.yaml '") | halt_error("x'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e pwned1 ] && [ ! -e pwned2 ]
}

@test "af_config_test_command: top level only, the last duplicate wins, unparseable lines elsewhere are skipped" {
  mkdir -p .archeflow
  cat > .archeflow/config.yaml <<'YAML'
other:
  test_command: "nested, never used"
weird: {flow: map}
  test_command: continuation of an unparseable value
test_command: 'echo "a b"'
YAML
  [ "$(af_config_test_command)" = 'echo "a b"' ]
  printf 'test_command: first\ntest_command: second\n' > .archeflow/config.yaml
  [ "$(af_config_test_command)" = "second" ]
  rm .archeflow/config.yaml
  [ -z "$(af_config_test_command)" ]
}

@test "af_config_json: {} without a config, non-zero on YAML outside the subset" {
  [ "$(af_config_json)" = "{}" ]
  mkdir -p .archeflow
  printf 'lenses: [security]\n' > .archeflow/config.yaml
  [ "$(af_config_json)" = '{"lenses":["security"]}' ]
  printf 'a: &anchor x\n' > .archeflow/config.yaml
  run af_config_json
  [ "$status" -ne 0 ]
}

@test "yaml: git reads git.* first, then the top-level key, then its default" {
  mkdir -p .archeflow
  printf 'branch_prefix: top/\ngit:\n  branch_prefix: "af-git/"   # quoted\n' > .archeflow/config.yaml
  run "$LIB_DIR/archeflow-git.sh" init r1
  [ "$status" -eq 0 ]
  git show-ref --verify --quiet refs/heads/af-git/r1
  printf 'branch_prefix: top/\n' > .archeflow/config.yaml
  run "$LIB_DIR/archeflow-git.sh" init r2
  [ "$status" -eq 0 ]
  git show-ref --verify --quiet refs/heads/top/r2
}

@test "yaml: wiggum-check reads costs.budget_usd as written (10.00 stays 10.00)" {
  mkdir -p .archeflow
  printf 'costs:\n  budget_usd: 10.00   # per run\n' > .archeflow/config.yaml
  "$LIB_DIR/archeflow-event.sh" r1 agent.complete do maker '{"estimated_cost_usd":9.80}' >/dev/null
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check r1
  [ "$status" -eq 0 ]
  [[ "$output" == *'of $10.00'* ]]
}
