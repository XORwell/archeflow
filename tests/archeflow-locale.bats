# Convergence scoring under a decimal-comma locale (de_DE.UTF-8).
#
# awk implementations that honour LC_NUMERIC (mawk, BSD/macOS awk, gawk in POSIX
# mode) print "0,67" and parse "0.5" as 0 under de_DE. To make that behaviour
# reproducible on any host, setup() puts an `awk` shim first on PATH that runs
# `gawk --posix` (gawk honours LC_NUMERIC only in POSIX mode). Without the
# de_DE.UTF-8 locale or gawk the tests are skipped; with
# ARCHEFLOW_REQUIRE_DE_LOCALE=1 (set in CI) they fail instead.

setup() {
  load test_helper
  _common_setup

  local gawk_bin
  gawk_bin="$(command -v gawk || true)"
  if [[ -n "$gawk_bin" ]]; then
    mkdir -p "$BATS_TEST_TMPDIR/shim"
    printf '#!/bin/sh\nexec %s --posix "$@"\n' "$gawk_bin" > "$BATS_TEST_TMPDIR/shim/awk"
    chmod +x "$BATS_TEST_TMPDIR/shim/awk"
    PATH="$BATS_TEST_TMPDIR/shim:$PATH"
  fi
  export LC_ALL=de_DE.UTF-8

  # Precondition: awk really formats with a decimal comma here.
  local probe
  probe="$(awk 'BEGIN {printf "%.1f", 0.5}' 2>/dev/null || true)"
  if [[ "$probe" != "0,5" ]]; then
    if [[ -n "${ARCHEFLOW_REQUIRE_DE_LOCALE:-}" ]]; then
      echo "de_DE.UTF-8 decimal-comma awk not available (probe: '$probe')" >&2
      return 1
    fi
    skip "needs the de_DE.UTF-8 locale and gawk (probe printed '$probe')"
  fi
}

teardown() {
  _common_teardown
}

@test "locale de_DE: score prints a decimal point and valid JSON" {
  echo '[{"id":"f1"},{"id":"f2"},{"id":"f3"}]' > prev.json
  echo '[{"id":"f2"},{"id":"f4"}]' > curr.json
  run "$LIB_DIR/archeflow-convergence.sh" score curr.json prev.json
  [ "$status" -eq 0 ]
  jq -e '.convergence_score == 0.67 and .status == "stalling"' <<<"$output"
  [[ "$output" != *"syntax error"* ]]
}

@test "locale de_DE: score above 0.8 is converging" {
  printf '[%s]\n' '{"id":"f1"},{"id":"f2"},{"id":"f3"},{"id":"f4"},{"id":"f5"}' > prev.json
  echo '[]' > curr.json
  run "$LIB_DIR/archeflow-convergence.sh" score curr.json prev.json
  [ "$status" -eq 0 ]
  jq -e '.convergence_score == 1 and .status == "converging"' <<<"$output"
}

@test "locale de_DE: wiggum-check reads 0.67 and 0.75 as stalling, not diverging" {
  mkdir -p run_dir/cycle-1 run_dir/cycle-2
  echo '{"convergence_score":0.67}' > run_dir/cycle-1/convergence.json
  echo '{"convergence_score":0.75}' > run_dir/cycle-2/convergence.json
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check run_dir
  [ "$status" -eq 1 ]
  jq -e '.wiggum_break == false' <<<"$output"
}

@test "locale de_DE: budget soft break with a fractional budget" {
  mkdir -p .archeflow/runs/r1
  printf 'costs:\n  budget_usd: 0.50\n' > .archeflow/config.yaml
  printf '%s\n' '{"type":"cost.recorded","data":{"estimated_cost_usd":0.49}}' > .archeflow/runs/r1/events.jsonl
  run "$LIB_DIR/archeflow-convergence.sh" wiggum-check .archeflow/runs/r1
  [ "$status" -eq 0 ]
  [[ "$output" == *'Budget >95% spent ($0.49 of $0.50, 98%)'* ]]
}
