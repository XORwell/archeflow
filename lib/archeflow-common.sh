#!/usr/bin/env bash
# archeflow-common.sh — shared helpers, sourced by the other lib scripts.
#
#   # shellcheck source=lib/archeflow-common.sh
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archeflow-common.sh"
#
# Provides:
#   die <msg...>              print "<prefix>ERROR: msg" to stderr, exit 1
#                             (prefix = "[$AF_LOG_PREFIX] " when AF_LOG_PREFIX is set)
#   af_valid_name <s>         0 if <s> is a safe file-stem / run ID / bundle name
#   af_require_run_id <id>    exit 1 with an error unless af_valid_name <id>
#   af_is_int <s>             0 if <s> is a plain decimal integer (optional leading -)
#   af_as_int <s> [default]   print <s> as a base-10 integer, or <default> (0)
#   af_tmpfile <target>       private temp file next to <target> (for atomic mv)
#   af_refuse_symlink <path>  return 1 (with a message) if <path> is a symlink
#   af_append <file> <line>   append one line, refusing to follow a symlink
#   af_default_branch         repository default branch (origin/HEAD, main,
#                             master, else the current branch; may print "")
#
# Why af_as_int exists: bash evaluates $(( x )), (( x )) and [[ x -gt y ]]
# recursively, so a value such as 'a[$(cmd)]' read from a JSON file runs cmd.
# Never feed data you did not compute yourself into shell arithmetic; pass it
# through af_as_int first (or do the math in jq).

# Guard against double sourcing.
[[ -n "${_AF_COMMON_LOADED:-}" ]] && return 0
_AF_COMMON_LOADED=1

die() {
  printf '%sERROR: %s\n' "${AF_LOG_PREFIX:+[$AF_LOG_PREFIX] }" "$*" >&2
  exit 1
}

# Run IDs, lens names and bundle names become path components (and git branch
# names), so reject path separators, "..", and leading dashes/dots
# (path traversal / option injection).
af_valid_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "${1:-}" != *..* ]]
}

af_require_run_id() {
  if ! af_valid_name "${1:-}"; then
    echo "Error: invalid run_id '${1:-}' (allowed: letters, digits, '.', '_', '-')" >&2
    exit 1
  fi
}

af_is_int() {
  [[ "${1:-}" =~ ^-?[0-9]+$ ]]
}

# Normalises leading zeros ("010" -> 10, not octal 8) and never evaluates the
# input as an expression. Values that do not fit in 18 digits fall back to the
# default instead of overflowing.
af_as_int() {
  local v="${1:-}" def="${2:-0}" sign="" digits
  if [[ "$v" =~ ^(-?)([0-9]{1,18})$ ]]; then
    sign="${BASH_REMATCH[1]}"
    digits="${BASH_REMATCH[2]}"
    printf '%s' "$(( ${sign}10#$digits ))"
  else
    printf '%s' "$def"
  fi
}

af_tmpfile() {
  local target="$1"
  mktemp "${target}.XXXXXX"
}

af_refuse_symlink() {
  if [[ -L "$1" ]]; then
    echo "Error: refusing to write through symlink: $1" >&2
    return 1
  fi
  return 0
}

af_append() {
  local file="$1" line="$2"
  af_refuse_symlink "$file" || return 1
  printf '%s\n' "$line" >> "$file"
}

# Repository default branch, without assuming "main": origin/HEAD, then an
# existing main or master, then the current branch (empty when detached).
af_default_branch() {
  local ref
  if ref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
    echo "${ref#refs/remotes/origin/}"
  elif git show-ref --verify --quiet refs/heads/main; then
    echo "main"
  elif git show-ref --verify --quiet refs/heads/master; then
    echo "master"
  else
    git branch --show-current 2>/dev/null || true
  fi
}
