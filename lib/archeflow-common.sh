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
#   af_refuse_symlink <path>  return 1 (with a message) if <path>, or any of its
#                             parent directories below the project root, is a symlink
#   af_append <file> <line>   append one line, refusing to follow a symlink
#   af_check_state_dirs       exit 1 if .archeflow/ or one of its state directories
#                             is a symlink or resolves outside the repository
#   af_yaml_to_json <file>    YAML -> JSON (yq, python3+PyYAML, or archeflow-yaml.sh)
#   af_config_json            .archeflow/config.yaml as JSON ("{}" if absent)
#   af_config_test_command    the top-level test_command of .archeflow/config.yaml
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

# Every existing component of <path> is checked, not just the last one: a
# committed ".archeflow/events -> /elsewhere" would otherwise redirect writes
# outside the repository. Relative paths are checked from the current
# directory down; absolute paths only below the project root (so system-level
# links such as /tmp -> /private/tmp on macOS do not count).
af_refuse_symlink() {
  local p="$1" cur rest part root
  if [[ "$p" == /* ]]; then
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    if [[ "$p" == "$root"/* ]]; then
      cur="$root"; rest="${p#"$root"/}"
    else
      cur=""; rest=""
      [[ -L "$p" ]] && { echo "Error: refusing to write through symlink: $p" >&2; return 1; }
    fi
  else
    cur="."; rest="$p"
  fi
  local -a parts=()
  [[ -n "$rest" ]] && IFS=/ read -r -a parts <<<"$rest"
  for part in "${parts[@]}"; do
    [[ -z "$part" || "$part" == "." ]] && continue
    cur="$cur/$part"
    if [[ -L "$cur" ]]; then
      echo "Error: refusing to write through symlink: ${cur#./} (in $p)" >&2
      return 1
    fi
  done
  return 0
}

# Refuse to operate when ArcheFlow's state directory, or one of its standard
# subdirectories, is a symlink or resolves outside the repository. Call it at
# the top of every script that writes under .archeflow/. Missing directories
# are fine (they are created later, as real directories).
AF_STATE_SUBDIRS=(events artifacts runs worktrees memory locks merge-queue templates lenses progress)
af_check_state_dirs() {
  local base="${1:-.archeflow}" d root real
  if [[ -L "$base" ]]; then
    die "refusing to use ${base}: it is a symlink (a repository can point it anywhere)."
  fi
  [[ -e "$base" ]] || return 0
  [[ -d "$base" ]] || die "refusing to use ${base}: not a directory."
  for d in "${AF_STATE_SUBDIRS[@]}"; do
    [[ -L "$base/$d" ]] && die "refusing to use ${base}/${d}: it is a symlink (a repository can point it anywhere)."
  done
  if root="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$root" ]]; then
    root="$(cd "$root" && pwd -P)"
    real="$(cd "$base" && pwd -P)"
    [[ "$real" == "$root" || "$real" == "$root"/* ]] \
      || die "refusing to use ${base}: it resolves outside the repository (${real})."
  fi
  return 0
}

# YAML -> JSON: mikefarah yq, else python3+PyYAML, else the built-in
# dependency-free converter. The file path is always passed as an argument.
af_yaml_to_json() {
  local file="$1" here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -qi mikefarah; then
    yq -o=json '.' "$file"
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c 'import sys, json, yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1])), default=str))' "$file"
  else
    "$here/archeflow-yaml.sh" "$file"
  fi
}

# .archeflow/config.yaml as a JSON object; "{}" when the file is absent or empty.
# Exits non-zero when the file exists but cannot be parsed.
af_config_json() {
  local file="${AF_CONFIG_FILE:-.archeflow/config.yaml}" json
  [[ -f "$file" ]] || { echo '{}'; return 0; }
  # The dependency-free converter only, so every host parses config the same way.
  json="$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archeflow-yaml.sh" "$file")" || return 1
  jq -c 'if type == "object" then . else {} end' <<<"${json:-null}"
}

# Top-level test_command (a nested "x: {test_command: ...}" never counts).
# Prints "" when unset. Falls back to a plain top-level line match when the
# config uses YAML the converters cannot read.
af_config_test_command() {
  local file="${AF_CONFIG_FILE:-.archeflow/config.yaml}" json
  [[ -f "$file" ]] || return 0
  if json="$(af_config_json 2>/dev/null)"; then
    jq -r '.test_command // empty | if type == "string" then . else tostring end' <<<"$json"
  else
    awk '/^test_command:/ { sub(/^test_command:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, "")
           if ($0 ~ /^".*"$/ || $0 ~ /^\047.*\047$/) $0 = substr($0, 2, length($0) - 2)
           print; exit }' "$file"
  fi
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
