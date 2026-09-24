#!/usr/bin/env bash
# archeflow-event.sh — Append a structured event to an ArcheFlow run's JSONL log.
#
# Usage: ./lib/archeflow-event.sh <run_id> <type> <phase> <agent> '<json_data>' [parent_seqs]
#
# Examples:
#   ./lib/archeflow-event.sh 2026-04-03-add-auth run.start plan "" '{"task":"Add authentication module"}'
#   ./lib/archeflow-event.sh 2026-04-03-add-auth agent.complete plan creator '{"duration_ms":167522}' 2
#   ./lib/archeflow-event.sh 2026-04-03-add-auth phase.transition do "" '{"from":"plan","to":"do"}' 3,4
#   ./lib/archeflow-event.sh 2026-04-03-add-auth fix.applied act "" '{"source":"guardian"}' 8
#   ./lib/archeflow-event.sh 2026-04-03-add-auth decision.point check guardian \
#     '{"archetype":"guardian","input":"diff","decision":"needs_changes","confidence":0.85}' 7
#   # Or use: ./lib/archeflow-decision.sh <run_id> <phase> <arch> '<input>' '<decision>' <confidence> [parent]
#
# Parent seqs: comma-separated seq numbers of causal parent events (DAG).
#   "2"   → single parent [2]
#   "3,4" → multiple parents [3,4] (fan-in)
#   ""    → root event []
#   (omitted) → chosen automatically, so the DAG does not depend on the caller:
#     run.start and the first event of a file: root [];
#     agent.complete, agent.failed, agent.timeout, review.verdict, shadow.detected,
#     decision.point of an agent: that agent's latest agent.start (if any);
#     everything else (and agents without an agent.start): the latest
#     run.start / phase.transition / cycle.boundary.
#
# Events are appended to .archeflow/events/<run_id>.jsonl
# If the events directory doesn't exist, it is created automatically.
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed. Install: https://jqlang.github.io/jq/" >&2; exit 1; }

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/archeflow-common.sh
source "${LIB_DIR}/archeflow-common.sh"
# Refuse a symlinked .archeflow/ (or events/, runs/, memory/ ...): writes would land outside the repo.
af_check_state_dirs

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <run_id> <type> <phase> <agent> [json_data] [parent_seqs]" >&2
  exit 1
fi

RUN_ID="$1"
TYPE="$2"
PHASE="$3"
AGENT="$4"
DATA="${5:-"{}"}"
PARENT_RAW="${6:-}"
PARENT_GIVEN=false
[[ $# -ge 6 ]] && PARENT_GIVEN=true
# Run IDs become file names under .archeflow/ (and git branch names).
af_require_run_id "$RUN_ID"

EVENTS_DIR=".archeflow/events"
EVENT_FILE="${EVENTS_DIR}/${RUN_ID}.jsonl"

mkdir -p "$EVENTS_DIR"

# Validate JSON data
if ! echo "$DATA" | jq empty 2>/dev/null; then
  echo "Error: invalid JSON in data argument: $DATA" >&2
  exit 1
fi

# Build parent array from comma-separated seq numbers (auto: after the lock)
if [[ "$PARENT_GIVEN" == false ]]; then
  PARENT_JSON=""
elif [[ -z "$PARENT_RAW" ]]; then
  PARENT_JSON="[]"
elif [[ "$PARENT_RAW" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
  PARENT_JSON="[${PARENT_RAW}]"
else
  echo "Error: invalid parent format (expected comma-separated integers): $PARENT_RAW" >&2
  exit 1
fi

# Sequence number = existing lines + 1. Computing it and appending must be one
# critical section, or parallel agents emitting to the same run get duplicate
# seq numbers. Lock is advisory (flock, or mkdir fallback).
# shellcheck source=lib/archeflow-lock.sh
source "${LIB_DIR}/archeflow-lock.sh"
LOCK_FILE="${EVENT_FILE}.lock"
af_lock "$LOCK_FILE" 10 || { echo "Error: could not lock $EVENT_FILE" >&2; exit 1; }
trap 'af_unlock "$LOCK_FILE"' EXIT

if [[ -f "$EVENT_FILE" ]]; then
  SEQ=$(( $(wc -l < "$EVENT_FILE") + 1 ))
else
  SEQ=1
fi

# Automatic parent (see header). The event file is data: only integer seqs
# of well-formed events are used.
if [[ -z "$PARENT_JSON" ]]; then
  PARENT_JSON="[]"
  if [[ "$TYPE" != "run.start" && -s "$EVENT_FILE" ]]; then
    PARENT_JSON=$(jq -cs --arg t "$TYPE" --arg a "$AGENT" '
      def isint: type == "number" and . >= 1 and . == floor and . < 1e15;
      [ .[] | select(type == "object" and (.seq | isint)) ] as $ev
      | ([ $ev[] | select(.type == "run.start" or .type == "phase.transition" or .type == "cycle.boundary") ]
         | last | .seq) as $anchor
      | (if $a != "" and ($t == "agent.complete" or $t == "agent.failed" or $t == "agent.timeout"
                          or $t == "review.verdict" or $t == "shadow.detected" or $t == "decision.point")
         then ([ $ev[] | select(.type == "agent.start" and .agent == $a) ] | last | .seq)
         else null end) as $own
      | [ ($own // $anchor // ($ev | last | .seq)) | select(. != null) ]
    ' "$EVENT_FILE" 2>/dev/null) || PARENT_JSON="[]"
    [[ "$PARENT_JSON" =~ ^\[[0-9]*\]$ ]] || PARENT_JSON="[]"
  fi
fi

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Construct the event using jq for reliable JSON assembly
# Agent is passed as --arg (string), then converted to null if empty via jq expression
EVENT=$(jq -cn \
  --arg ts "$TS" \
  --arg run_id "$RUN_ID" \
  --argjson seq "$SEQ" \
  --argjson parent "$PARENT_JSON" \
  --arg type "$TYPE" \
  --arg phase "$PHASE" \
  --arg agent_raw "$AGENT" \
  --argjson data "$DATA" \
  '{ts:$ts, run_id:$run_id, seq:$seq, parent:$parent, type:$type, phase:$phase, agent:(if $agent_raw == "" then null else $agent_raw end), data:$data}'
)

# A committed .archeflow/ can contain symlinks; never append through one.
af_append "$EVENT_FILE" "$EVENT" || exit 1
af_unlock "$LOCK_FILE"
trap - EXIT

# Optional Langfuse bridge: forward event in background, never block orchestration.
# If the bridge script is missing, config is absent, or the POST fails, this is
# a no-op. Use lib/archeflow-langfuse-backfill.sh to replay historical runs.
_LF_BRIDGE="${LIB_DIR}/archeflow-langfuse.sh"
if [[ -x "$_LF_BRIDGE" ]]; then
  echo "$EVENT" | "$_LF_BRIDGE" >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

# Print confirmation to stderr (non-intrusive)
echo "[archeflow-event] #${SEQ} ${TYPE} (${PHASE}/${AGENT:-_})" >&2
