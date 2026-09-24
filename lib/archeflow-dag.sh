#!/usr/bin/env bash
# archeflow-dag.sh — Render an ASCII DAG from ArcheFlow JSONL events.
#
# Usage: ./lib/archeflow-dag.sh <events.jsonl> [--color] [--no-color]
#
# Reads a JSONL event file and renders the causal DAG as ASCII art.
# Each event shows: #seq  description (phase) [metadata]
# Tree drawing uses Unicode box-drawing characters for branches.
#
# The rendering uses a "logical grouping" strategy: phase transitions and
# structural events appear as top-level siblings under root, with agents
# and sub-events nested beneath their phase section. This gives a readable
# timeline view while preserving DAG relationships.
#
# Requires: jq
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <events.jsonl> [--color] [--no-color]" >&2
  exit 1
fi

EVENT_FILE="$1"
shift

if ! command -v jq &> /dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

if [[ ! -f "$EVENT_FILE" ]]; then
  echo "Error: Event file not found: $EVENT_FILE" >&2
  exit 1
fi

# Color support: auto-detect terminal, allow override
USE_COLOR=auto
for arg in "$@"; do
  case "$arg" in
    --color) USE_COLOR=yes ;;
    --no-color) USE_COLOR=no ;;
  esac
done

if [[ "$USE_COLOR" == "auto" ]]; then
  if [[ -t 1 ]]; then
    USE_COLOR=yes
  else
    USE_COLOR=no
  fi
fi

# ANSI color codes
if [[ "$USE_COLOR" == "yes" ]]; then
  C_RESET="\033[0m"
  C_SEQ="\033[1;37m"       # bold white for seq numbers
  C_PLAN="\033[1;34m"      # blue for plan phase
  C_DO="\033[1;32m"        # green for do phase
  C_CHECK="\033[1;33m"     # yellow for check phase
  C_ACT="\033[1;35m"       # magenta for act phase
  C_TRANS="\033[0;36m"     # cyan for phase transitions
  C_DIM="\033[0;90m"       # dim for metadata
  C_DECISION="\033[1;33m"  # yellow for decisions
  C_VERDICT="\033[1;31m"   # red for verdicts
else
  C_RESET="" C_SEQ="" C_PLAN="" C_DO="" C_CHECK="" C_ACT=""
  C_TRANS="" C_DIM="" C_DECISION="" C_VERDICT=""
fi

phase_color() {
  case "$1" in
    plan)  printf "%s" "$C_PLAN" ;;
    do)    printf "%s" "$C_DO" ;;
    check) printf "%s" "$C_CHECK" ;;
    act)   printf "%s" "$C_ACT" ;;
    *)     printf "%s" "$C_RESET" ;;
  esac
}

# Pre-process all events with jq into a structured format for bash consumption.
# Output: seq|type|phase|agent|parents_csv|label
# This avoids calling jq per-event in a loop.
EVENTS_PARSED=$(jq -r '
  def mklabel:
    if .type == "run.start" then "run.start"
    elif .type == "agent.complete" then
      (.data.archetype // .agent // "unknown") + " (" + .phase + ")" +
      (if (.data.tokens // 0) > 0 then " [" + (.data.tokens | tostring) + " tok]" else "" end)
    elif .type == "decision.point" then
      (.data.archetype // .agent // "?") + " → " + (.data.decision // "?") +
      " (conf " + ((.data.confidence // 0) | tostring) + ")"
    elif .type == "decision" then
      "decision: " + (.data.what // "unknown") + " → " + (.data.chosen // "unknown")
    elif .type == "phase.transition" then
      "─── " + (.data.from // "?") + " → " + (.data.to // "?") + " ───"
    elif .type == "review.verdict" then
      (.data.archetype // .agent // "unknown") + " (" + .phase + ") → " +
      ((.data.verdict // "unknown") | ascii_upcase | gsub("_"; " "))
    elif .type == "fix.applied" then
      "fix (" + (.data.source // "unknown") + "): " + (.data.finding // "unknown")
    elif .type == "cycle.boundary" then
      "cycle " + ((.data.cycle // 0) | tostring) + "/" + ((.data.max_cycles // 0) | tostring) +
      " → " + (.data.next_action // "continue")
    elif .type == "shadow.detected" then
      "shadow: " + (.data.archetype // "unknown") + " — " + (.data.shadow // "unknown")
    elif .type == "run.complete" then
      "run.complete [" + ((.data.agents_total // .data.agents // 0) | tostring) +
      " agents, " + ((.data.fixes_total // .data.fixes // 0) | tostring) + " fixes]"
    else .type
    end;
  # Event files may come from the repository, so only well-formed events are
  # rendered: seq and parents must be non-negative integers (they are used as
  # array keys and compared numerically below, and bash evaluates such values
  # as arithmetic expressions). Strings are stripped of the field separator
  # and newlines so one event is always one line.
  def clean: tostring | gsub("[\u001f\n\r]"; " ");
  def isint: type == "number" and . >= 0 and . == floor and . < 1e15;
  select(type == "object" and (.seq | isint))
  | [(.seq | tostring), (.type // "" | clean), (.phase // "" | clean),
     ((.agent // "_NONE_") | clean),
     ((((.parent // []) | if type == "array" then . else [] end | map(select(isint) | tostring) | join(","))
       | if . == "" then "_NONE_" else . end)),
     ((try mklabel catch (.type // "?")) | clean)]
  | join("\u001f")  # ASCII unit separator: single byte, locale-independent
' "$EVENT_FILE")

# Parse into arrays
declare -A EVENT_TYPE EVENT_PHASE EVENT_LABEL EVENT_PARENTS
declare -A CHILDREN_OF  # parent_seq -> space-separated child seqs

while IFS=$'\x1f' read -r seq type phase agent parents label; do
  [[ "$seq" =~ ^[0-9]+$ ]] || continue  # empty input / defensive: jq already filtered
  [[ "$agent" == "_NONE_" ]] && agent=""
  [[ "$parents" == "_NONE_" ]] && parents=""
  EVENT_TYPE[$seq]="$type"
  EVENT_PHASE[$seq]="$phase"
  EVENT_LABEL[$seq]="$label"
  EVENT_PARENTS[$seq]="$parents"

  # Register parent-child relationships
  if [[ -z "$parents" ]]; then
    CHILDREN_OF[0]="${CHILDREN_OF[0]:-} $seq"
  else
    IFS=',' read -ra parent_arr <<< "$parents"
    for p in "${parent_arr[@]}"; do
      CHILDREN_OF[$p]="${CHILDREN_OF[$p]:-} $seq"
    done
  fi

done <<< "$EVENTS_PARSED"

# Sort and deduplicate children
for key in "${!CHILDREN_OF[@]}"; do
  CHILDREN_OF[$key]=$(echo "${CHILDREN_OF[$key]}" | tr ' ' '\n' | sort -un | tr '\n' ' ' | xargs)
done

# Determine display parent for each event.
# Strategy: structural events (phase.transition, cycle.boundary, run.complete) are promoted
# to be direct children of #1 (run.start), creating a flat timeline backbone.
# All other events use their first (lowest-numbered) parent for display.
declare -A DISPLAY_PARENT  # seq -> parent seq for display (0 = root)
declare -A DISPLAY_CHILDREN  # parent -> ordered children for display

for seq_i in $(printf '%s\n' "${!EVENT_TYPE[@]}" | sort -n); do
  local_type="${EVENT_TYPE[$seq_i]}"
  parents_csv="${EVENT_PARENTS[$seq_i]:-}"

  if [[ -z "$parents_csv" ]]; then
    # Root event (run.start)
    DISPLAY_PARENT[$seq_i]=0
  elif [[ "$local_type" == "phase.transition" || "$local_type" == "cycle.boundary" || "$local_type" == "run.complete" ]]; then
    # Promote structural events to be children of run.start (#1)
    DISPLAY_PARENT[$seq_i]=1
  else
    # Use first (lowest) parent as display parent
    IFS=',' read -ra parr <<< "$parents_csv"
    DISPLAY_PARENT[$seq_i]="${parr[0]}"
  fi

  dp="${DISPLAY_PARENT[$seq_i]}"
  DISPLAY_CHILDREN[$dp]="${DISPLAY_CHILDREN[$dp]:-} $seq_i"
done

# Sort display children
for key in "${!DISPLAY_CHILDREN[@]}"; do
  DISPLAY_CHILDREN[$key]=$(echo "${DISPLAY_CHILDREN[$key]}" | tr ' ' '\n' | sort -n | tr '\n' ' ' | xargs)
done

# Render the tree recursively using display hierarchy
render_node() {
  local seq="$1"
  local prefix="$2"
  local is_last="$3"

  local label="${EVENT_LABEL[$seq]:-unknown}"
  local phase="${EVENT_PHASE[$seq]:-}"
  local type="${EVENT_TYPE[$seq]:-}"
  local pc
  pc=$(phase_color "$phase")

  # Format seq number with padding
  local seq_str
  seq_str=$(printf "#%-3s" "${seq}")

  # Connector
  local connector
  if [[ -z "$prefix" && "$seq" == "1" ]]; then
    connector=""
  elif [[ "$is_last" == "true" ]]; then
    connector="└── "
  else
    connector="├── "
  fi

  # Color the label based on type
  local colored_label
  case "$type" in
    phase.transition) colored_label="${C_TRANS}${label}${C_RESET}" ;;
    decision|decision.point) colored_label="${C_DECISION}${label}${C_RESET}" ;;
    review.verdict)   colored_label="${C_VERDICT}${label}${C_RESET}" ;;
    *)                colored_label="${pc}${label}${C_RESET}" ;;
  esac

  if [[ "$seq" == "1" ]]; then
    printf "%b\n" "${C_SEQ}#1${C_RESET}  ${colored_label}"
  else
    printf "%b\n" "${prefix}${connector}${C_SEQ}${seq_str}${C_RESET}${colored_label}"
  fi

  # Render children
  local children="${DISPLAY_CHILDREN[$seq]:-}"
  if [[ -z "$children" ]]; then
    return
  fi

  local -a child_arr
  read -ra child_arr <<< "$children"
  local count=${#child_arr[@]}
  local i=0

  for c in "${child_arr[@]}"; do
    i=$((i + 1))
    local child_is_last="false"
    if [[ $i -eq $count ]]; then
      child_is_last="true"
    fi

    local child_prefix
    if [[ "$seq" == "1" ]]; then
      child_prefix=""
    elif [[ "$is_last" == "true" ]]; then
      child_prefix="${prefix}    "
    else
      child_prefix="${prefix}│   "
    fi

    render_node "$c" "$child_prefix" "$child_is_last"
  done
}

# Find root nodes (display parent == 0 means top-level)
root_children="${DISPLAY_CHILDREN[0]:-}"
if [[ -z "$root_children" ]]; then
  echo "No events found." >&2
  exit 1
fi

# The first root child should be #1 (run.start), render from there
render_node 1 "" "true"
