# Tests for archeflow-common.sh — shared validation helpers.

setup() {
  load test_helper
  _common_setup
  # shellcheck source=lib/archeflow-common.sh
  source "$LIB_DIR/archeflow-common.sh"
}

teardown() {
  _common_teardown
}

@test "common: af_as_int passes integers and never evaluates expressions" {
  [ "$(af_as_int 42)" = "42" ]
  [ "$(af_as_int -7)" = "-7" ]
  [ "$(af_as_int 010)" = "10" ]          # decimal, not octal
  [ "$(af_as_int 08)" = "8" ]
  [ "$(af_as_int '')" = "0" ]
  [ "$(af_as_int 1.5)" = "0" ]
  [ "$(af_as_int 1+1)" = "0" ]
  [ "$(af_as_int x 9)" = "9" ]
  [ "$(af_as_int 99999999999999999999)" = "0" ]
  [ "$(af_as_int 'a[$(touch '"$BATS_TEST_TMPDIR"'/pwned)]')" = "0" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "common: af_valid_name accepts run IDs and rejects paths and options" {
  af_valid_name 2026-09-24-add-auth
  af_valid_name r1.v2_x
  ! af_valid_name ""
  ! af_valid_name ../x
  ! af_valid_name a/b
  ! af_valid_name -rf
  ! af_valid_name .hidden
  ! af_valid_name 'a..b'
}

@test "common: af_require_run_id exits with a clear error" {
  run af_require_run_id '../../etc'
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid run_id"* ]]
}

@test "common: die prints the script prefix and exits 1" {
  run bash -c 'AF_LOG_PREFIX=mq; source "$1"; die boom' _ "$LIB_DIR/archeflow-common.sh"
  [ "$status" -eq 1 ]
  [ "$output" = "[mq] ERROR: boom" ]
  run bash -c 'source "$1"; die boom' _ "$LIB_DIR/archeflow-common.sh"
  [ "$output" = "ERROR: boom" ]
}

@test "common: af_append refuses symlinks and af_tmpfile is private and adjacent" {
  echo keep > target
  ln -s target link
  run af_append link "x"
  [ "$status" -ne 0 ]
  [ "$(cat target)" = "keep" ]
  af_append plain "line"
  [ "$(cat plain)" = "line" ]
  t=$(af_tmpfile "$PWD/queue.json")
  [[ "$t" == "$PWD/queue.json."* ]]
  [ "$(stat -c %a "$t" 2>/dev/null || stat -f %Lp "$t")" = "600" ]
}
