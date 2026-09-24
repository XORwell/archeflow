#!/usr/bin/env bash
# archeflow-report.sh — Generate a Markdown process report from ArcheFlow JSONL events.
#
# Usage: ./lib/archeflow-report.sh <events.jsonl> [--output <file.md>] [--dag] [--summary]
#
# Reads a JSONL event file and produces a structured Markdown report showing
# the full orchestration process: phases, decisions, reviews, fixes, metrics.
#
# Flags:
#   --output <file.md>  Write report to file instead of stdout
#   --dag               Output ONLY the ASCII DAG (for quick terminal viewing)
#   --summary           Output a one-line summary (for session logs)
#
# Requires: jq
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/archeflow-common.sh
source "${SCRIPT_DIR}/archeflow-common.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <events.jsonl> [--output <file.md>] [--dag] [--summary]" >&2
  exit 1
fi

EVENT_FILE="$1"
shift

OUTPUT=""
MODE="full"  # full | dag | summary

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT="${2:-}"
      shift 2
      ;;
    --dag)
      MODE="dag"
      shift
      ;;
    --summary)
      MODE="summary"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2; exit 1
      ;;
  esac
done

if ! command -v jq &> /dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

if [[ ! -f "$EVENT_FILE" ]]; then
  echo "Error: Event file not found: $EVENT_FILE" >&2
  exit 1
fi

# Event files can come from the repository (they are committed with each run),
# so their fields are never used in shell arithmetic: bash would evaluate a value
# like 'a[$(cmd)]'. Numbers are computed in jq and checked with af_as_int.
JQ_NUM='def num: if type == "number" then . elif type == "string" then (tonumber? // null) else null end;'

# Prints the run duration in whole minutes, or nothing if unknown / zero.
duration_minutes() {
  local m
  m=$(echo "$1" | jq -r "${JQ_NUM}"' (.data.duration_ms | num) as $d
      | if $d == null or $d == 0 then "" else ($d / 60000 | floor | tostring) end' 2>/dev/null || true)
  af_as_int "$m" ""
}

# Helper: extract events by type
events_of_type() {
  jq -c --arg t "$1" 'select(.type == $t)' "$EVENT_FILE"
}

# Extract run metadata
RUN_START=$(events_of_type "run.start" | head -1)
RUN_COMPLETE=$(events_of_type "run.complete" | head -1)
RUN_ID=$(echo "$RUN_START" | jq -r '.run_id // "unknown"')
TASK=$(echo "$RUN_START" | jq -r '.data.task // "unknown"')
WORKFLOW=$(echo "$RUN_START" | jq -r '.data.workflow // "unknown"')
TEAM=$(echo "$RUN_START" | jq -r '.data.team // "unknown"')

# --summary mode: one-line output and exit
if [[ "$MODE" == "summary" ]]; then
  if [[ -n "$RUN_COMPLETE" ]]; then
    STATUS=$(echo "$RUN_COMPLETE" | jq -r '.data.status // "unknown"')
    CYCLES=$(echo "$RUN_COMPLETE" | jq -r '.data.cycles // "?"')
    # Handle both agents_total and agents field names
    AGENTS=$(echo "$RUN_COMPLETE" | jq -r '.data.agents_total // .data.agents // "?"')
    FIXES=$(echo "$RUN_COMPLETE" | jq -r '.data.fixes_total // .data.fixes // "?"')
    DURATION_MIN=$(duration_minutes "$RUN_COMPLETE")
    if [[ -n "$DURATION_MIN" ]]; then
      echo "[${STATUS}] ${TASK} — ${CYCLES} cycles, ${AGENTS} agents, ${FIXES} fixes (~${DURATION_MIN}min) [${RUN_ID}]"
    else
      echo "[${STATUS}] ${TASK} — ${CYCLES} cycles, ${AGENTS} agents, ${FIXES} fixes [${RUN_ID}]"
    fi
  else
    echo "[in-progress] ${TASK} [${RUN_ID}]"
  fi
  exit 0
fi

# --dag mode: output DAG and exit
if [[ "$MODE" == "dag" ]]; then
  if [[ -x "${SCRIPT_DIR}/archeflow-dag.sh" ]]; then
    "${SCRIPT_DIR}/archeflow-dag.sh" "$EVENT_FILE" "$@"
  else
    echo "Error: archeflow-dag.sh not found at ${SCRIPT_DIR}/archeflow-dag.sh" >&2
    exit 1
  fi
  exit 0
fi

# --- Full report mode ---

# Collect cycle data for cycle diff section
CYCLE_BOUNDARIES=$(events_of_type "cycle.boundary" | jq -r '.data.cycle' 2>/dev/null || true)
CYCLE_COUNT=0
if [[ -n "$CYCLE_BOUNDARIES" ]]; then
  CYCLE_COUNT=$(echo "$CYCLE_BOUNDARIES" | grep -c '[0-9]' 2>/dev/null || true)
  CYCLE_COUNT=${CYCLE_COUNT:-0}
fi

# Collect review findings per cycle for diff
# A cycle's reviews are between two cycle.boundary events (or between start and first boundary)
collect_cycle_findings() {
  # Returns JSON array of {cycle, archetype, findings[]} for all review.verdict events
  jq -s '
    # Assign cycle number to each event based on cycle.boundary positions
    (
      [.[] | select(.type == "cycle.boundary") | .seq] | sort
    ) as $boundaries |
    [.[] | select(.type == "review.verdict")] |
    [.[] | {
      seq: .seq,
      archetype: (.data.archetype // .agent // "unknown"),
      verdict: .data.verdict,
      findings: (.data.findings // []),
      cycle: (
        .seq as $s |
        if ($boundaries | length) == 0 then 1
        else
          ([1] + [$boundaries | to_entries[] | select(.value < $s) | .key + 2] | max)
        end
      )
    }]
  ' "$EVENT_FILE"
}

generate_report() {
  cat <<HEADER
# Process Report: ${TASK}

> Auto-generated from ArcheFlow event log.
> Run: \`${RUN_ID}\` | Workflow: \`${WORKFLOW}\` | Team: \`${TEAM}\`

---

## Overview

HEADER

  # Overview table from run.complete
  if [[ -n "$RUN_COMPLETE" ]]; then
    STATUS=$(echo "$RUN_COMPLETE" | jq -r '.data.status // "unknown"')
    CYCLES=$(echo "$RUN_COMPLETE" | jq -r '.data.cycles // "?"')
    # Handle both agents_total and agents field names
    AGENTS=$(echo "$RUN_COMPLETE" | jq -r '.data.agents_total // .data.agents // "?"')
    FIXES=$(echo "$RUN_COMPLETE" | jq -r '.data.fixes_total // .data.fixes // "?"')
    SHADOWS=$(echo "$RUN_COMPLETE" | jq -r '.data.shadows // "0"')
    DURATION_MIN=$(duration_minutes "$RUN_COMPLETE")
    if [[ -n "$DURATION_MIN" ]]; then
      DURATION_DISPLAY="~${DURATION_MIN} min"
    else
      DURATION_DISPLAY="n/a"
    fi

    cat <<TABLE
| Field | Value |
|-------|-------|
| **Status** | ${STATUS} |
| **PDCA Cycles** | ${CYCLES} |
| **Agents** | ${AGENTS} |
| **Fixes** | ${FIXES} |
| **Shadows** | ${SHADOWS} |
| **Duration** | ${DURATION_DISPLAY} |

TABLE
  fi

  # Config from run.start
  CONFIG=$(echo "$RUN_START" | jq -r '.data.config // empty')
  if [[ -n "$CONFIG" ]]; then
    echo "### Configuration"
    echo '```json'
    echo "$CONFIG" | jq .
    echo '```'
    echo ""
  fi

  echo "---"
  echo ""

  # Process Flow (DAG)
  echo "## Process Flow"
  echo ""
  echo '```'
  if [[ -x "${SCRIPT_DIR}/archeflow-dag.sh" ]]; then
    "${SCRIPT_DIR}/archeflow-dag.sh" "$EVENT_FILE" --no-color
  else
    echo "(DAG renderer not available)"
  fi
  echo '```'
  echo ""

  echo "---"
  echo ""

  # Phase sections — iterate through phase transitions
  echo "## Phases"
  echo ""

  CURRENT_PHASE=""

  # Process all events chronologically
  while IFS= read -r event; do
    TYPE=$(echo "$event" | jq -r '.type')
    PHASE=$(echo "$event" | jq -r '.phase')
    AGENT=$(echo "$event" | jq -r '.agent // ""')
    TS=$(echo "$event" | jq -r '.ts')

    # Phase header on transition
    if [[ "$PHASE" != "$CURRENT_PHASE" && "$TYPE" != "run.start" && "$TYPE" != "run.complete" ]]; then
      CURRENT_PHASE="$PHASE"
      PHASE_UPPER=$(echo "$PHASE" | tr '[:lower:]' '[:upper:]')
      echo "### ${PHASE_UPPER}"
      echo ""
    fi

    case "$TYPE" in
      agent.complete)
        ARCHETYPE=$(echo "$event" | jq -r '.data.archetype // .agent // "unknown"')
        DURATION_S=$(af_as_int "$(echo "$event" | jq -r "${JQ_NUM}"' (.data.duration_ms | num) // 0 | . / 1000 | floor' 2>/dev/null)")
        TOKENS=$(echo "$event" | jq -r '.data.tokens // 0')
        SUMMARY=$(echo "$event" | jq -r '.data.summary // "no summary"')
        ARTIFACTS=$(echo "$event" | jq -r '(.data.artifacts // []) | join(", ")')

        echo "**${ARCHETYPE}** (${DURATION_S}s, ${TOKENS} tokens)"
        echo ": ${SUMMARY}"
        if [[ -n "$ARTIFACTS" ]]; then
          echo ": Artifacts: ${ARTIFACTS}"
        fi
        echo ""
        ;;

      decision)
        WHAT=$(echo "$event" | jq -r '.data.what // "unknown"')
        CHOSEN=$(echo "$event" | jq -r '.data.chosen // "unknown"')
        RATIONALE=$(echo "$event" | jq -r '.data.rationale // ""')

        echo "**Decision: ${WHAT}**"
        echo ": Chosen: ${CHOSEN}"
        if [[ -n "$RATIONALE" ]]; then
          echo ": Rationale: ${RATIONALE}"
        fi

        # List alternatives if present
        ALTS=$(echo "$event" | jq -r '(.data.alternatives // [])[] | "  - ~" + .id + "~ " + .label + " — " + .reason_rejected')
        if [[ -n "$ALTS" ]]; then
          echo ": Rejected:"
          echo "$ALTS"
        fi
        echo ""
        ;;

      review.verdict)
        ARCHETYPE=$(echo "$event" | jq -r '.data.archetype // .agent // "unknown"')
        VERDICT=$(echo "$event" | jq -r '.data.verdict // "unknown"')
        VERDICT_UPPER=$(echo "$VERDICT" | tr '[:lower:]' '[:upper:]' | tr '_' ' ')

        echo "**${ARCHETYPE}** → ${VERDICT_UPPER}"

        # List findings
        echo "$event" | jq -r '(.data.findings // [])[] | "  - [" + .severity + "] " + .description' 2>/dev/null || true
        echo ""
        ;;

      fix.applied)
        SOURCE=$(echo "$event" | jq -r '.data.source // "unknown"')
        FINDING=$(echo "$event" | jq -r '.data.finding // "unknown"')
        FILE=$(echo "$event" | jq -r '.data.file // ""')
        LINE=$(echo "$event" | jq -r '.data.line // ""')

        if [[ -n "$FILE" && "$LINE" != "null" && -n "$LINE" ]]; then
          echo "- **Fix** (${SOURCE}): ${FINDING} — \`${FILE}:${LINE}\`"
        else
          echo "- **Fix** (${SOURCE}): ${FINDING}"
        fi
        ;;

      shadow.detected)
        ARCHETYPE=$(echo "$event" | jq -r '.data.archetype // "unknown"')
        SHADOW=$(echo "$event" | jq -r '.data.shadow // "unknown"')
        ACTION=$(echo "$event" | jq -r '.data.action // "unknown"')

        echo "- **Shadow** ${ARCHETYPE}: ${SHADOW} → ${ACTION}"
        echo ""
        ;;

      cycle.boundary)
        CYCLE=$(echo "$event" | jq -r '.data.cycle // "?"')
        MAX=$(echo "$event" | jq -r '.data.max_cycles // "?"')
        MET=$(echo "$event" | jq -r '.data.met // false')
        NEXT=$(echo "$event" | jq -r '.data.next_action // "unknown"')

        echo ""
        echo "---"
        echo ""
        echo "**Cycle ${CYCLE}/${MAX}** — exit condition met: ${MET} → ${NEXT}"
        echo ""
        ;;
    esac

  done < "$EVENT_FILE"

  # Cycle Comparison section (only if multiple cycles detected)
  if [[ "$CYCLE_COUNT" -ge 2 ]]; then
    echo ""
    echo "---"
    echo ""
    echo "## Cycle Comparison"
    echo ""

    # Collect all review findings with cycle assignment
    CYCLE_FINDINGS=$(collect_cycle_findings)

    # Get unique cycle numbers
    CYCLE_NUMS=$(echo "$CYCLE_FINDINGS" | jq -r '[.[].cycle] | unique | .[]')

    # Compare consecutive cycles
    PREV_CYCLE=""
    for CURR_CYCLE in $CYCLE_NUMS; do
      if [[ -n "$PREV_CYCLE" ]]; then
        echo "### Cycle ${PREV_CYCLE} → Cycle ${CURR_CYCLE}"
        echo ""

        # Get findings for each cycle as JSON arrays
        PREV_FINDINGS=$(echo "$CYCLE_FINDINGS" | jq --argjson c "$PREV_CYCLE" \
          '[.[] | select(.cycle == $c) | .findings[] | {desc: .description, sev: .severity}]' 2>/dev/null || echo "[]")
        CURR_FINDINGS=$(echo "$CYCLE_FINDINGS" | jq --argjson c "$CURR_CYCLE" \
          '[.[] | select(.cycle == $c) | .findings[] | {desc: .description, sev: .severity}]' 2>/dev/null || echo "[]")

        # Compute new, resolved, and persistent findings
        DIFF_OUTPUT=$(jq -rn --argjson prev "$PREV_FINDINGS" --argjson curr "$CURR_FINDINGS" '
          def descs: [.[].desc];
          ($prev | descs) as $pd |
          ($curr | descs) as $cd |
          ($curr | [.[] | select(.desc as $d | $pd | all(. != $d))]) as $new |
          ($prev | [.[] | select(.desc as $d | $cd | all(. != $d))]) as $resolved |
          ($curr | [.[] | select(.desc as $d | $pd | any(. == $d))]) as $persistent |
          (
            (if ($new | length) > 0 then
              ["**New findings:**"] + [$new[] | "- [" + .sev + "] " + .desc]
            else [] end) +
            (if ($resolved | length) > 0 then
              ["", "**Resolved findings:**"] + [$resolved[] | "- [" + .sev + "] " + .desc]
            else [] end) +
            (if ($persistent | length) > 0 then
              ["", "**Persistent findings:**"] + [$persistent[] | "- [" + .sev + "] " + .desc]
            else [] end)
          ) | .[]
        ' 2>/dev/null || true)

        if [[ -n "$DIFF_OUTPUT" ]]; then
          echo "$DIFF_OUTPUT"
        else
          echo "(No findings to compare)"
        fi
        echo ""
      fi
      PREV_CYCLE="$CURR_CYCLE"
    done
  fi

  # Artifacts list from run.complete
  if [[ -n "$RUN_COMPLETE" ]]; then
    echo ""
    echo "---"
    echo ""
    echo "## Artifacts"
    echo ""
    echo "$RUN_COMPLETE" | jq -r '(.data.artifacts // [])[] | "- `" + . + "`"'
  fi
}

if [[ -n "$OUTPUT" ]]; then
  generate_report > "$OUTPUT"
  echo "Report written to: $OUTPUT" >&2
else
  generate_report
fi
