#!/usr/bin/env bash
# archeflow-gnap.sh — GNAP (Git-Native Agent Protocol) compatibility layer.
#
# Syncs between ArcheFlow's queue.json and the GNAP .gnap/ directory format,
# enabling interoperability with any GNAP-compatible agent (OpenClaw, Codex,
# Claude Code, custom bots). Any agent that can `git push` can participate.
#
# Usage:
#   ./lib/archeflow-gnap.sh init                      # Create .gnap/ from ArcheFlow state
#   ./lib/archeflow-gnap.sh export [--queue <path>]   # Export queue.json → .gnap/tasks/
#   ./lib/archeflow-gnap.sh import                    # Import .gnap/tasks/ → queue.json
#
# Trust: .gnap/ is written by any agent that can push to the repository, so an
# import never changes existing queue items and never imports work as runnable.
# New tasks land with status "proposed" and source "gnap"; a sprint must not
# dispatch "proposed" items without the user's explicit approval.
#   ./lib/archeflow-gnap.sh sync                      # Bidirectional sync
#   ./lib/archeflow-gnap.sh status                    # Show GNAP state
#
# Dependencies: jq, bash 4+
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/archeflow-common.sh
source "${SCRIPT_DIR}/archeflow-common.sh"
# Refuse a symlinked .archeflow/ (or events/, runs/, memory/ ...): writes would land outside the repo.
af_check_state_dirs
GNAP_DIR=".gnap"
QUEUE_FILE="docs/orchestra/queue.json"
ARCHEFLOW_DIR=".archeflow"

# --- Helpers ---

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

ensure_gnap() {
  mkdir -p "${GNAP_DIR}/tasks" "${GNAP_DIR}/runs" "${GNAP_DIR}/messages"
}

# Map ArcheFlow priority to GNAP integer (0 = highest)
priority_to_int() {
  case "$1" in
    P0) echo 0 ;;
    P1) echo 1 ;;
    P2) echo 2 ;;
    P3) echo 3 ;;
    *)  echo 5 ;;
  esac
}

# Map GNAP integer priority back to ArcheFlow
int_to_priority() {
  case "$1" in
    0) echo "P0" ;;
    1) echo "P1" ;;
    2) echo "P2" ;;
    3) echo "P3" ;;
    *) echo "P3" ;;
  esac
}

# Map ArcheFlow status to GNAP state
status_to_state() {
  case "$1" in
    pending)    echo "ready" ;;
    running)    echo "in_progress" ;;
    completed)  echo "done" ;;
    blocked)    echo "blocked" ;;
    failed)     echo "blocked" ;;   # GNAP has no "failed"; never re-queue it as backlog
    cancelled)  echo "cancelled" ;;
    *)          echo "backlog" ;;
  esac
}

# --- Commands ---

cmd_init() {
  ensure_gnap

  # Write protocol version
  af_refuse_symlink "${GNAP_DIR}/version" || exit 1
  af_refuse_symlink "${GNAP_DIR}/agents.json" || exit 1
  echo "4" > "${GNAP_DIR}/version"

  # Generate agents.json from ArcheFlow archetypes + queue routing
  local agents="[]"

  # Add ArcheFlow archetypes as AI agents
  for agent_file in "${SCRIPT_DIR}/../agents/"*.md; do
    [[ -f "$agent_file" ]] || continue
    local name
    name=$(awk '/^---$/{n++; next} n==1 && /name:/{print $2; exit}' "$agent_file")
    [[ -z "$name" ]] && continue

    agents=$(echo "$agents" | jq --arg id "archeflow-${name}" --arg name "$name" \
      '. + [{
        id: $id,
        name: ("ArcheFlow " + $name),
        role: $name,
        type: "ai",
        status: "active",
        runtime: "archeflow",
        capabilities: ["code-review", "implementation", "analysis"]
      }]')
  done

  # Add agent entries from queue routing
  if [[ -f "$QUEUE_FILE" ]]; then
    local queue_agents
    queue_agents=$(jq -r '.items[].agent // empty' "$QUEUE_FILE" 2>/dev/null | sort -u)
    while IFS= read -r agent_id; do
      [[ -z "$agent_id" ]] && continue
      local agent_type="ai"
      [[ "$agent_id" == *"cursor"* ]] && agent_type="ai"
      agents=$(echo "$agents" | jq --arg id "$agent_id" --arg type "$agent_type" \
        'if any(.[]; .id == $id) then . else . + [{
          id: $id,
          name: $id,
          role: "executor",
          type: $type,
          status: "active",
          runtime: $id
        }] end')
    done <<< "$queue_agents"
  fi

  echo "$agents" | jq '{agents: .}' > "${GNAP_DIR}/agents.json"

  # Export existing queue items as tasks
  if [[ -f "$QUEUE_FILE" ]]; then
    cmd_export
  fi

  echo "[archeflow-gnap] Initialized .gnap/ directory" >&2
  echo "[archeflow-gnap]   agents: $(echo "$agents" | jq length)" >&2
  echo "[archeflow-gnap]   tasks:  $(ls -1 "${GNAP_DIR}/tasks/" 2>/dev/null | wc -l | tr -d ' ')" >&2
}

cmd_export() {
  local queue="${QUEUE_FILE}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --queue) queue="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ ! -f "$queue" ]]; then
    echo "Error: queue file not found: $queue" >&2
    exit 1
  fi

  ensure_gnap

  local count=0
  local ts
  ts=$(now_ts)

  # Export each queue item as a GNAP task
  while IFS= read -r item; do
    local id title assigned state priority project notes deps
    id=$(echo "$item" | jq -r '.id // ""')
    [[ -n "$id" && "$id" != "null" ]] || continue
    title=$(echo "$item" | jq -r '.task')
    assigned=$(echo "$item" | jq -r '.agent // "unassigned"')
    state=$(status_to_state "$(echo "$item" | jq -r '.status')")
    priority=$(priority_to_int "$(echo "$item" | jq -r '.priority')")
    project=$(echo "$item" | jq -r '.project // ""')
    notes=$(echo "$item" | jq -r '.notes // ""')
    deps=$(echo "$item" | jq -c '.depends_on // [] | if type == "array" then . else [] end')

    local task
    task=$(jq -cn \
      --arg id "$id" \
      --arg title "$title" \
      --arg assigned "$assigned" \
      --arg state "$state" \
      --argjson priority "$priority" \
      --arg project "$project" \
      --arg notes "$notes" \
      --arg ts "$ts" \
      --argjson deps "$deps" \
      '{
        id: $id,
        title: $title,
        assigned_to: [$assigned],
        state: $state,
        priority: $priority,
        created_by: "archeflow",
        created_at: $ts,
        tags: (if $project != "" then [$project] else [] end),
        desc: $notes,
        metadata: {
          source: "archeflow-queue",
          project: $project,
          depends_on: $deps
        }
      }')

    # Sanitize filename: ids are data, so keep only a safe charset and never
    # allow a leading dot (no "..", no hidden files, no path separators).
    local safe_id
    safe_id=$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[.-]*//')
    [[ -n "$safe_id" ]] || continue
    local out="${GNAP_DIR}/tasks/${safe_id}.json"
    af_refuse_symlink "$out" || continue
    echo "$task" | jq '.' > "$out"
    count=$((count + 1))
  done < <(jq -c '.items[]?' "$queue" 2>/dev/null)

  echo "[archeflow-gnap] Exported ${count} tasks to .gnap/tasks/" >&2
}

cmd_import() {
  if [[ ! -d "${GNAP_DIR}/tasks" ]]; then
    echo "Error: no .gnap/tasks/ directory found" >&2
    exit 1
  fi

  if [[ ! -f "$QUEUE_FILE" ]]; then
    echo "Error: queue file not found: $QUEUE_FILE" >&2
    exit 1
  fi

  local imported=0
  local skipped=0

  for task_file in "${GNAP_DIR}/tasks/"*.json; do
    [[ -f "$task_file" && ! -L "$task_file" ]] || continue
    jq -e 'type == "object"' "$task_file" >/dev/null 2>&1 || { skipped=$((skipped + 1)); continue; }

    local id title assigned state priority project notes source
    id=$(jq -r '.id // "" | tostring' "$task_file")
    [[ -n "$id" && "$id" != "null" ]] || { skipped=$((skipped + 1)); continue; }

    # Existing items are never modified by an import: GNAP files are written by
    # other agents and must not be able to flip a queue item to ready/running.
    if jq -e --arg id "$id" '(.items // []) | any(.id == $id)' "$QUEUE_FILE" >/dev/null; then
      skipped=$((skipped + 1))
      continue
    fi

    # Only import tasks not created by archeflow (avoid duplicates on round-trip)
    source=$(jq -r '.metadata.source // ""' "$task_file")
    if [[ "$source" == "archeflow-queue" ]]; then
      continue
    fi

    title=$(jq -r '.title // "" | tostring' "$task_file")
    assigned=$(jq -r '.assigned_to[0]? // "claude-code" | tostring' "$task_file")
    state=$(jq -r '.state // "" | tostring' "$task_file")
    priority=$(jq -r '.priority // 3 | tostring' "$task_file")
    project=$(jq -r '(.metadata.project // .tags[0]? // "") | tostring' "$task_file")
    notes=$(jq -r '.desc // "" | tostring' "$task_file")

    local af_priority
    af_priority=$(int_to_priority "$priority")

    local new_item
    new_item=$(jq -cn \
      --arg id "$id" \
      --arg priority "$af_priority" \
      --arg project "$project" \
      --arg task "$title" \
      --arg agent "$assigned" \
      --arg gnap_state "$state" \
      --arg notes "$notes" \
      '{
        id: $id,
        priority: $priority,
        project: $project,
        task: $task,
        estimate: "M",
        agent: $agent,
        depends_on: [],
        status: "proposed",
        source: "gnap",
        gnap_state: $gnap_state,
        notes: ($notes + " [imported from GNAP; needs user approval before dispatch]")
      }')

    local tmp; tmp=$(af_tmpfile "$QUEUE_FILE")
    jq --argjson item "$new_item" '.items = ((.items // []) + [$item])' "$QUEUE_FILE" > "$tmp"
    mv "$tmp" "$QUEUE_FILE"
    imported=$((imported + 1))
  done

  echo "[archeflow-gnap] Import complete: $imported new (status proposed), $skipped skipped (existing or invalid)" >&2
}

cmd_sync() {
  echo "[archeflow-gnap] Bidirectional sync..." >&2

  # Step 1: Import any new GNAP tasks into queue
  if [[ -d "${GNAP_DIR}/tasks" ]]; then
    cmd_import
  fi

  # Step 2: Export current queue state back to GNAP
  cmd_export

  echo "[archeflow-gnap] Sync complete" >&2
}

cmd_status() {
  if [[ ! -d "$GNAP_DIR" ]]; then
    echo "No .gnap/ directory. Run '$0 init' first." >&2
    return 1
  fi

  local version="?"
  [[ -f "${GNAP_DIR}/version" ]] && version=$(cat "${GNAP_DIR}/version")

  local agent_count=0
  [[ -f "${GNAP_DIR}/agents.json" ]] && agent_count=$(jq '.agents | length' "${GNAP_DIR}/agents.json")

  local task_count=0
  task_count=$(ls -1 "${GNAP_DIR}/tasks/" 2>/dev/null | wc -l | tr -d ' ')

  local run_count=0
  run_count=$(ls -1 "${GNAP_DIR}/runs/" 2>/dev/null | wc -l | tr -d ' ')

  local msg_count=0
  msg_count=$(ls -1 "${GNAP_DIR}/messages/" 2>/dev/null | wc -l | tr -d ' ')

  echo "GNAP Status"
  echo "==========="
  echo "Protocol version: $version"
  echo "Agents:           $agent_count"
  echo "Tasks:            $task_count"
  echo "Runs:             $run_count"
  echo "Messages:         $msg_count"
  echo ""

  if [[ "$task_count" -gt 0 ]]; then
    echo "Tasks by state:"
    for task_file in "${GNAP_DIR}/tasks/"*.json; do
      [[ -f "$task_file" ]] || continue
      jq -r '.state' "$task_file"
    done | sort | uniq -c | sort -rn | while read -r count state; do
      printf "  %-15s %s\n" "$state" "$count"
    done
  fi
}

# --- Main ---

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <command> [args...]" >&2
  echo "" >&2
  echo "Commands:" >&2
  echo "  init                     Create .gnap/ from ArcheFlow state" >&2
  echo "  export [--queue <path>]  Export queue.json → .gnap/tasks/" >&2
  echo "  import                   Import .gnap/tasks/ → queue.json" >&2
  echo "  sync                     Bidirectional sync" >&2
  echo "  status                   Show GNAP state" >&2
  exit 1
fi


# Serialize mutating commands: concurrent read-modify-write of QUEUE_FILE from
# parallel agents would otherwise lose updates.
# shellcheck source=lib/archeflow-lock.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archeflow-lock.sh"
# The lock lives under .archeflow/ (usually gitignored), not next to the
# workspace's committed queue.json.
_af_serialize() {
  mkdir -p "${ARCHEFLOW_DIR}/locks"
  af_lock "${ARCHEFLOW_DIR}/locks/gnap-queue.lock" 30 || { echo "Error: could not lock $QUEUE_FILE" >&2; exit 1; }
  trap 'af_unlock "${ARCHEFLOW_DIR}/locks/gnap-queue.lock"' EXIT
}

COMMAND="$1"
shift

case "$COMMAND" in
  init|import|sync) _af_serialize ;;
esac

case "$COMMAND" in
  init)   cmd_init "$@" ;;
  export) cmd_export "$@" ;;
  import) cmd_import "$@" ;;
  sync)   cmd_sync "$@" ;;
  status) cmd_status "$@" ;;
  *)      echo "Unknown command: $COMMAND" >&2; exit 1 ;;
esac
