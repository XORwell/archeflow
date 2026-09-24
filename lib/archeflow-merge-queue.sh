#!/usr/bin/env bash
# archeflow-merge-queue.sh — Merge queue for parallel worktree agents.
#
# When multiple agents work in parallel (via /af-sprint), each operates in its
# own git worktree or branch. This script manages the merge queue: detects
# conflicts between completed agent branches, orders merges by dependency,
# and handles conflict resolution.
#
# Inspired by Gas Town's "Refinery" pattern (Steve Yegge, 2026).
#
# Usage:
#   ./lib/archeflow-merge-queue.sh enqueue <branch> [--priority <N>]  # Add branch to merge queue
#   ./lib/archeflow-merge-queue.sh status                              # Show queue state
#   ./lib/archeflow-merge-queue.sh check [<branch>]                    # Check for conflicts
#   ./lib/archeflow-merge-queue.sh merge [--strategy <squash|no-ff>]   # Process queue
#   ./lib/archeflow-merge-queue.sh drain                               # Merge everything possible
#   ./lib/archeflow-merge-queue.sh reset                               # Clear the queue
#
# Dependencies: jq, git, bash 4+
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq required" >&2; exit 1; }

AF_LOG_PREFIX="merge-queue"
# shellcheck source=lib/archeflow-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archeflow-common.sh"

MERGE_QUEUE_DIR=".archeflow/merge-queue"
QUEUE_FILE="${MERGE_QUEUE_DIR}/queue.jsonl"
CONFLICT_LOG="${MERGE_QUEUE_DIR}/conflicts.jsonl"
MERGE_LOG="${MERGE_QUEUE_DIR}/merged.jsonl"

# --- Helpers ---

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

ensure_dir() { mkdir -p "$MERGE_QUEUE_DIR"; }

info() { echo "[merge-queue] $*" >&2; }

get_base_branch() {
  git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || \
  git branch --show-current 2>/dev/null || echo "main"
}

# Branch names are read back from queue.jsonl (data). A name starting with "-"
# would be parsed as a git option, so reject it on the way in and on the way out;
# git calls also pass --end-of-options before any data-derived ref.
valid_branch() {
  local b="$1"
  [[ -n "$b" && "$b" != -* ]] && git check-ref-format --branch "$b" >/dev/null 2>&1
}

# Get files changed by a branch relative to base
branch_files() {
  local branch="$1"
  local base="${2:-$(get_base_branch)}"
  git diff --name-only --end-of-options "${base}...${branch}" 2>/dev/null || true
}

# Check if two branches touch overlapping files
branches_conflict() {
  local branch_a="$1"
  local branch_b="$2"
  local base="${3:-$(get_base_branch)}"

  local files_a files_b
  files_a=$(branch_files "$branch_a" "$base")
  files_b=$(branch_files "$branch_b" "$base")

  if [[ -z "$files_a" || -z "$files_b" ]]; then
    echo "false"
    return
  fi

  local overlap
  overlap=$(comm -12 <(echo "$files_a" | sort) <(echo "$files_b" | sort))

  if [[ -n "$overlap" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# Get overlapping files between two branches
get_overlap_files() {
  local branch_a="$1"
  local branch_b="$2"
  local base="${3:-$(get_base_branch)}"

  local files_a files_b
  files_a=$(branch_files "$branch_a" "$base")
  files_b=$(branch_files "$branch_b" "$base")

  comm -12 <(echo "$files_a" | sort) <(echo "$files_b" | sort)
}

# --- Commands ---

cmd_enqueue() {
  local branch=""
  local priority=5
  local run_id=""
  local project=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority) priority="$2"; shift 2 ;;
      --run-id)   run_id="$2"; shift 2 ;;
      --project)  project="$2"; shift 2 ;;
      *)          branch="$1"; shift ;;
    esac
  done

  [[ -z "$branch" ]] && die "Usage: $0 enqueue <branch> [--priority N] [--run-id ID] [--project NAME]"
  valid_branch "$branch" || die "Invalid branch name: '${branch}'"
  af_is_int "$priority" || die "--priority must be an integer, got '${priority}'"
  priority=$(af_as_int "$priority")

  # Verify branch exists
  if ! git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
    die "Branch '${branch}' does not exist"
  fi

  ensure_dir

  # Check if already in queue
  if [[ -f "$QUEUE_FILE" ]] && jq -e --arg b "$branch" 'select(.branch == $b)' "$QUEUE_FILE" > /dev/null 2>&1; then
    info "Branch '${branch}' already in queue — updating priority"
    local tmp; tmp=$(af_tmpfile "$QUEUE_FILE")
    jq -c --arg b "$branch" --argjson p "$priority" \
      'if .branch == $b then .priority = $p else . end' "$QUEUE_FILE" > "$tmp"
    mv "$tmp" "$QUEUE_FILE"
    return 0
  fi

  local base
  base=$(get_base_branch)
  local files_changed
  files_changed=$(branch_files "$branch" "$base" | wc -l | tr -d ' ')
  local commits
  commits=$(af_as_int "$(git rev-list --count --end-of-options "${base}..${branch}" 2>/dev/null || echo 0)")

  af_append "$QUEUE_FILE" "$(jq -cn \
    --arg branch "$branch" \
    --argjson priority "$priority" \
    --arg run_id "$run_id" \
    --arg project "$project" \
    --arg ts "$(now_ts)" \
    --argjson files "$files_changed" \
    --argjson commits "$commits" \
    '{
      branch: $branch,
      priority: $priority,
      run_id: $run_id,
      project: $project,
      state: "pending",
      enqueued_at: $ts,
      files_changed: $files,
      commits: $commits,
      conflicts_with: []
    }')"

  info "Enqueued: ${branch} (priority=${priority}, ${files_changed} files, ${commits} commits)"
}

cmd_status() {
  if [[ ! -f "$QUEUE_FILE" ]]; then
    echo "Merge queue is empty." >&2
    return 0
  fi

  local base
  base=$(get_base_branch)

  echo "Merge Queue (base: ${base})"
  echo "============================="
  echo ""

  printf "%-4s %-40s %-10s %-6s %-6s %s\n" "PRI" "BRANCH" "STATE" "FILES" "CMTS" "CONFLICTS"
  printf "%-4s %-40s %-10s %-6s %-6s %s\n" "---" "------" "-----" "-----" "----" "---------"

  jq -r '[.priority, .branch, .state, (.files_changed|tostring), (.commits|tostring), (.conflicts_with|join(","))] | @tsv' "$QUEUE_FILE" \
    | sort -t$'\t' -k1 -n \
    | while IFS=$'\t' read -r pri branch state files commits conflicts; do
        printf "%-4s %-40s %-10s %-6s %-6s %s\n" "$pri" "$branch" "$state" "$files" "$commits" "${conflicts:--}"
      done

  echo ""

  # Summary
  local total pending ready blocked merged
  total=$(jq -sc 'length' "$QUEUE_FILE")
  pending=$(jq -sc '[.[] | select(.state == "pending")] | length' "$QUEUE_FILE")
  ready=$(jq -sc '[.[] | select(.state == "ready")] | length' "$QUEUE_FILE")
  blocked=$(jq -sc '[.[] | select(.state == "blocked")] | length' "$QUEUE_FILE")
  merged=$(jq -sc '[.[] | select(.state == "merged")] | length' "$QUEUE_FILE")
  echo "Total: ${total} | Pending: ${pending} | Ready: ${ready} | Blocked: ${blocked} | Merged: ${merged}"
}

cmd_check() {
  local target_branch="${1:-}"

  if [[ ! -f "$QUEUE_FILE" ]]; then
    echo "Queue is empty, nothing to check." >&2
    return 0
  fi

  ensure_dir
  local base
  base=$(get_base_branch)

  local branches=()
  while IFS= read -r branch; do
    [[ -n "$branch" ]] && branches+=("$branch")
  done < <(jq -r 'select(.state != "merged") | .branch' "$QUEUE_FILE" 2>/dev/null)

  local conflicts_found=0

  if [[ -n "$target_branch" ]]; then
    # Check specific branch against all others
    for other in "${branches[@]}"; do
      [[ "$other" == "$target_branch" ]] && continue

      if [[ "$(branches_conflict "$target_branch" "$other" "$base")" == "true" ]]; then
        local overlap
        overlap=$(get_overlap_files "$target_branch" "$other" "$base")
        echo "CONFLICT: ${target_branch} <-> ${other}"
        echo "  Files: $(echo "$overlap" | tr '\n' ', ' | sed 's/,$//')"
        conflicts_found=$((conflicts_found + 1))

        af_append "$CONFLICT_LOG" "$(jq -cn \
          --arg a "$target_branch" --arg b "$other" \
          --arg ts "$(now_ts)" --arg files "$overlap" \
          '{ts:$ts, branch_a:$a, branch_b:$b, files:($files|split("\n"))}')" || true
      fi
    done
  else
    # Check all pairs
    local n=${#branches[@]}
    for ((i=0; i<n; i++)); do
      for ((j=i+1; j<n; j++)); do
        local a="${branches[$i]}" b="${branches[$j]}"

        if [[ "$(branches_conflict "$a" "$b" "$base")" == "true" ]]; then
          local overlap
          overlap=$(get_overlap_files "$a" "$b" "$base")
          echo "CONFLICT: ${a} <-> ${b}"
          echo "  Files: $(echo "$overlap" | tr '\n' ', ' | sed 's/,$//')"
          conflicts_found=$((conflicts_found + 1))

          # Update queue entries with conflict info
          local tmp; tmp=$(af_tmpfile "$QUEUE_FILE")
          jq -c --arg a "$a" --arg b "$b" \
            'if .branch == $a then .conflicts_with += [$b] | .conflicts_with |= unique
             elif .branch == $b then .conflicts_with += [$a] | .conflicts_with |= unique
             else . end' "$QUEUE_FILE" > "$tmp"
          mv "$tmp" "$QUEUE_FILE"

          af_append "$CONFLICT_LOG" "$(jq -cn \
            --arg a "$a" --arg b "$b" \
            --arg ts "$(now_ts)" --arg files "$overlap" \
            '{ts:$ts, branch_a:$a, branch_b:$b, files:($files|split("\n"))}')" || true
        fi
      done
    done
  fi

  # Mark non-conflicting branches as ready
  local tmp; tmp=$(af_tmpfile "$QUEUE_FILE")
  jq -c 'if (.conflicts_with | length) == 0 and .state == "pending" then .state = "ready" else . end' "$QUEUE_FILE" > "$tmp"
  mv "$tmp" "$QUEUE_FILE"

  # Mark conflicting branches as blocked
  tmp=$(af_tmpfile "$QUEUE_FILE")
  jq -c 'if (.conflicts_with | length) > 0 and .state == "pending" then .state = "blocked" else . end' "$QUEUE_FILE" > "$tmp"
  mv "$tmp" "$QUEUE_FILE"

  if [[ "$conflicts_found" -eq 0 ]]; then
    info "No conflicts detected. All branches are safe to merge."
  else
    info "${conflicts_found} conflict(s) detected. Blocked branches need manual resolution or sequential merge."
  fi

  return $(( conflicts_found > 255 ? 255 : conflicts_found ))
}

cmd_merge() {
  local strategy="squash"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strategy) [[ $# -ge 2 ]] || die "--strategy requires a value"; strategy="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Validate up front: an unknown strategy used to fall through the case below
  # with merge_ok=true, so branches were marked "merged" without being merged.
  case "$strategy" in
    squash|no-ff) ;;
    *) die "Unknown merge strategy: '${strategy}' (use squash or no-ff)" ;;
  esac

  if [[ ! -f "$QUEUE_FILE" ]]; then
    info "Queue is empty."
    return 0
  fi

  # Run conflict check first
  cmd_check > /dev/null 2>&1 || true

  local base
  base=$(get_base_branch)

  # Ensure we're on the base branch
  local current
  current=$(git branch --show-current 2>/dev/null || true)
  if [[ "$current" != "$base" ]]; then
    valid_branch "$base" || die "Invalid base branch: '${base}'"
    if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
      git checkout --quiet "$base" --  # git 2.43 checkout treats --end-of-options as a pathspec
    else
      die "Not on base branch '${base}' and have uncommitted changes. Commit or stash first."
    fi
  fi

  local merged=0
  local failed=0

  # Process ready branches in priority order. The loop reads from a process
  # substitution, not a pipe, so the counters survive (they used to be
  # incremented in a subshell and the summary always said 0).
  local entry branch merge_ok tmp
  while IFS= read -r entry; do
    branch=$(echo "$entry" | jq -r '.branch // ""')

    if ! valid_branch "$branch"; then
      info "Skipping invalid branch name in queue: '${branch}'"
      continue
    fi

    info "Merging: ${branch}..."

    # Verify branch still exists
    if ! git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
      info "Branch '${branch}' no longer exists — skipping"
      continue
    fi

    # Try the merge
    merge_ok=true
    case "$strategy" in
      squash)
        if git merge --squash --quiet --end-of-options "$branch" >/dev/null 2>&1; then
          if ! git diff --cached --quiet 2>/dev/null; then
            git commit -m "feat: merge ${branch}" --quiet 2>/dev/null || merge_ok=false
          fi
        else
          merge_ok=false
        fi
        # A failed squash leaves no MERGE_HEAD, so "merge --abort" cannot undo
        # it; reset the index and work tree back to HEAD instead.
        [[ "$merge_ok" == "true" ]] || git reset --merge --quiet 2>/dev/null || true
        ;;
      no-ff)
        if ! git merge --no-ff --quiet -m "feat: merge ${branch}" --end-of-options "$branch" >/dev/null 2>&1; then
          merge_ok=false
          git merge --abort 2>/dev/null || true
        fi
        ;;
    esac

    if [[ "$merge_ok" == "true" ]]; then
      info "Merged: ${branch}"

      # Log the merge
      af_append "$MERGE_LOG" "$(jq -cn \
        --arg branch "$branch" \
        --arg ts "$(now_ts)" \
        --arg strategy "$strategy" \
        '{branch:$branch, merged_at:$ts, strategy:$strategy, result:"success"}')" || true

      # Update queue entry
      tmp=$(af_tmpfile "$QUEUE_FILE")
      jq -c --arg b "$branch" \
        'if .branch == $b then .state = "merged" else . end' "$QUEUE_FILE" > "$tmp"
      mv "$tmp" "$QUEUE_FILE"

      merged=$((merged + 1))

      # Re-check remaining branches (base has moved forward)
      cmd_check > /dev/null 2>&1 || true
    else
      info "FAILED to merge: ${branch} — conflicts detected"

      af_append "$CONFLICT_LOG" "$(jq -cn \
        --arg branch "$branch" \
        --arg ts "$(now_ts)" \
        '{branch:$branch, ts:$ts, result:"conflict"}')" || true

      tmp=$(af_tmpfile "$QUEUE_FILE")
      jq -c --arg b "$branch" \
        'if .branch == $b then .state = "blocked" else . end' "$QUEUE_FILE" > "$tmp"
      mv "$tmp" "$QUEUE_FILE"

      failed=$((failed + 1))
    fi
  done < <(jq -c 'select(.state == "ready")' "$QUEUE_FILE" 2>/dev/null | jq -sc 'sort_by(.priority)[]')

  info "Merge run complete: ${merged} merged, ${failed} failed"
}

cmd_drain() {
  info "Draining merge queue..."

  local max_rounds=10
  local round=0

  while [[ "$round" -lt "$max_rounds" ]]; do
    round=$((round + 1))

    # Check if there are any pending/ready items
    local remaining
    remaining=$(jq -c 'select(.state == "pending" or .state == "ready")' "$QUEUE_FILE" 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$remaining" -eq 0 ]]; then
      info "Queue drained (round ${round})"
      break
    fi

    info "Round ${round}: ${remaining} items remaining"
    cmd_check > /dev/null 2>&1 || true
    cmd_merge
  done

  cmd_status
}

cmd_reset() {
  ensure_dir
  : > "$QUEUE_FILE" 2>/dev/null || true
  info "Merge queue cleared"
}

# --- Main ---

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <command> [args...]" >&2
  echo "" >&2
  echo "Commands:" >&2
  echo "  enqueue <branch> [--priority N]   Add branch to merge queue" >&2
  echo "  status                            Show queue state" >&2
  echo "  check [<branch>]                  Detect conflicts between queued branches" >&2
  echo "  merge [--strategy squash|no-ff]   Process the queue (merge ready branches)" >&2
  echo "  drain                             Merge everything possible" >&2
  echo "  reset                             Clear the queue" >&2
  exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
  enqueue) cmd_enqueue "$@" ;;
  status)  cmd_status ;;
  check)   cmd_check "$@" ;;
  merge)   cmd_merge "$@" ;;
  drain)   cmd_drain ;;
  reset)   cmd_reset ;;
  *)       echo "Unknown command: $COMMAND" >&2; exit 1 ;;
esac
