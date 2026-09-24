#!/usr/bin/env bash
# archeflow-score.sh — Archetype effectiveness scoring for ArcheFlow orchestrations.
#
# Usage:
#   archeflow-score.sh extract <events.jsonl>     # Score archetypes from a completed run
#   archeflow-score.sh report                     # Show aggregate effectiveness report
#   archeflow-score.sh recommend <team.yaml>      # Recommend model tiers for a team
#
# Scores review archetypes (Guardian, Sage, Skeptic, Trickster, etc.) on signal-to-noise,
# fix rate, cost efficiency, accuracy, and cycle impact. Stores per-run scores in
# .archeflow/memory/effectiveness.jsonl and produces aggregate reports with recommendations.
#
# Requires: jq
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

# shellcheck source=lib/archeflow-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archeflow-common.sh"
# Refuse a symlinked .archeflow/ (or events/, runs/, memory/ ...): writes would land outside the repo.
af_check_state_dirs

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <command> [args...]" >&2
  echo "" >&2
  echo "Commands:" >&2
  echo "  extract <events.jsonl>   Score archetypes from a completed run" >&2
  echo "  report                   Show aggregate effectiveness report" >&2
  echo "  recommend <team.yaml>    Recommend model tiers for a team" >&2
  exit 1
fi

COMMAND="$1"
shift

if ! command -v jq &> /dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

MEMORY_DIR=".archeflow/memory"
EFFECTIVENESS_FILE="${MEMORY_DIR}/effectiveness.jsonl"

# --- extract: score archetypes from a completed run ---

cmd_extract() {
  local event_file="${1:?Usage: $0 extract <events.jsonl>}"

  if [[ ! -f "$event_file" ]]; then
    echo "Error: Event file not found: $event_file" >&2
    exit 1
  fi

  # Verify run is complete
  if ! jq -e 'select(.type == "run.complete")' "$event_file" > /dev/null 2>&1; then
    echo "Error: No run.complete event found. Scoring incomplete runs is unreliable." >&2
    exit 1
  fi

  mkdir -p "$MEMORY_DIR"

  # Extract run metadata
  local run_id
  run_id=$(jq -r 'select(.type == "run.start") | .run_id' "$event_file" | head -1)
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Score each review archetype using jq
  # This processes all events in a single jq pass for efficiency
  jq -sc --arg run_id "$run_id" --arg ts "$ts" '

    # Collect review verdicts
    [.[] | select(.type == "review.verdict")] as $verdicts |

    # Collect fixes
    [.[] | select(.type == "fix.applied")] as $fixes |

    # Collect agent.complete for cost data
    [.[] | select(.type == "agent.complete")] as $completions |

    # Collect cycle boundaries
    [.[] | select(.type == "cycle.boundary")] as $cycles |

    # Final cycle exit status
    ($cycles | last // {data:{}}) as $final_cycle |
    ($final_cycle.data.met // false) as $cycle_exited |

    # Get unique review archetypes
    [$verdicts[] | (.data.archetype // .agent // "unknown")] | unique | .[] |

    . as $arch |

    # This archetype verdicts
    [$verdicts[] | select((.data.archetype // .agent) == $arch)] as $arch_verdicts |

    # All findings from this archetype
    [$arch_verdicts[] | .data.findings // [] | .[]] as $all_findings |
    ($all_findings | length) as $total_findings |

    # Useful findings: severity >= WARNING and fix_required
    [$all_findings[] | select(
      (.severity == "warning" or .severity == "bug" or .severity == "critical") and
      (.fix_required == true)
    )] as $useful_findings |
    ($useful_findings | length) as $useful_count |

    # Signal-to-noise
    (if $total_findings > 0 then ($useful_count / $total_findings) else 0 end) as $signal_noise |

    # Fixes applied from this archetype
    [$fixes[] | select(.data.source == $arch)] as $arch_fixes |
    ($arch_fixes | length) as $fix_count |

    # Fix rate
    (if $total_findings > 0 then ($fix_count / $total_findings) else 0 end) as $fix_rate |

    # Cost from agent.complete
    ([$completions[] | select((.data.archetype // .agent) == $arch)] | last // {data:{}}) as $completion |
    ($completion.data.estimated_cost_usd // $completion.data.cost_usd // 0) as $cost_usd |
    ($completion.data.tokens // (($completion.data.tokens_input // 0) + ($completion.data.tokens_output // 0))) as $tokens |
    ($completion.data.model // "unknown") as $model |

    # Cost efficiency: useful findings per dollar (normalized to 0-1 via /100 cap)
    (if $cost_usd > 0 then ($useful_count / $cost_usd) else 0 end) as $raw_cost_eff |
    ([1.0, ($raw_cost_eff / 100)] | min) as $cost_eff_norm |

    # Accuracy: 1 - (contradicted / total)
    # Approximation: count other archetypes that approved with 0 findings
    ([$verdicts[] | select(
      ((.data.archetype // .agent) != $arch) and
      (.data.verdict == "approved") and
      ((.data.findings // []) | length == 0)
    )] | length) as $contradictors |
    (if $total_findings > 0 and $contradictors > 0 then
      (1 - ([1.0, ($contradictors / ($verdicts | length))] | min) * 0.5)
    else 1.0 end) as $accuracy |

    # Cycle impact: did fixes from this archetype contribute to cycle exit?
    (if $cycle_exited and $fix_count > 0 then true else false end) as $cycle_impact |
    (if $cycle_impact then 1.0 else 0.0 end) as $cycle_impact_score |

    # Composite score
    (
      ($signal_noise * 0.30) +
      ($fix_rate * 0.25) +
      ($cost_eff_norm * 0.20) +
      ($accuracy * 0.15) +
      ($cycle_impact_score * 0.10)
    ) as $composite |

    {
      ts: $ts,
      run_id: $run_id,
      archetype: $arch,
      signal_to_noise: ($signal_noise * 100 | round / 100),
      fix_rate: ($fix_rate * 100 | round / 100),
      cost_efficiency: ($raw_cost_eff * 10 | round / 10),
      accuracy: ($accuracy * 100 | round / 100),
      cycle_impact: $cycle_impact,
      composite_score: ($composite * 100 | round / 100),
      tokens: $tokens,
      cost_usd: $cost_usd,
      model: $model,
      findings_total: $total_findings,
      findings_useful: $useful_count,
      fixes_applied: $fix_count
    }
  ' "$event_file" | while IFS= read -r score_line; do
    # Append each score as a single JSONL line
    af_append "$EFFECTIVENESS_FILE" "$score_line" || exit 1
    local arch
    arch=$(echo "$score_line" | jq -r '.archetype')
    local composite
    composite=$(echo "$score_line" | jq -r '.composite_score')
    echo "[archeflow-score] Scored ${arch}: composite=${composite}" >&2
  done

  echo "[archeflow-score] Scores appended to ${EFFECTIVENESS_FILE}" >&2
}

# --- report: show aggregate effectiveness report ---

cmd_report() {
  if [[ ! -f "$EFFECTIVENESS_FILE" ]]; then
    echo "No effectiveness data found at ${EFFECTIVENESS_FILE}" >&2
    echo "Run 'archeflow-score.sh extract <events.jsonl>' after completing runs." >&2
    exit 1
  fi

  echo "# Archetype Effectiveness Report"
  echo ""
  echo "| Archetype | Runs | Avg Score | S/N | Fix Rate | Cost Eff | Accuracy | Trend | Rec |"
  echo "|-----------|------|-----------|-----|----------|----------|----------|-------|-----|"

  # Process aggregates with jq
  jq -s '
    group_by(.archetype) | .[] |
    . as $group |
    (.[0].archetype) as $arch |
    (length) as $total_runs |

    # Last 10 runs
    (if length > 10 then .[-10:] else . end) as $recent |

    # Averages over recent
    ($recent | map(.composite_score) | add / length * 100 | round / 100) as $avg_composite |
    ($recent | map(.signal_to_noise) | add / length * 100 | round / 100) as $avg_sn |
    ($recent | map(.fix_rate) | add / length * 100 | round / 100) as $avg_fix |
    ($recent | map(.cost_efficiency) | add / length * 10 | round / 10) as $avg_cost_eff |
    ($recent | map(.accuracy) | add / length * 100 | round / 100) as $avg_acc |

    # Trend: last 5 vs prior 5
    (if ($recent | length) >= 10 then
      (($recent[-5:] | map(.composite_score) | add / length) -
       ($recent[-10:-5] | map(.composite_score) | add / length)) as $delta |
      if $delta > 0.05 then "improving"
      elif $delta < -0.05 then "declining"
      else "stable"
      end
    else "n/a"
    end) as $trend |

    # Recommendation
    (if $avg_composite >= 0.70 then "keep"
     elif $avg_composite >= 0.40 then "optimize"
     else "consider_removing"
     end) as $rec |

    # Most common model
    ($recent | group_by(.model) | sort_by(-length) | .[0][0].model // "unknown") as $model |

    {
      archetype: $arch,
      runs: $total_runs,
      avg_composite: $avg_composite,
      avg_sn: $avg_sn,
      avg_fix: $avg_fix,
      avg_cost_eff: $avg_cost_eff,
      avg_acc: $avg_acc,
      trend: $trend,
      rec: $rec,
      model: $model,
      avg_cost: ($recent | map(.cost_usd) | add / length * 10000 | round / 10000)
    }
  ' "$EFFECTIVENESS_FILE" | jq -r '
    "| \(.archetype) | \(.runs) | \(.avg_composite) | \(.avg_sn) | \(.avg_fix) | \(.avg_cost_eff) | \(.avg_acc) | \(.trend) | \(.rec) |"
  '

  echo ""

  # Model suggestions
  echo "**Model suggestions:**"
  jq -s '
    group_by(.archetype) | .[] |
    (.[0].archetype) as $arch |
    (if length > 10 then .[-10:] else . end) as $recent |
    ($recent | map(.composite_score) | add / length * 100 | round / 100) as $avg |
    ($recent | group_by(.model) | sort_by(-length) | .[0][0].model // "unknown") as $model |
    ($recent | map(.cost_usd) | add / length * 10000 | round / 10000) as $avg_cost |

    if $avg >= 0.70 and ($model == "haiku") then
      "- \($arch) (\($model), score \($avg)): Keep \($model) — high effectiveness at low cost"
    elif $avg < 0.50 and ($model == "haiku") then
      "- \($arch) (\($model), score \($avg)): Consider upgrading to sonnet or tightening review lens"
    elif $avg >= 0.70 and ($model == "sonnet") then
      "- \($arch) (\($model), score \($avg)): Try downgrading to haiku — may maintain quality at lower cost"
    elif $avg < 0.50 and ($model == "sonnet") then
      "- \($arch) (\($model), score \($avg)): Consider removing — expensive and not contributing"
    else
      "- \($arch) (\($model), score \($avg)): No change recommended"
    end
  ' "$EFFECTIVENESS_FILE" | jq -r '.'
}

# --- recommend: suggest model tiers for a team ---

cmd_recommend() {
  local team_file="${1:?Usage: $0 recommend <team.yaml>}"

  if [[ ! -f "$team_file" ]]; then
    echo "Error: Team file not found: $team_file" >&2
    exit 1
  fi

  if [[ ! -f "$EFFECTIVENESS_FILE" ]]; then
    echo "No effectiveness data found. Cannot make recommendations without historical data." >&2
    exit 1
  fi

  # Extract archetypes from the team YAML (grep-based on purpose: "yq" is two
  # incompatible tools depending on the host, see archeflow-init.sh)
  local archetypes=""
  if [[ -z "${archetypes:-}" ]]; then
    # Fallback: grep for archetype names from the YAML
    archetypes=$(grep -E '(archetype:|^[[:space:]]*-[[:space:]])' "$team_file" | sed 's/.*archetype:[[:space:]]*//' | sed 's/^[[:space:]]*-[[:space:]]*//' | grep -o '[a-zA-Z_][a-zA-Z0-9_]*' || true)
  fi

  if [[ -z "$archetypes" ]]; then
    echo "Error: Could not extract archetypes from ${team_file}" >&2
    exit 1
  fi

  local team_name
  team_name=$(grep '^name:' "$team_file" | head -1 | sed 's/^name:[[:space:]]*//' || echo "unknown")

  echo "# Model Recommendations for team: ${team_name}"
  echo ""
  echo "| Archetype | Current Model | Score | Suggestion |"
  echo "|-----------|--------------|-------|------------|"

  for arch in $archetypes; do
    # Look up effectiveness for this archetype
    local score_data
    score_data=$(jq -s --arg arch "$arch" '
      [.[] | select(.archetype == $arch)] |
      if length == 0 then null
      else
        (if length > 10 then .[-10:] else . end) as $recent |
        {
          avg_composite: ($recent | map(.composite_score | numbers) | if length == 0 then 0 else add / length * 100 | round / 100 end),
          model: ($recent | group_by(.model) | sort_by(-length) | .[0][0].model // "unknown"),
          runs: length
        }
      end
    ' "$EFFECTIVENESS_FILE" 2>/dev/null)

    if [[ "$score_data" == "null" ]]; then
      echo "| ${arch} | unknown | n/a | No data — run more orchestrations first |"
      continue
    fi

    local model avg runs suggestion tier
    model=$(echo "$score_data" | jq -r '.model')
    avg=$(echo "$score_data" | jq -r '.avg_composite')
    runs=$(echo "$score_data" | jq -r '.runs')
    # Compare in jq: effectiveness.jsonl may be repository-supplied, so its
    # values never reach shell arithmetic (and no bc dependency).
    tier=$(echo "$score_data" | jq -r '(.avg_composite | numbers) // 0 | if . >= 0.70 then "high" elif . >= 0.40 then "mid" else "low" end')

    # Generate suggestion
    if [[ "$tier" == "high" ]]; then
      if [[ "$model" == "haiku" ]]; then
        suggestion="Keep haiku — high effectiveness at low cost"
      elif [[ "$model" == "sonnet" ]]; then
        suggestion="Try haiku — may maintain quality cheaper"
      else
        suggestion="Keep current model — performing well"
      fi
    elif [[ "$tier" == "mid" ]]; then
      if [[ "$model" == "haiku" ]]; then
        suggestion="Try sonnet — may improve signal quality"
      else
        suggestion="Optimize review lens — moderate effectiveness"
      fi
    else
      suggestion="Consider removing from team — low effectiveness"
    fi

    echo "| ${arch} | ${model} | ${avg} (${runs} runs) | ${suggestion} |"
  done
}

# --- Dispatch ---

case "$COMMAND" in
  extract)   cmd_extract "$@" ;;
  report)    cmd_report "$@" ;;
  recommend) cmd_recommend "$@" ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    echo "Usage: $0 {extract|report|recommend} [args...]" >&2
    exit 1
    ;;
esac
