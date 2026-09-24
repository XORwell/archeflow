# Tests for archeflow-langfuse.sh — config parsing and request hygiene.
#
# A fake `curl` on PATH records its argv and the header file it was given, so
# no network access is needed.

setup() {
  load test_helper
  _common_setup
  export HOME="$BATS_TEST_TMPDIR/home"
  unset XDG_CONFIG_HOME  # hermetic: CI runners set it, which would bypass $HOME/.config
  mkdir -p "$HOME" .archeflow "$BATS_TEST_TMPDIR/bin"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.argv"
  export CURL_HDR="$BATS_TEST_TMPDIR/curl.headers"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_LOG"
prev=""
for a in "$@"; do
  if [[ "$prev" == "-H" && "$a" == @* ]]; then cat "${a#@}" > "$CURL_HDR"; fi
  prev="$a"
done
printf '200'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  EVENT='{"run_id":"r1","seq":1,"ts":"2026-01-01T00:00:00Z","type":"run.start","phase":"plan","agent":"","data":{"task":"t"}}'
}

teardown() {
  _common_teardown
}

@test "langfuse: no config means silent no-op" {
  run bash -c "echo '$EVENT' | '$LIB_DIR/archeflow-langfuse.sh'"
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_LOG" ]
}

@test "langfuse: config file is parsed as data, never executed" {
  cat > .archeflow/langfuse.env <<EOF
LANGFUSE_ENABLED=true
LANGFUSE_HOST=http://127.0.0.1:9
LANGFUSE_PUBLIC_KEY=pk
LANGFUSE_SECRET_KEY=sk
\$(touch "$BATS_TEST_TMPDIR/pwned")
touch "$BATS_TEST_TMPDIR/pwned2"
EOF
  run bash -c "echo '$EVENT' | '$LIB_DIR/archeflow-langfuse.sh'"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned2" ]
  [ -f "$CURL_LOG" ]
}

@test "langfuse: secret is sent via header file, not argv" {
  cat > .archeflow/langfuse.env <<'EOF'
export LANGFUSE_ENABLED="true"
LANGFUSE_HOST='http://127.0.0.1:9/'   # trailing comment
LANGFUSE_PUBLIC_KEY=pk-test
LANGFUSE_SECRET_KEY=sk-very-secret # comment
EOF
  run bash -c "echo '$EVENT' | '$LIB_DIR/archeflow-langfuse.sh'"
  [ "$status" -eq 0 ]
  expected_auth="Authorization: Basic $(printf 'pk-test:sk-very-secret' | base64 | tr -d '\n')"
  ! grep -q 'sk-very-secret' "$CURL_LOG"
  ! grep -q 'Authorization' "$CURL_LOG"
  grep -qx "$expected_auth" "$CURL_HDR"
  grep -qx 'http://127.0.0.1:9/api/public/ingestion' "$CURL_LOG"
  # Response goes to a private mktemp file, not a predictable /tmp/.archeflow-langfuse.$$ path.
  ! grep -q '/tmp/.archeflow-langfuse\.' "$CURL_LOG"
}

@test "langfuse: temp files are removed after the POST" {
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  printf 'LANGFUSE_ENABLED=true\nLANGFUSE_HOST=http://127.0.0.1:9\nLANGFUSE_PUBLIC_KEY=a\nLANGFUSE_SECRET_KEY=b\n' > .archeflow/langfuse.env
  run bash -c "echo '$EVENT' | '$LIB_DIR/archeflow-langfuse.sh'"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "langfuse: caller's PAYLOAD env var is not forwarded" {
  printf 'LANGFUSE_ENABLED=true\nLANGFUSE_HOST=http://127.0.0.1:9\nLANGFUSE_PUBLIC_KEY=a\nLANGFUSE_SECRET_KEY=b\n' > .archeflow/langfuse.env
  run env PAYLOAD='{"injected":true}' bash -c "echo '$EVENT' | '$LIB_DIR/archeflow-langfuse.sh'"
  [ "$status" -eq 0 ]
  ! grep -q 'injected' "$CURL_LOG"
  grep -q 'trace-create' "$CURL_LOG"
}

# --- B2: config comes from one trusted source ------------------------------

@test "langfuse: git-tracked (repository-supplied) langfuse.env is refused" {
  printf 'LANGFUSE_ENABLED=true\nLANGFUSE_HOST=https://attacker.example\nLANGFUSE_PUBLIC_KEY=a\nLANGFUSE_SECRET_KEY=b\n' \
    > .archeflow/langfuse.env
  git add -f .archeflow/langfuse.env && git commit --quiet -m "repo ships langfuse config"
  run bash -c "echo '$EVENT' | '$LIB_DIR/archeflow-langfuse.sh'"
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_LOG" ]
}

@test "langfuse: inherited keys are never combined with a host from a file" {
  printf 'LANGFUSE_ENABLED=true\nLANGFUSE_HOST=https://attacker.example\n' > .archeflow/langfuse.env
  run env LANGFUSE_PUBLIC_KEY=pk-lf-victim LANGFUSE_SECRET_KEY=sk-lf-victim-secret \
    bash -c "echo '$EVENT' | '$LIB_DIR/archeflow-langfuse.sh'"
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_LOG" ]
}

@test "langfuse: env-only config works without any file" {
  run env LANGFUSE_ENABLED=true LANGFUSE_HOST=https://cloud.langfuse.example \
    LANGFUSE_PUBLIC_KEY=pk LANGFUSE_SECRET_KEY=sk \
    bash -c "echo '$EVENT' | '$LIB_DIR/archeflow-langfuse.sh'"
  [ "$status" -eq 0 ]
  grep -qx 'https://cloud.langfuse.example/api/public/ingestion' "$CURL_LOG"
}

@test "langfuse: env mode ignores a project file entirely" {
  printf 'LANGFUSE_ENABLED=true\nLANGFUSE_HOST=http://127.0.0.1:1\nLANGFUSE_PUBLIC_KEY=x\nLANGFUSE_SECRET_KEY=y\n' \
    > .archeflow/langfuse.env
  run env LANGFUSE_ENABLED=true LANGFUSE_HOST=https://mine.example LANGFUSE_PUBLIC_KEY=pk LANGFUSE_SECRET_KEY=sk \
    bash -c "echo '$EVENT' | '$LIB_DIR/archeflow-langfuse.sh'"
  grep -qx 'https://mine.example/api/public/ingestion' "$CURL_LOG"
  grep -qx "Authorization: Basic $(printf 'pk:sk' | base64 | tr -d '\n')" "$CURL_HDR"
}

@test "langfuse: parent directories are not searched for langfuse.env" {
  printf 'LANGFUSE_ENABLED=true\nLANGFUSE_HOST=http://127.0.0.1:9\nLANGFUSE_PUBLIC_KEY=a\nLANGFUSE_SECRET_KEY=b\n' \
    > .archeflow/langfuse.env
  mkdir inner && cd inner && git init --quiet
  run bash -c "echo '$EVENT' | '$LIB_DIR/archeflow-langfuse.sh'"
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_LOG" ]
}

@test "langfuse: user-level config in XDG_CONFIG_HOME is used" {
  mkdir -p "$HOME/.config/archeflow"
  printf 'LANGFUSE_ENABLED=true\nLANGFUSE_HOST=https://lf.example\nLANGFUSE_PUBLIC_KEY=a\nLANGFUSE_SECRET_KEY=b\n' \
    > "$HOME/.config/archeflow/langfuse.env"
  run bash -c "echo '$EVENT' | '$LIB_DIR/archeflow-langfuse.sh'"
  grep -qx 'https://lf.example/api/public/ingestion' "$CURL_LOG"
}

@test "langfuse: plain-http non-loopback hosts and URLs with credentials are refused" {
  for host in http://lf.example http://127.evil.example "https://u:p@lf.example" "http://localhost.evil.example"; do
    printf 'LANGFUSE_ENABLED=true\nLANGFUSE_HOST=%s\nLANGFUSE_PUBLIC_KEY=a\nLANGFUSE_SECRET_KEY=b\n' "$host" \
      > .archeflow/langfuse.env
    run bash -c "echo '$EVENT' | '$LIB_DIR/archeflow-langfuse.sh'"
    [ "$status" -eq 0 ]
    [ ! -f "$CURL_LOG" ]
  done
  grep -q "refusing LANGFUSE_HOST" .archeflow/langfuse.errors.log
}

@test "langfuse: the error log is never appended through a symlink" {
  printf 'LANGFUSE_ENABLED=true\nLANGFUSE_HOST=http://lf.example\nLANGFUSE_PUBLIC_KEY=a\nLANGFUSE_SECRET_KEY=b\n' \
    > .archeflow/langfuse.env
  echo keep > "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" .archeflow/langfuse.errors.log
  run bash -c "echo '$EVENT' | '$LIB_DIR/archeflow-langfuse.sh'"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = "keep" ]
}
