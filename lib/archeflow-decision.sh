#!/usr/bin/env bash
# archeflow-decision.sh — Log a PDCA decision point for run replay / effectiveness analysis.
#
# Appends a decision.point event to .archeflow/events/<run_id>.jsonl with:
#   phase, archetype (agent + data.archetype), input, decision, confidence, ts (via event layer)
#
# Usage:
#   ./lib/archeflow-decision.sh <run_id> <phase> <archetype> '<input>' '<decision>' <confidence> [parent_seq]
#
# Examples:
#   ./lib/archeflow-decision.sh 2026-04-06-auth check guardian \
#     'diff + proposal risks' 'needs_changes' 0.82 7
#   ./lib/archeflow-decision.sh 2026-04-06-auth act "" 'route findings' 'send_to_maker' 0.9
#
# confidence: 0.0–1.0 (orchestrator-estimated certainty in the recorded choice)
#
# Requires: jq (via archeflow-event.sh)
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed. Install: https://jqlang.github.io/jq/" >&2; exit 1; }

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 6 ]]; then
  echo "Usage: $0 <run_id> <phase> <archetype> '<input>' '<decision>' <confidence> [parent_seq]" >&2
  exit 1
fi

RUN_ID="$1"
PHASE="$2"
ARCH="$3"
INPUT="$4"
DECISION="$5"
CONF_RAW="$6"
PARENT="${7:-}"

if ! [[ "$CONF_RAW" =~ ^[0-9]*\.?[0-9]+$ ]]; then
  echo "Error: confidence must be a number (e.g. 0.85)" >&2
  exit 1
fi

DATA=$(jq -cn \
  --arg a "$ARCH" \
  --arg i "$INPUT" \
  --arg d "$DECISION" \
  --argjson c "$CONF_RAW" \
  '{archetype:$a, input:$i, decision:$d, confidence:$c}')

exec "$LIB_DIR/archeflow-event.sh" "$RUN_ID" decision.point "$PHASE" "$ARCH" "$DATA" "$PARENT"
