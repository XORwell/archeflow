#!/usr/bin/env bash
# archeflow-review.sh — Get a git diff for Guardian review, with stats.
#
# Standalone diff helper for af-review. No PDCA orchestration — just extracts
# the right diff and reports stats so the Claude Code agent can feed it to
# Guardian (or other reviewers).
#
# Usage:
#   archeflow-review.sh                          # Uncommitted changes (staged + unstaged
#                                                # + new untracked files, except ignored
#                                                # files and .archeflow/)
#   archeflow-review.sh --branch feat/batch-api  # Branch diff vs the base branch
#   archeflow-review.sh --commit HEAD~3..HEAD    # Commit range
#   archeflow-review.sh --base develop           # Override base branch
#
# Base branch default: origin/HEAD, then main, then master, then the current
# branch (af_default_branch in archeflow-common.sh, shared with archeflow-git.sh).
#   archeflow-review.sh --stat-only              # Only print stats, no diff output
#
# Output:
#   Prints the diff to stdout. Stats go to stderr so they don't pollute the diff.
#   Exit code 0 if diff is non-empty, 1 if empty (nothing to review).
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

BASE_BRANCH=""       # empty = auto-detect (af_default_branch)
MODE="uncommitted"   # uncommitted | branch | commit
TARGET=""
STAT_ONLY="false"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # read by die() in archeflow-common.sh
AF_LOG_PREFIX="af-review"
# shellcheck source=lib/archeflow-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archeflow-common.sh"

info() {
  echo "[af-review] $*" >&2
}

# Print diff stats (files changed, insertions, deletions) to stderr.
print_stats() {
  local diff_text="$1"

  local files_changed lines_added lines_removed total_lines
  files_changed=$(echo "$diff_text" | grep -c '^diff --git' || true)
  lines_added=$(echo "$diff_text" | grep -c '^+[^+]' || true)
  lines_removed=$(echo "$diff_text" | grep -c '^-[^-]' || true)
  total_lines=$(echo "$diff_text" | wc -l | tr -d ' ')

  info "--- Review Stats ---"
  info "Files changed:  ${files_changed}"
  info "Lines added:    +${lines_added}"
  info "Lines removed:  -${lines_removed}"
  info "Diff size:      ${total_lines} lines"

  if [[ "$total_lines" -gt 500 ]]; then
    info "Warning: large diff (>500 lines). Consider reviewing per-file."
  fi
}

# Resolve the base branch for --branch mode. A default branch that only
# exists as origin/<name> (fresh clone, never checked out) is diffed against
# the remote-tracking ref.
resolve_base_branch() {
  local base="$1"
  if [[ -z "$base" ]]; then
    base=$(af_default_branch)
    [[ -n "$base" ]] || die "Cannot detect the base branch (detached HEAD?). Pass --base <branch>."
    if ! git show-ref --verify --quiet "refs/heads/${base}" \
       && git show-ref --verify --quiet "refs/remotes/origin/${base}"; then
      base="origin/${base}"
    fi
  fi
  echo "$base"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)
        MODE="branch"
        TARGET="${2:?Missing branch name after --branch}"
        shift 2
        ;;
      --commit)
        MODE="commit"
        TARGET="${2:?Missing commit range after --commit}"
        shift 2
        ;;
      --base)
        BASE_BRANCH="${2:?Missing base branch after --base}"
        shift 2
        ;;
      --stat-only)
        STAT_ONLY="true"
        shift
        ;;
      -h|--help)
        echo "Usage: $0 [--branch <name>] [--commit <range>] [--base <branch>] [--stat-only]"
        echo ""
        echo "  (no args)           Review uncommitted changes (staged, unstaged and new untracked files)"
        echo "  --branch <name>     Review branch diff against the base branch"
        echo "  --commit <range>    Review a commit range (e.g. HEAD~3..HEAD)"
        echo "  --base <branch>     Override base branch (default: origin/HEAD, main, master, current)"
        echo "  --stat-only         Print stats only, no diff output"
        exit 0
        ;;
      *)
        die "Unknown argument: $1. Use --help for usage."
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Diff extraction
# ---------------------------------------------------------------------------

get_diff() {
  local diff_text=""

  # Refs/ranges are passed to git as positional args; a value starting with
  # "-" would be parsed as an option (e.g. --output=<path> truncates/writes an
  # arbitrary file), so reject it outright.
  if [[ "${TARGET:-}" == -* || "${BASE_BRANCH:-}" == -* ]]; then
    die "Invalid ref: refs and ranges must not start with '-'."
  fi

  case "$MODE" in
    uncommitted)
      # Combine staged and unstaged changes against HEAD
      diff_text=$(git diff --text --no-textconv --no-ext-diff HEAD 2>/dev/null || true)
      if [[ -z "$diff_text" ]]; then
        # Maybe everything is staged, try just staged
        diff_text=$(git diff --text --no-textconv --no-ext-diff --cached 2>/dev/null || true)
      fi
      # New files are the common case for a feature: add untracked, non-ignored
      # files as new-file diffs. ArcheFlow's own state (.archeflow/, e.g. the
      # review.diff this review writes) is not part of the change.
      local untracked_diff="" f d
      while IFS= read -r -d '' f; do
        [[ "$f" == .archeflow/* ]] && continue
        [[ -f "$f" && ! -L "$f" ]] || continue
        # exit 1 = "files differ", the expected result against /dev/null
        d=$(git diff --text --no-textconv --no-ext-diff --no-index -- /dev/null "$f" 2>/dev/null || true)
        [[ -n "$d" ]] && untracked_diff+="${d}"$'\n'
      done < <(git ls-files -z --others --exclude-standard 2>/dev/null)
      if [[ -n "$untracked_diff" ]]; then
        if [[ -n "$diff_text" ]]; then
          diff_text="${diff_text}"$'\n'"${untracked_diff%$'\n'}"
        else
          diff_text="${untracked_diff%$'\n'}"
        fi
      fi
      ;;
    branch)
      # Verify target branch exists
      if ! git show-ref --verify --quiet "refs/heads/${TARGET}" 2>/dev/null; then
        # Maybe it's a remote branch
        if ! git rev-parse --verify --end-of-options "${TARGET}" &>/dev/null; then
          die "Branch '${TARGET}' not found."
        fi
      fi
      if ! git rev-parse --verify --quiet --end-of-options "${BASE_BRANCH}^{commit}" &>/dev/null; then
        die "Base branch '${BASE_BRANCH}' not found. Pass --base <branch>."
      fi
      diff_text=$(git diff --text --no-textconv --no-ext-diff --end-of-options "${BASE_BRANCH}...${TARGET}" 2>/dev/null || true)
      ;;
    commit)
      # Validate commit range resolves
      if ! git rev-parse --end-of-options "${TARGET}" &>/dev/null; then
        die "Invalid commit range: '${TARGET}'"
      fi
      diff_text=$(git diff --text --no-textconv --no-ext-diff --end-of-options "${TARGET}" 2>/dev/null || true)
      ;;
  esac

  echo "$diff_text"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  # Verify we're in a git repo
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    die "Not inside a git repository."
  fi

  parse_args "$@"

  # Auto-detect the base branch unless --base was given
  if [[ "$MODE" == "branch" ]]; then
    BASE_BRANCH=$(resolve_base_branch "$BASE_BRANCH")
  fi

  # Describe what we're reviewing
  case "$MODE" in
    uncommitted) info "Reviewing: uncommitted changes vs HEAD (including untracked files)" ;;
    branch)      info "Reviewing: branch '${TARGET}' vs '${BASE_BRANCH}'" ;;
    commit)      info "Reviewing: commit range '${TARGET}'" ;;
  esac

  local diff_text
  diff_text=$(get_diff)

  # Validate non-empty
  if [[ -z "$diff_text" ]]; then
    info "No changes found. Nothing to review."
    exit 1
  fi

  # Print stats to stderr
  print_stats "$diff_text"

  # Output the diff to stdout (unless stat-only)
  if [[ "$STAT_ONLY" != "true" ]]; then
    echo "$diff_text"
  fi
}

main "$@"
