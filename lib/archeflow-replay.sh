#!/usr/bin/env bash
# archeflow-replay.sh — Inspect recorded runs: decision timeline and weighted what-if replay.
#
# Usage:
#   archeflow-replay.sh timeline <run_id>
#   archeflow-replay.sh whatif <run_id> [--weights arch=w,arch2=w2] [--threshold 0.5] [--json]
#   archeflow-replay.sh compare <run_id> [--weights ...] [--threshold ...] [--json]
#
# Events file: .archeflow/events/<run_id>.jsonl (relative to current working directory)
#
# whatif / compare:
#   - Loads check-phase review.verdict events (last verdict per archetype).
#   - Original gate (strict): BLOCK if any reviewer is not approved.
#   - Replay gate (weighted): BLOCK if sum(weight * strict) / sum(weight) >= threshold,
#     where strict=1 for non-approved verdicts, else 0. Default weight per archetype is 1.0.
#
# Requires: jq
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

# shellcheck source=lib/archeflow-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archeflow-common.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 {timeline|whatif|compare} <run_id> [options]" >&2
  echo "" >&2
  echo "  timeline <run_id>              Decision timeline (decision.point + review.verdict)" >&2
  echo "  whatif <run_id> [--weights k=v,...] [--threshold 0.5] [--json]" >&2
  echo "  compare <run_id>  (timeline + whatif summary)" >&2
  exit 1
fi

COMMAND="$1"
RUN_ID="$2"
shift 2
# Run IDs become file names under .archeflow/ (and git branch names).
af_require_run_id "$RUN_ID"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required." >&2
  exit 1
fi

EVENT_FILE=".archeflow/events/${RUN_ID}.jsonl"

resolve_event_file() {
  if [[ ! -f "$EVENT_FILE" ]]; then
    echo "Error: event file not found: $EVENT_FILE" >&2
    exit 1
  fi
}

cmd_timeline() {
  resolve_event_file
  echo "## Decision timeline — run_id=${RUN_ID}"
  echo ""
  local cnt
  cnt=$(jq -s '[.[] | select(.type == "decision.point")] | length' "$EVENT_FILE")
  if [[ "$cnt" -gt 0 ]]; then
    echo "### decision.point (${cnt})"
    jq -r 'select(.type == "decision.point")
      | "- \(.ts)  [\(.phase)] \(.data.archetype // .agent // "?")  \(.data.decision)  conf=\(.data.confidence // "n/a")  input=\(.data.input // "")"' \
      "$EVENT_FILE"
    echo ""
  else
    echo "### decision.point"
    echo "(none — emit with ./lib/archeflow-decision.sh during the run)"
    echo ""
  fi

  echo "### review.verdict (check phase)"
  if jq -e -s '[.[] | select(.type == "review.verdict" and .phase == "check")] | length > 0' "$EVENT_FILE" >/dev/null 2>&1; then
    jq -r 'select(.type == "review.verdict" and .phase == "check")
      | "- \(.ts)  \(.data.archetype // .agent // "?")  verdict=\(.data.verdict)  findings=\((.data.findings // []) | length)"' \
      "$EVENT_FILE"
  else
    echo "(none)"
  fi
  echo ""
}

parse_weights_to_json() {
  local raw="${1:-}"
  local obj='{}'
  if [[ -z "$raw" ]]; then
    echo '{}'
    return
  fi
  IFS=',' read -ra pairs <<< "$raw"
  for pair in "${pairs[@]}"; do
    [[ -z "$pair" ]] && continue
    local k="${pair%%=*}"
    local v="${pair#*=}"
    k=$(echo "$k" | tr '[:upper:]' '[:lower:]' | xargs)
    v=$(echo "$v" | xargs)
    if [[ -z "$k" || "$k" == "$pair" ]]; then
      echo "Error: invalid weight entry (use arch=1.5): $pair" >&2
      exit 1
    fi
    obj=$(echo "$obj" | jq --arg k "$k" --argjson v "$v" '. + {($k): $v}')
  done
  echo "$obj"
}

cmd_whatif() {
  local weights_str=""
  local threshold="0.5"
  local json_out="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --weights)
        weights_str="$2"
        shift 2
        ;;
      --threshold)
        threshold="$2"
        shift 2
        ;;
      --json)
        json_out="true"
        shift
        ;;
      *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  resolve_event_file
  local weights_json
  weights_json="$(parse_weights_to_json "$weights_str")"

  local result
  result=$(jq -s --argjson weights "$weights_json" --argjson thr "$threshold" --arg run_id "$RUN_ID" '
    def strict($v):
      if $v == null then 1
      else ($v | ascii_downcase) as $lv
      | if ($lv == "approved" or $lv == "approve") then 0 else 1 end
      end;

    def norm_key: ascii_downcase;

    ([.[] | select(.type == "review.verdict" and .phase == "check")]
      | sort_by(.seq)
      | reduce .[] as $e ({}; . + { (($e.data.archetype // $e.agent // "unknown") | norm_key): $e })
    ) as $last |

    ($last | keys) as $keys |
    if ($keys | length) == 0 then
      {
        run_id: $run_id,
        error: "no check-phase review.verdict events; nothing to simulate"
      }
    else
      [ $keys[] as $k | $last[$k] as $ev |
        ($weights[($k | norm_key)] // 1.0) as $w
        | strict($ev.data.verdict) as $s
        | {
            archetype: ($ev.data.archetype // $ev.agent // $k),
            verdict: ($ev.data.verdict // "unknown"),
            weight: $w,
            strict: $s,
            weighted_contrib: ($w * $s)
          }
      ] as $rows |
      ($rows | map(.weighted_contrib) | add) as $num |
      ($rows | map(.weight) | add) as $den |
      (if $den > 0 then ($num / $den) else 0 end) as $ratio |
      (if ($rows | map(.strict) | max) == 1 then "BLOCK" else "SHIP" end) as $strict_out |
      (if $ratio >= $thr then "BLOCK" else "SHIP" end) as $replay_out |
      {
        run_id: $run_id,
        threshold: $thr,
        weights_used: $weights,
        strict_any_veto: {
          outcome: $strict_out,
          description: "BLOCK if any reviewer verdict is not approved"
        },
        weighted_replay: {
          weighted_strictness: ($ratio * 1000 | round / 1000),
          outcome: $replay_out,
          description: ("BLOCK if weighted strictness >= " + ($thr | tostring))
        },
        reviewers: $rows
      }
    end
  ' "$EVENT_FILE")

  if [[ "$json_out" == "true" ]]; then
    echo "$result"
  else
    echo "$result" | jq -r '
      if .error then "Error: \(.error)" else
        "# What-if replay — run_id=\(.run_id)\n",
        "",
        "## Outcomes",
        "| Model | Result |",
        "|-------|--------|",
        "| Original (any non-approve → BLOCK) | \(.strict_any_veto.outcome) |",
        "| Weighted replay (threshold=\(.threshold)) | \(.weighted_replay.outcome) |",
        "",
        "## Weighted strictness",
        "\(.weighted_replay.weighted_strictness)  (0 = all approved, 1 = all blocking)",
        "",
        "## Per reviewer",
        "| Archetype | Verdict | Weight | Strict | w×strict |",
        "|-----------|---------|--------|--------|----------|",
        (.reviewers[] | "| \(.archetype) | \(.verdict) | \(.weight) | \(.strict) | \(.weighted_contrib) |"),
        "",
        (if (.weights_used | length) > 0 then
          "## Custom weights applied\n" + (.weights_used | to_entries | map("- \(.key): \(.value)") | join("\n")) + "\n"
        else empty end)
      end
    '
  fi
}

cmd_compare() {
  cmd_timeline
  echo ""
  cmd_whatif "$@"
}

case "$COMMAND" in
  timeline) cmd_timeline ;;
  whatif)   cmd_whatif "$@" ;;
  compare)  cmd_compare "$@" ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    exit 1
    ;;
esac
