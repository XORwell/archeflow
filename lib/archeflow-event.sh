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
#
# The lookup must not rescan the whole log for every event (that made logging
# O(n) per event). A small state file under .archeflow/locks/ caches what the
# lookup needs (latest anchor, latest agent.start per agent, latest seq) up to
# a byte offset of the log, and only the lines appended since are read. It is
# used only while the log still ends, at that offset, with the event recorded in
# it; otherwise (log rewritten, truncated, first use) the whole log is scanned
# again, which gives the same result. The format:
#   line 1: <size of the log in bytes> <byte length of the last line, with newline>
#   line 2: the last line of the log (the event this script appended)
#   line 3: {"anchor": seq|null, "last": seq|null, "starts": {"<agent>": seq}}
STATE_FILE=".archeflow/locks/events-${RUN_ID}.parents"
AUTO_PARENT=false
[[ -z "$PARENT_JSON" && "$TYPE" != "run.start" && -s "$EVENT_FILE" ]] && AUTO_PARENT=true
[[ -n "$PARENT_JSON" ]] || PARENT_JSON="[]"

LOG_SIZE=0
[[ -f "$EVENT_FILE" ]] && LOG_SIZE=$(af_as_int "$(wc -c < "$EVENT_FILE" | tr -d ' ')")
STATE_JSON=""
SCAN_FROM=0   # byte offset where the scan starts (0 = the whole log)
if [[ "$LOG_SIZE" -gt 0 && -f "$STATE_FILE" && ! -L "$STATE_FILE" ]]; then
  {
    IFS=' ' read -r _st_size _st_len || true
    IFS= read -r _st_tail || true
    IFS= read -r STATE_JSON || true
  } < "$STATE_FILE"
  _st_size=$(af_as_int "${_st_size:-}" "")
  _st_len=$(af_as_int "${_st_len:-}" "")
  if [[ -n "$_st_size" && -n "$_st_len" && "$_st_len" -gt 0 && "$_st_size" -ge "$_st_len" \
        && "$_st_size" -le "$LOG_SIZE" ]] \
     && [[ "$(tail -c "+$((_st_size - _st_len + 1))" "$EVENT_FILE" 2>/dev/null | head -c "$_st_len" || true)" == "${_st_tail:-}" ]]; then
    SCAN_FROM="$_st_size"
  else
    STATE_JSON=""
  fi
fi

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# One jq pass: fold the unread part of the log into the state, pick the
# automatic parent, build the event (agent "" becomes null), and fold the event
# into the state. Prints the event and the new state on two lines. A log that
# does not parse gives no automatic parent (as before); the event is then built
# on its own below.
parent_lookup() {
  local from="$1" state="$2"
  { if [[ "$LOG_SIZE" -gt 0 ]]; then tail -c "+$((from + 1))" "$EVENT_FILE"; fi; } | jq -cs \
    --arg st "$state" --arg auto "$AUTO_PARENT" --arg ts "$TS" --arg run_id "$RUN_ID" \
    --argjson seq "$SEQ" --argjson parent "$PARENT_JSON" --arg type "$TYPE" --arg phase "$PHASE" \
    --arg agent_raw "$AGENT" --argjson data "$DATA" '
    def isint: type == "number" and . >= 1 and . == floor and . < 1e15;
    def fold($e):
      if ($e | type) == "object" and ($e.seq | isint) then
        .last = $e.seq
        | if $e.type == "run.start" or $e.type == "phase.transition" or $e.type == "cycle.boundary"
          then .anchor = $e.seq else . end
        | if $e.type == "agent.start" and ($e.agent | type) == "string"
          then .starts[$e.agent] = $e.seq else . end
      else . end;
    (if $st == "" then {anchor: null, last: null, starts: {}}
     else ($st | fromjson
       | if type == "object" and (.anchor == null or (.anchor | isint))
            and (.last == null or (.last | isint))
            and (.starts | type) == "object" and ([.starts[] | isint] | all)
         then {anchor, last, starts} else error("bad state") end) end) as $cached
    | reduce .[] as $e ($cached; fold($e))
    | (if $agent_raw != "" and ($type == "agent.complete" or $type == "agent.failed"
          or $type == "agent.timeout" or $type == "review.verdict" or $type == "shadow.detected"
          or $type == "decision.point")
       then .starts[$agent_raw] else null end) as $own
    | (if $auto == "true" then [ ($own // .anchor // .last) | select(. != null) ]
         | if tojson | test("^\\[[0-9]*\\]$") then . else [] end
       else $parent end) as $parent
    | {ts: $ts, run_id: $run_id, seq: $seq, parent: $parent, type: $type, phase: $phase,
       agent: (if $agent_raw == "" then null else $agent_raw end), data: $data} as $event
    | $event, fold($event)
  ' 2>/dev/null
}
NEW_STATE=""
EVENT=""
# A cache that cannot be read is ignored: rescan from the start.
if RESULT=$(parent_lookup "$SCAN_FROM" "$STATE_JSON") \
   || { [[ "$SCAN_FROM" -gt 0 ]] && RESULT=$(parent_lookup 0 ""); }; then
  EVENT="${RESULT%%$'\n'*}"
  NEW_STATE="${RESULT#*$'\n'}"
fi

if [[ -z "$EVENT" || "$EVENT" != "{"* ]]; then
  # Construct the event using jq for reliable JSON assembly
  # Agent is passed as --arg (string), then converted to null if empty via jq expression
  NEW_STATE=""
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
fi

# A committed .archeflow/ can contain symlinks; never append through one.
af_append "$EVENT_FILE" "$EVENT" || exit 1

# Update the parent-lookup cache (best effort: without it the next event rescans).
NEW_SIZE=$(af_as_int "$(wc -c < "$EVENT_FILE" | tr -d ' ')")
_tmp=""
if [[ "$NEW_STATE" == "{"* && "$NEW_SIZE" -gt "$LOG_SIZE" ]] \
   && mkdir -p "$(dirname "$STATE_FILE")" && af_refuse_symlink "$STATE_FILE" 2>/dev/null \
   && _tmp=$(af_tmpfile "$STATE_FILE") \
   && printf '%s %s\n%s\n%s\n' "$NEW_SIZE" "$((NEW_SIZE - LOG_SIZE))" "$EVENT" "$NEW_STATE" > "$_tmp" \
   && mv -f "$_tmp" "$STATE_FILE"; then
  :
else
  [[ -z "$_tmp" ]] || rm -f "$_tmp"
  [[ -L "$STATE_FILE" ]] || rm -f "$STATE_FILE"
fi
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
