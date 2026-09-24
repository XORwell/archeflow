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

# Event files are local by default but can come from a repository (a user may
# commit them), so their fields are never used in shell arithmetic: bash would
# evaluate a value like 'a[$(cmd)]'. Numbers are computed in jq and checked with
# af_as_int.
#
# Fields read (the schema in skills/run/reference.md):
#   run.start       data.task, data.workflow, data.team (optional; else the roles
#                   seen in agent.start/agent.complete/review.verdict events)
#   run.complete    data.status, cycles, agents_total, fixes_total, shadows,
#                   duration_ms (optional; else run.start ts -> run.complete ts)
#   run.merged      overrides the status with "merged" (a merge after awaiting_merge)
#   cycle.boundary  data.cycle, max_cycles, exit_condition, decision
#                   (the pre-0.11 names met / next_action are still read)
JQ_NUM='def num: if type == "number" then . elif type == "string" then (tonumber? // null) else null end;'

# Run duration in whole seconds, or nothing if unknown.
duration_seconds() {
  local d
  d=$(jq -rs "${JQ_NUM}"'
      def t: (.ts | strings | try fromdateiso8601 catch null) // null;
      [ .[] | objects ] as $ev
      | ([ $ev[] | select(.type == "run.start") ] | first) as $s
      | ([ $ev[] | select(.type == "run.complete") ] | last) as $c
      | (if $c == null then null else ($c.data.duration_ms? | num) end) as $ms
      | if $ms != null and $ms > 0 then ($ms / 1000 | floor | tostring)
        elif $s != null and $c != null and ($s | t) != null and ($c | t) != null
             and ($c | t) >= ($s | t) then (($c | t) - ($s | t) | floor | tostring)
        else "" end' "$EVENT_FILE" 2>/dev/null || true)
  af_as_int "$d" ""
}

# "<1 min", "~N min", or nothing if unknown.
duration_display() {
  local secs
  secs=$(duration_seconds)
  [[ -n "$secs" ]] || return 0
  if [[ "$secs" -lt 60 ]]; then
    echo "<1 min"
  else
    echo "~$((secs / 60)) min"
  fi
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
# Team: data.team if given, else the roles that took part, in order of appearance.
TEAM=$(echo "$RUN_START" | jq -r '.data.team // empty
  | if type == "array" then map(tostring) | join(", ") else tostring end' 2>/dev/null || true)
if [[ -z "$TEAM" ]]; then
  TEAM=$(jq -rs '[ .[] | objects
      | select(.type == "agent.start" or .type == "agent.complete" or .type == "review.verdict")
      | (.data.archetype? // .agent) | strings | select(. != "" and . != "system") ]
    | reduce .[] as $r ([]; if index([$r]) then . else . + [$r] end) | join(", ")' \
    "$EVENT_FILE" 2>/dev/null || true)
fi
[[ -n "$TEAM" ]] || TEAM="unknown"
# A merge confirmed after the run ended (awaiting_merge) is logged as run.merged.
MERGED=$(jq -r 'select(.type == "run.merged") | "yes"' "$EVENT_FILE" 2>/dev/null | head -1 || true)

# --summary mode: one-line output and exit
if [[ "$MODE" == "summary" ]]; then
  if [[ -n "$RUN_COMPLETE" ]]; then
    STATUS=$(echo "$RUN_COMPLETE" | jq -r '.data.status // "unknown"')
    [[ -n "$MERGED" ]] && STATUS="merged"
    CYCLES=$(echo "$RUN_COMPLETE" | jq -r '.data.cycles // "?"')
    # Handle both agents_total and agents field names
    AGENTS=$(echo "$RUN_COMPLETE" | jq -r '.data.agents_total // .data.agents // "?"')
    FIXES=$(echo "$RUN_COMPLETE" | jq -r '.data.fixes_total // .data.fixes // "?"')
    DURATION=$(duration_display)
    if [[ -n "$DURATION" ]]; then
      echo "[${STATUS}] ${TASK} — ${CYCLES} cycles, ${AGENTS} agents, ${FIXES} fixes (${DURATION}) [${RUN_ID}]"
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
    [[ -n "$MERGED" ]] && STATUS="merged"
    CYCLES=$(echo "$RUN_COMPLETE" | jq -r '.data.cycles // "?"')
    # Handle both agents_total and agents field names
    AGENTS=$(echo "$RUN_COMPLETE" | jq -r '.data.agents_total // .data.agents // "?"')
    FIXES=$(echo "$RUN_COMPLETE" | jq -r '.data.fixes_total // .data.fixes // "?"')
    # Shadows: data.shadows, else the shadow.detected events in the log.
    SHADOWS=$(echo "$RUN_COMPLETE" | jq -r '.data.shadows // empty | tostring' 2>/dev/null || true)
    [[ -n "$SHADOWS" ]] || SHADOWS=$(jq -c 'select(.type == "shadow.detected")' "$EVENT_FILE" 2>/dev/null | wc -l | tr -d ' ')
    DURATION_DISPLAY=$(duration_display)
    [[ -n "$DURATION_DISPLAY" ]] || DURATION_DISPLAY="n/a"

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
        # Extras: tokens and estimated cost, when recorded.
        EXTRAS=$(echo "$event" | jq -r "${JQ_NUM}"' [ ((.data.tokens | num) // 0 | select(. > 0) | "\(.) tokens"),
            ((.data.estimated_cost_usd | num) // null | select(. != null) | "$\(. * 100 | round / 100)") ]
            | map(", " + .) | join("")' 2>/dev/null || true)
        SUMMARY=$(echo "$event" | jq -r '.data.summary // "no summary"')
        ARTIFACTS=$(echo "$event" | jq -r '(.data.artifacts // []) | if type == "array" then map(tostring) | join(", ") else tostring end' 2>/dev/null || true)

        echo "**${ARCHETYPE}** (${DURATION_S}s${EXTRAS})"
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
        # exit_condition/decision (reference.md); met/next_action from older logs.
        EXIT_COND=$(echo "$event" | jq -r '.data.exit_condition // (if .data.met == true then "met"
            elif .data.met == false then "not met" else "not recorded" end) | tostring')
        NEXT=$(echo "$event" | jq -r '.data.decision // .data.next_action // "not recorded" | tostring')
        COUNTS=$(echo "$event" | jq -r '[ ("critical", "warning", "info") as $k
            | select(.data[$k]? != null) | "\(.data[$k]) \($k | ascii_upcase)" ] | join(", ")' 2>/dev/null || true)

        echo ""
        echo "---"
        echo ""
        if [[ -n "$COUNTS" ]]; then
          echo "**Cycle ${CYCLE}/${MAX}** — exit condition: ${EXIT_COND} (${COUNTS}) → ${NEXT}"
        else
          echo "**Cycle ${CYCLE}/${MAX}** — exit condition: ${EXIT_COND} → ${NEXT}"
        fi
        echo ""
        ;;

      wiggum.break)
        BTYPE=$(echo "$event" | jq -r '.data.type // "?" | tostring')
        REASONS=$(echo "$event" | jq -r '[ (.data.triggers // [])[]? | .reason? | strings ] | join("; ")' 2>/dev/null || true)
        echo "- **Wiggum Break** (${BTYPE}): ${REASONS}"
        echo ""
        ;;

      run.merged)
        BASE=$(echo "$event" | jq -r '.data.base // "base branch" | tostring')
        echo "- **Merged** into ${BASE}"
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
    # run.complete.data.artifacts, else the artifacts named by agent.complete events.
    ARTS=$(echo "$RUN_COMPLETE" | jq -r '(.data.artifacts // [])[]? | strings | "- `" + . + "`"' 2>/dev/null || true)
    if [[ -z "$ARTS" ]]; then
      ARTS=$(jq -rs '[ .[] | objects | select(.type == "agent.complete") | (.data.artifacts? // [])
          | if type == "array" then .[] else . end | strings ] | unique | .[] | "- `" + . + "`"' \
        "$EVENT_FILE" 2>/dev/null || true)
    fi
    echo "${ARTS:-(none recorded)}"
  fi
}

if [[ -n "$OUTPUT" ]]; then
  generate_report > "$OUTPUT"
  echo "Report written to: $OUTPUT" >&2
else
  generate_report
fi
