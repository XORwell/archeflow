#!/usr/bin/env bats
# Every user-facing lib script answers --help with usage text and exit 0,
# without touching the working directory (no git repo or .archeflow needed).

setup() {
  LIB="$BATS_TEST_DIRNAME/../lib"
  WORK="$(mktemp -d)"
  cd "$WORK"
}

teardown() {
  rm -rf "$WORK"
}

@test "lib scripts: --help prints usage and exits 0" {
  local failures=()
  for f in "$LIB"/archeflow-*.sh; do
    case "$(basename "$f")" in
      archeflow-common.sh|archeflow-yaml.sh|archeflow-lock.sh|archeflow-version.sh) continue ;;
    esac
    run bash "$f" --help </dev/null
    if [[ "$status" -ne 0 || -z "$output" ]]; then
      failures+=("$(basename "$f") (status=$status)")
    fi
  done
  [[ -z "$(ls -A "$WORK")" ]] || failures+=("--help wrote files: $(ls -A "$WORK")")
  if (( ${#failures[@]} )); then
    printf '%s\n' "${failures[@]}"
    return 1
  fi
}
