#!/usr/bin/env bash
# archeflow-lock.sh — tiny advisory lock helper, sourced by other lib scripts.
#
#   source "<archeflow-root>/lib/archeflow-lock.sh"
#   af_lock   <lockfile> [timeout_s]   # acquire (default 10s); returns 1 on timeout
#   af_unlock <lockfile>               # release
#
# Uses flock(1) on fd 9 when available (Linux, util-linux); otherwise falls back
# to an atomic mkdir("<lockfile>.d") spin lock (macOS/BSD). A mkdir lock older
# than 60s is treated as stale (holder crashed) and broken.

af_lock() {
  local lockfile="$1" timeout="${2:-10}"
  # Lock files live under a possibly committed .archeflow/: do not follow a symlink.
  if [[ -L "$lockfile" ]]; then
    echo "Error: refusing to use symlinked lock file: $lockfile" >&2
    return 1
  fi
  if command -v flock >/dev/null 2>&1; then
    exec 9>>"$lockfile" || return 1
    flock -w "$timeout" 9 || return 1
    return 0
  fi
  local dir="${lockfile}.d" waited=0 max=$(( timeout * 20 ))
  until mkdir "$dir" 2>/dev/null; do
    # Break stale locks (older than 60s).
    if [[ -n "$(find "$dir" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
      rmdir "$dir" 2>/dev/null || true
      continue
    fi
    (( waited++ >= max )) && return 1
    sleep 0.05
  done
  return 0
}

af_unlock() {
  local lockfile="$1"
  if command -v flock >/dev/null 2>&1; then
    flock -u 9 2>/dev/null || true
    exec 9>&-  # NB: no other redirections here; with exec they would persist
    return 0
  fi
  rmdir "${lockfile}.d" 2>/dev/null || true
}
