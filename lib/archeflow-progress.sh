#!/usr/bin/env bash
# archeflow-progress.sh — Generate a live progress file from ArcheFlow JSONL events.
#
# Usage:
#   archeflow-progress.sh <run_id>           # Generate/update .archeflow/progress.md
#   archeflow-progress.sh <run_id> --watch   # Continuous update mode (2s interval)
#   archeflow-progress.sh <run_id> --json    # Output as JSON (for dashboards)
#
# Reads .archeflow/events/<run_id>.jsonl and produces a human-readable progress
# snapshot. Designed to be called after every archeflow-event.sh invocation during
# a run, or watched from a second terminal.
#
# Requires: jq
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

# shellcheck source=lib/archeflow-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archeflow-common.sh"
# Refuse a symlinked .archeflow/ (or events/, runs/, memory/ ...): writes would land outside the repo.
af_check_state_dirs

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <run_id> [--watch] [--json]" >&2
  exit 1
fi

RUN_ID="$1"
shift
# Run IDs become file names under .archeflow/ (and git branch names).
af_require_run_id "$RUN_ID"

MODE="default"  # default | watch | json
while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch) MODE="watch" ;;
    --json)  MODE="json" ;;
    *)       echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

EVENTS_DIR=".archeflow/events"
EVENT_FILE="${EVENTS_DIR}/${RUN_ID}.jsonl"
PROGRESS_FILE=".archeflow/progress.md"

if ! command -v jq &> /dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

# --- Core: generate progress from current JSONL state ---

generate_progress_json() {
  # Produce a structured JSON object from the event stream.
  # This is the single source of truth — markdown and terminal output derive from it.

  if [[ ! -f "$EVENT_FILE" ]]; then
    jq -cn --arg run_id "$RUN_ID" '{error: "Event file not found", run_id: $run_id}'
    return 1
  fi

  jq -s '
    def ntok: if type == "number" then . elif type == "string" then (tonumber? // 0) else 0 end;
    # Extract run metadata
    (.[0] // {}) as $first |
    ([.[] | select(.type == "run.start")] | first // {}) as $run_start_evt |
    ($run_start_evt.data // {}) as $run_data |
    ($run_start_evt.ts // "") as $start_ts |
    ([.[] | select(.type == "run.complete")] | first // null) as $run_complete |

    # Current phase: last phase seen
    (map(.phase) | map(select(. != null and . != "")) | last // "unknown") as $current_phase |

    # Total events
    length as $total_events |

    # Latest event
    (last // {}) as $latest |

    # Completed agents: agent.complete events
    [.[] | select(.type == "agent.complete") | {
      agent: (.data.archetype // .agent // "unknown"),
      phase: .phase,
      duration_s: ((.data.duration_ms // 0) / 1000 | floor),
      # tokens: a number, {"input": n, "output": n}, or tokens_input + tokens_output.
      tokens: (.data.tokens as $t
        | if ($t | type) == "number" then $t
          elif ($t | type) == "string" and ($t | tonumber? // null) != null then ($t | tonumber)
          elif ($t | type) == "object" then (($t.input | ntok) + ($t.output | ntok))
          else ((.data.tokens_input | ntok) + (.data.tokens_output | ntok)) end),
      cost_usd: (.data.estimated_cost_usd // .data.cost_usd // 0),
      seq: .seq
    }] as $completed |

    # Running agents: agent.start with no matching agent.complete
    (
      [.[] | select(.type == "agent.start") | {
        agent: (.data.archetype // .agent // "unknown"),
        phase: .phase,
        start_ts: .ts,
        seq: .seq
      }] |
      # (a lookup table instead of a scan of $completed per agent.start)
      ($completed | map(.agent)) as $done_list |
      (reduce ($done_list[] | strings) as $a ({}; .[$a] = true)) as $done |
      [.[] | select(
        .agent as $a |
        if ($a | type) == "string" then $done[$a] == null else ($done_list | index($a)) == null end
      )]
    ) as $running |

    # Phase transitions
    [.[] | select(.type == "phase.transition") | {
      from: (.data.from // "?"),
      to: (.data.to // "?"),
      seq: .seq
    }] as $transitions |

    # Review verdicts
    [.[] | select(.type == "review.verdict") | {
      agent: (.data.archetype // .agent // "unknown"),
      verdict: (.data.verdict // "unknown"),
      findings_count: ((.data.findings // []) | length),
      seq: .seq
    }] as $verdicts |

    # Fixes
    [.[] | select(.type == "fix.applied")] | length as $fixes_count |

    # Budget: sum costs from agent.complete events
    ($completed | map(.cost_usd) | add // 0) as $budget_used |

    # Try to get budget limit from run.start config
    ($run_data.config.budget_usd // $run_data.budget_usd // null) as $budget_total |

    # Determine status
    (if $run_complete != null then "completed"
     elif ($running | length) > 0 then
       "running"
     else "idle"
     end) as $status |

    # Active agent description
    (if ($running | length) > 0 then ($running[0].agent) else null end) as $active_agent |

    {
      run_id: ($first.run_id // "unknown"),
      task: ($run_data.task // "unknown"),
      workflow: ($run_data.workflow // "unknown"),
      status: $status,
      phase: $current_phase,
      active_agent: $active_agent,
      start_ts: $start_ts,
      budget_used_usd: $budget_used,
      budget_total_usd: $budget_total,
      budget_percent: (if $budget_total != null and $budget_total > 0 then
        (($budget_used / $budget_total * 100) | floor)
      else null end),
      completed: $completed,
      running: $running,
      transitions: $transitions,
      verdicts: $verdicts,
      fixes_count: $fixes_count,
      latest_event: {
        seq: ($latest.seq // 0),
        type: ($latest.type // "unknown"),
        agent: ($latest.agent // null),
        phase: ($latest.phase // "unknown"),
        ts: ($latest.ts // "")
      },
      total_events: $total_events
    }
  ' "$EVENT_FILE"
}

generate_progress_markdown() {
  local progress_json
  progress_json=$(generate_progress_json)

  if echo "$progress_json" | jq -e '.error' > /dev/null 2>&1; then
    echo "Error: $(echo "$progress_json" | jq -r '.error')"
    return 1
  fi

  # Extract fields for the markdown template: one jq call; each field is what
  # "$(echo "$progress_json" | jq -r <field>)" gave (NUL-separated here).
  local run_id task workflow status phase active_agent start_ts
  local budget_used budget_total budget_percent total_events
  local latest_seq latest_type latest_agent latest_phase latest_ts
  local -a fields=()
  local field
  while IFS= read -r -d '' field; do fields+=("$field"); done < <(echo "$progress_json" | jq -j '
    def pp($i):
      if type == "object" then
        (if length == 0 then "{}" else
          "{\n" + ([to_entries[] | $i + "  " + (.key | tojson) + ": " + (.value | pp($i + "  "))] | join(",\n"))
          + "\n" + $i + "}" end)
      elif type == "array" then
        (if length == 0 then "[]" else
          "[\n" + (map($i + "  " + pp($i + "  ")) | join(",\n")) + "\n" + $i + "]" end)
      else tojson end;
    def rstrip_nl: if endswith("\n") then .[:-1] | rstrip_nl else . end;
    def cap: (if type == "string" then . else pp("") end)
      | (if contains("\u0000") then split("\u0000") | join("") else . end) | rstrip_nl;
    [.run_id, .task, .workflow, .status, .phase, (.active_agent // "none"), .start_ts,
     .budget_used_usd, .budget_total_usd, .budget_percent, .total_events,
     .latest_event.seq, .latest_event.type, (.latest_event.agent // "_"), .latest_event.phase,
     .latest_event.ts] | .[] | cap + "\u0000"' 2>/dev/null || true)
  run_id="${fields[0]:-}"
  task="${fields[1]:-}"
  workflow="${fields[2]:-}"
  status="${fields[3]:-}"
  phase="${fields[4]:-}"
  active_agent="${fields[5]:-}"
  start_ts="${fields[6]:-}"
  budget_used="${fields[7]:-}"
  budget_total="${fields[8]:-}"
  budget_percent="${fields[9]:-}"
  total_events="${fields[10]:-}"
  latest_seq="${fields[11]:-}"
  latest_type="${fields[12]:-}"
  latest_agent="${fields[13]:-}"
  latest_phase="${fields[14]:-}"
  latest_ts="${fields[15]:-}"

  # Calculate elapsed time
  local elapsed_display="n/a"
  if [[ -n "$start_ts" && "$start_ts" != "null" ]]; then
    local start_epoch now_epoch elapsed_s elapsed_min
    start_epoch=$(date -d "$start_ts" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_ts" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    start_epoch=$(af_as_int "$start_epoch")
    if [[ "$start_epoch" -gt 0 ]]; then
      elapsed_s=$(( now_epoch - start_epoch ))
      elapsed_min=$(( elapsed_s / 60 ))
      if [[ $elapsed_min -gt 0 ]]; then
        elapsed_display="${elapsed_min} min"
      else
        elapsed_display="${elapsed_s}s"
      fi
    fi
  fi

  # Status line
  local phase_upper
  phase_upper=$(echo "$phase" | tr '[:lower:]' '[:upper:]')
  local status_line="${phase_upper} phase"
  if [[ "$active_agent" != "none" && "$active_agent" != "null" ]]; then
    status_line="${status_line} — ${active_agent} running"
  fi
  if [[ "$status" == "completed" ]]; then
    status_line="Completed"
  fi

  # Budget line
  local budget_line
  if [[ "$budget_total" != "null" && "$budget_total" != "0" ]]; then
    budget_line="\$${budget_used} / \$${budget_total} (${budget_percent}%)"
  else
    budget_line="\$${budget_used} (no budget set)"
  fi

  # Start time display (HH:MM)
  local start_display="n/a"
  if [[ -n "$start_ts" && "$start_ts" != "null" ]]; then
    start_display=$(echo "$start_ts" | grep -o '[0-9][0-9]:[0-9][0-9]' | head -1 || echo "$start_ts")
  fi

  # Header
  cat <<EOF
# ArcheFlow Run: ${run_id}
**Status:** ${status_line}
**Started:** ${start_display} | **Elapsed:** ${elapsed_display}
**Budget:** ${budget_line}

## Progress
EOF

  # Build checklist from completed agents, transitions, verdicts, and running agents
  # Order: by seq number (chronological)

  # Completed agents
  echo "$progress_json" | jq -r '
    # Build sorted event list for the checklist
    (
      [.completed[] | {
        seq: .seq,
        line: ("- [x] " + (.phase | ascii_upcase) + ": " + .agent +
               " (" + (.duration_s | tostring) + "s, " +
               (if .tokens > 0 then ((.tokens / 1000 | floor | tostring) + "k tok, ") else "" end) +
               "$" + (.cost_usd | tostring) + ")")
      }] +
      [.transitions[] | {
        seq: .seq,
        line: ("- [x] " + (.from | ascii_upcase) + " -> " + (.to | ascii_upcase) + " transition")
      }] +
      [.verdicts[] | {
        seq: .seq,
        line: ("- [x] CHECK: " + .agent + " -> " + (.verdict | ascii_upcase | gsub("_"; " ")) +
               (if .findings_count > 0 then " (" + (.findings_count | tostring) + " findings)" else "" end))
      }] +
      [.running[] | {
        seq: .seq,
        line: ("- [ ] **" + (.phase | ascii_upcase) + ": " + .agent + "** <- running")
      }]
    ) | sort_by(.seq) | .[].line
  '

  echo ""

  # Latest event
  local latest_time
  latest_time=$(echo "$latest_ts" | grep -o '[0-9][0-9]:[0-9][0-9]' | head -1 || echo "$latest_ts")

  echo "## Latest Event"
  if [[ "$latest_agent" != "null" && "$latest_agent" != "_" ]]; then
    echo "#${latest_seq} ${latest_type} — ${latest_agent} (${latest_phase}) — ${latest_time}"
  else
    echo "#${latest_seq} ${latest_type} (${latest_phase}) — ${latest_time}"
  fi
  echo ""

  # DAG (delegate to archeflow-dag.sh if available)
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -x "${script_dir}/archeflow-dag.sh" && -f "$EVENT_FILE" ]]; then
    echo "## DAG"
    "${script_dir}/archeflow-dag.sh" "$EVENT_FILE" --no-color
  fi
}

# --- Mode dispatch ---

case "$MODE" in
  json)
    generate_progress_json
    ;;

  watch)
    while true; do
      clear
      if [[ -f "$EVENT_FILE" ]]; then
        generate_progress_markdown
        # Check if run is complete
        if jq -e 'select(.type == "run.complete")' "$EVENT_FILE" > /dev/null 2>&1; then
          echo ""
          echo "--- Run complete. Exiting watch mode. ---"
          exit 0
        fi
      else
        echo "Waiting for events: ${EVENT_FILE}"
      fi
      sleep 2
    done
    ;;

  default)
    if [[ ! -f "$EVENT_FILE" ]]; then
      echo "Error: Event file not found: $EVENT_FILE" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$PROGRESS_FILE")"
    af_refuse_symlink "$PROGRESS_FILE" || exit 1
    output=$(generate_progress_markdown)
    echo "$output" > "$PROGRESS_FILE"
    echo "$output"
    echo "[archeflow-progress] Updated ${PROGRESS_FILE}" >&2
    ;;
esac
