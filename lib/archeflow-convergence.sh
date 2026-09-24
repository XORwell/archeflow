#!/usr/bin/env bash
set -euo pipefail

# Convergence detection, oscillation analysis, and Wiggum Break logic.
# (Wiggum Break: the circuit breaker, see skills/shadow-detection/SKILL.md.)
#
# Usage:
#   archeflow-convergence.sh score <current-findings.json> <previous-findings.json>
#   archeflow-convergence.sh oscillation <cycle-n.json> <cycle-n-1.json> <cycle-n-2.json>
#   archeflow-convergence.sh wiggum-check <run_id | run-dir>
#
# Findings JSON format: array of objects with at least {id, file, category, severity}.
# The run skill writes one per cycle: .archeflow/artifacts/<run_id>/findings-cycle-<N>.json
#
# wiggum-check reads what a real run writes:
#   events:    .archeflow/events/<run_id>.jsonl (shadow.detected, agent.failed,
#              agent.timeout, decision what=post_merge_test chosen=revert, cost data)
#   artifacts: .archeflow/artifacts/<run_id>/ (findings-cycle-*.json,
#              convergence-cycle-*.json or cycle-*/convergence.json)
# It includes the oscillation check: with findings files for three consecutive
# cycles N-2, N-1, N (the last three), 2+ findings present in N-2, absent in N-1
# and present again in N are a hard break. Called with a run ID, a break is also
# logged as a wiggum.break event (data = the printed JSON).
#
# Exit codes: 0 = result (score computed, oscillation found, break triggered),
#             1 = no oscillation / no break, 2 = usage or input error.
#
# Dependencies: jq, bash 4+

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required. Install: https://jqlang.github.io/jq/" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    local code="${1:-2}"
    {
        echo "Usage:"
        echo "  archeflow-convergence.sh score <current.json> <previous.json>"
        echo "  archeflow-convergence.sh oscillation <cycle-n.json> <cycle-n-1.json> <cycle-n-2.json>"
        echo "  archeflow-convergence.sh wiggum-check <run_id | run-dir>"
        echo "Exit codes: 0 result/break found, 1 none found, 2 usage or input error."
    } >&2
    exit "$code"
}

# ============================================================
# Convergence score
#
# Classifies each finding as NEW, RESOLVED, PERSISTENT, or REGRESSED
# Score = resolved / (resolved + new + regressed)
# ============================================================

compute_score() {
    local current_file="$1"
    local previous_file="$2"

    [[ ! -f "$current_file" ]] && { echo "Error: $current_file not found" >&2; exit 2; }
    [[ ! -f "$previous_file" ]] && { echo "Error: $previous_file not found" >&2; exit 2; }

    local current_ids previous_ids
    current_ids=$(jq -r '.[].id' "$current_file" 2>/dev/null | sort)
    previous_ids=$(jq -r '.[].id' "$previous_file" 2>/dev/null | sort)

    local resolved=0 new_findings=0 persistent=0 regressed=0

    # RESOLVED: in previous but not in current
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if ! echo "$current_ids" | grep -qxF "$id"; then
            resolved=$((resolved + 1))
        else
            persistent=$((persistent + 1))
        fi
    done <<< "$previous_ids"

    # NEW: in current but not in previous
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if ! echo "$previous_ids" | grep -qxF "$id"; then
            new_findings=$((new_findings + 1))
        fi
    done <<< "$current_ids"

    # Convergence score
    local denominator=$((resolved + new_findings + regressed))
    local score="0.00"
    if [[ "$denominator" -gt 0 ]]; then
        score=$(awk "BEGIN {printf \"%.2f\", $resolved / $denominator}")
    elif [[ "$persistent" -eq 0 && "$resolved" -eq 0 && "$new_findings" -eq 0 ]]; then
        score="1.00"
    fi

    # Status
    local status="stuck"
    local action="stop_immediately"
    if (( $(awk "BEGIN {print ($score > 0.8) ? 1 : 0}") )); then
        status="converging"
        action="continue"
    elif (( $(awk "BEGIN {print ($score >= 0.5) ? 1 : 0}") )); then
        status="stalling"
        action="continue_with_caution"
    elif (( $(awk "BEGIN {print ($score > 0) ? 1 : 0}") )); then
        status="diverging"
        action="stop_if_2_consecutive"
    fi

    jq -n \
        --arg score "$score" \
        --arg status "$status" \
        --arg action "$action" \
        --argjson resolved "$resolved" \
        --argjson new "$new_findings" \
        --argjson persistent "$persistent" \
        --argjson regressed "$regressed" \
        '{
            convergence_score: ($score | tonumber),
            status: $status,
            action: $action,
            resolved: $resolved,
            new: $new,
            persistent: $persistent,
            regressed: $regressed
        }'
}

# ============================================================
# Oscillation detection
#
# A finding is oscillating if present in cycle N-2, absent in N-1,
# and present again in N.
# ============================================================

# oscillating_ids <cycle-n.json> <cycle-n-1.json> <cycle-n-2.json>: one id per line.
oscillating_ids() {
    local ids_n ids_n1 ids_n2 id
    ids_n=$(jq -r '.[]?.id? | strings' "$1" 2>/dev/null | sort)
    ids_n1=$(jq -r '.[]?.id? | strings' "$2" 2>/dev/null | sort)
    ids_n2=$(jq -r '.[]?.id? | strings' "$3" 2>/dev/null | sort)
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if ! grep -qxF -- "$id" <<<"$ids_n1" && grep -qxF -- "$id" <<<"$ids_n"; then
            printf '%s\n' "$id"
        fi
    done <<< "$ids_n2"
}

detect_oscillation() {
    local cycle_n="$1"
    local cycle_n1="$2"
    local cycle_n2="$3"

    [[ ! -f "$cycle_n" ]] && { echo "Error: $cycle_n not found" >&2; exit 2; }
    [[ ! -f "$cycle_n1" ]] && { echo "Error: $cycle_n1 not found" >&2; exit 2; }
    [[ ! -f "$cycle_n2" ]] && { echo "Error: $cycle_n2 not found" >&2; exit 2; }

    local ids_n ids_n1 ids_n2
    ids_n=$(jq -r '.[].id' "$cycle_n" 2>/dev/null | sort)
    ids_n1=$(jq -r '.[].id' "$cycle_n1" 2>/dev/null | sort)
    ids_n2=$(jq -r '.[].id' "$cycle_n2" 2>/dev/null | sort)

    local oscillating=()

    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        local in_n1
        in_n1=$(echo "$ids_n1" | grep -cxF "$id" 2>/dev/null) || in_n1=0
        local in_n
        in_n=$(echo "$ids_n" | grep -cxF "$id" 2>/dev/null) || in_n=0

        if [[ "$in_n1" -eq 0 && "$in_n" -gt 0 ]]; then
            oscillating+=("$id")
        fi
    done <<< "$ids_n2"

    local count=${#oscillating[@]}

    if [[ "$count" -ge 2 ]]; then
        jq -n \
            --argjson count "$count" \
            --argjson ids "$(printf '%s\n' "${oscillating[@]}" | jq -R . | jq -s .)" \
            '{
                oscillation_detected: true,
                count: $count,
                finding_ids: $ids,
                action: "hard_wiggum_break",
                reason: "2+ oscillating findings — fundamental tension in review criteria"
            }'
        return 0
    else
        jq -n '{oscillation_detected: false, count: 0}'
        return 1
    fi
}

# ============================================================
# Wiggum Break check
#
# Scans a run directory for conditions that trigger hard or soft breaks.
# ============================================================

# resolve_run <run_id | run-dir>: sets RUN_DIR (artifacts) and EVENT_FILE.
#   run ID -> .archeflow/artifacts/<id>/ and .archeflow/events/<id>.jsonl
#   dir    -> <dir>/ and <dir>/events.jsonl if present, else
#             <dir>/../../events/<basename>.jsonl (dir = .archeflow/artifacts/<id>)
resolve_run() {
    local arg="$1" base
    RUN_DIR="" EVENT_FILE=""
    if [[ -d "$arg" ]]; then
        RUN_DIR="$arg"
        base="$(basename "$arg")"
        if [[ -f "$arg/events.jsonl" ]]; then
            EVENT_FILE="$arg/events.jsonl"
        elif [[ "$base" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$base" != *..* && -f "$arg/../../events/$base.jsonl" ]]; then
            EVENT_FILE="$arg/../../events/$base.jsonl"
        fi
        return 0
    fi
    if [[ "$arg" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$arg" != *..* ]]; then
        RUN_DIR=".archeflow/artifacts/$arg"
        EVENT_FILE=".archeflow/events/$arg.jsonl"
        [[ -f "$EVENT_FILE" ]] || EVENT_FILE=""
        [[ -d "$RUN_DIR" ]] || RUN_DIR=""
        if [[ -n "$RUN_DIR" || -n "$EVENT_FILE" ]]; then
            return 0
        fi
    fi
    echo "Error: $arg not found (neither a run directory nor a run ID with .archeflow/events/$arg.jsonl)" >&2
    exit 2
}

wiggum_check() {
    resolve_run "$1"
    local run_dir="$RUN_DIR"
    local event_file="$EVENT_FILE"

    local breaks=()
    local break_type="none"

    if [[ -n "$event_file" ]]; then
        # Hard: the SAME shadow (archetype + shadow name) detected 3+ times in
        # ONE cycle. Cycle = .data.cycle // .cycle; events without a cycle
        # field count as cycle 1.
        local same_shadow
        same_shadow=$(jq -rs '
            [ .[] | select(.type == "shadow.detected")
              | { c: ((.data.cycle // .cycle // 1) | tostring),
                  k: ((.data.archetype // .agent // "?") + "/" + (.data.shadow // "?")) } ]
            | group_by([.c, .k]) | map(select(length >= 3))
            | map("\(.[0].k) x\(length) in cycle \(.[0].c)") | first // empty
        ' "$event_file" 2>/dev/null) || same_shadow=""
        if [[ -n "$same_shadow" ]]; then
            breaks+=("hard|Same shadow detected 3+ times in one cycle ($same_shadow)")
            break_type="hard"
        fi

        # Hard: 3 CONSECUTIVE agent failures/timeouts: longest run of
        # agent.failed / agent.timeout events in file order, reset by any
        # agent.complete.
        local failure_streak
        failure_streak=$(jq -rs '
            reduce (.[] | .type) as $t ({cur: 0, max: 0};
                if $t == "agent.failed" or $t == "agent.timeout" then
                    .cur += 1 | .max = ([.max, .cur] | max)
                elif $t == "agent.complete" then .cur = 0
                else . end) | .max
        ' "$event_file" 2>/dev/null) || failure_streak=0
        [[ "$failure_streak" =~ ^[0-9]+$ ]] || failure_streak=0
        if [[ "$failure_streak" -ge 3 ]]; then
            breaks+=("hard|$failure_streak consecutive agent failures/timeouts")
            break_type="hard"
        fi

        # Hard: test suite broken after merge. archeflow-rollback.sh logs a
        # decision event (what=post_merge_test, chosen=revert) when it reverts.
        local reverted
        reverted=$(jq -rs '[ .[] | select(.type == "decision"
                     and (.data.what // "") == "post_merge_test"
                     and (.data.chosen // "") == "revert") ] | length' "$event_file" 2>/dev/null) || reverted=0
        [[ "$reverted" =~ ^[0-9]+$ ]] || reverted=0
        if [[ "$reverted" -gt 0 ]]; then
            breaks+=("hard|Test suite broken after merge (merge reverted)")
            break_type="hard"
        fi
    fi

    # Hard: 2+ oscillating findings over the last three cycles' findings files
    # (findings-cycle-<N-2>.json, <N-1>, <N>; consecutive cycle numbers only).
    if [[ -n "$run_dir" ]]; then
        local osc_files osc_n=() f num
        osc_files=$(find "$run_dir" -maxdepth 1 -name "findings-cycle-*.json" 2>/dev/null | sort -V | tail -3)
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            num="${f##*findings-cycle-}"; num="${num%.json}"
            [[ "$num" =~ ^[0-9]+$ ]] && osc_n+=("$num")
        done <<< "$osc_files"
        if [[ ${#osc_n[@]} -eq 3 ]] \
           && [[ "$((10#${osc_n[1]}))" -eq "$((10#${osc_n[0]} + 1))" && "$((10#${osc_n[2]}))" -eq "$((10#${osc_n[1]} + 1))" ]]; then
            local osc
            osc=$(oscillating_ids "$run_dir/findings-cycle-${osc_n[2]}.json" \
                  "$run_dir/findings-cycle-${osc_n[1]}.json" "$run_dir/findings-cycle-${osc_n[0]}.json")
            local osc_count
            osc_count=$(printf '%s' "$osc" | grep -c . || true)
            if [[ "$osc_count" -ge 2 ]]; then
                breaks+=("hard|$osc_count findings oscillate across cycles ${osc_n[0]}-${osc_n[2]} ($(tr '\n' ' ' <<<"$osc" | sed 's/ $//'))")
                break_type="hard"
            fi
        fi
    fi

    # Hard: legacy marker file for a broken post-merge test suite
    if [[ -n "$run_dir" && -f "$run_dir/post-merge-test-result" ]]; then
        if [[ "$(cat "$run_dir/post-merge-test-result")" == "FAILED" ]]; then
            breaks+=("hard|Test suite broken after merge")
            break_type="hard"
        fi
    fi

    # Soft: convergence < 0.5 for 2 consecutive cycles
    # (convergence-cycle-<N>.json, or cycle-<N>/convergence.json)
    local conv_files=""
    if [[ -n "$run_dir" ]]; then
        conv_files=$(find "$run_dir" \( -name "convergence.json" -o -name "convergence-cycle-*.json" \) 2>/dev/null | sort -V)
    fi
    local consecutive_diverging=0 cf
    while IFS= read -r cf; do
        [[ -z "$cf" ]] && continue
        local score
        score=$(jq -r '.convergence_score // 1' "$cf" 2>/dev/null || echo "1")
        # Non-numeric scores (null, garbage) count as converging, not as 0.
        [[ "$score" =~ ^[0-9]*\.?[0-9]+$ ]] || score=1
        if awk -v s="$score" 'BEGIN {exit !(s < 0.5)}'; then
            consecutive_diverging=$((consecutive_diverging + 1))
        else
            consecutive_diverging=0
        fi
    done <<< "$conv_files"

    if [[ "$consecutive_diverging" -ge 2 && "$break_type" != "hard" ]]; then
        breaks+=("soft|Convergence <0.5 for $consecutive_diverging consecutive cycles")
        break_type="soft"
    fi

    # Soft: findings unchanged between consecutive cycles
    local findings_files=""
    if [[ -n "$run_dir" ]]; then
        findings_files=$(find "$run_dir" -name "findings-cycle-*.json" 2>/dev/null | sort -V)
    fi
    local prev_hash="" ff
    while IFS= read -r ff; do
        [[ -z "$ff" ]] && continue
        local curr_ids curr_hash
        curr_ids=$(jq -r '.[].id' "$ff" 2>/dev/null | sort)
        # No open findings is not "stuck": never compare empty cycles.
        if [[ -z "$curr_ids" ]]; then
            prev_hash=""
            continue
        fi
        curr_hash=$(printf '%s\n' "$curr_ids" | cksum)
        if [[ -n "$prev_hash" && "$curr_hash" == "$prev_hash" && "$break_type" != "hard" ]]; then
            breaks+=("soft|Findings unchanged between consecutive cycles")
            break_type="soft"
            break
        fi
        prev_hash="$curr_hash"
    done <<< "$findings_files"

    # Soft: budget >95% spent
    if [[ -n "$event_file" ]]; then
        local total_cost
        total_cost=$(jq -rs '[ .[] | (.data.estimated_cost_usd? // empty) | numbers ] | add // 0' \
            "$event_file" 2>/dev/null) || total_cost=0
        [[ "$total_cost" =~ ^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]] || total_cost=0
        # Budget: costs.budget_usd from the project config.
        local budget="" cfg
        for cfg in ".archeflow/config.yaml" "${run_dir:-.}/../config.yaml" "${run_dir:-.}/../../config.yaml"; do
            [[ -f "$cfg" ]] || continue
            budget=$(grep -E '^[[:space:]]*budget_usd:' "$cfg" 2>/dev/null | head -1 \
                | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/["'"'"']//g') || budget=""
            [[ -n "$budget" ]] && break
        done
        [[ "$budget" =~ ^[0-9]*\.?[0-9]+$ ]] || budget=0

        if awk -v b="$budget" 'BEGIN {exit !(b > 0)}'; then
            local spent_pct
            spent_pct=$(awk -v c="$total_cost" -v b="$budget" 'BEGIN {printf "%.0f", (c / b) * 100}')
            if [[ "$spent_pct" -ge 95 && "$break_type" != "hard" ]]; then
                total_cost=$(awk -v c="$total_cost" 'BEGIN {printf "%.2f", c}')
                breaks+=("soft|Budget >95% spent (\$$total_cost of \$$budget, ${spent_pct}%)")
                break_type="soft"
            fi
        fi
    fi

    if [[ ${#breaks[@]} -eq 0 ]]; then
        jq -n '{wiggum_break: false}'
        return 1
    fi

    local break_json out
    break_json=$(printf '%s\n' "${breaks[@]}" | jq -R 'index("|") as $i | {type: .[:$i], reason: .[$i + 1:]}' | jq -s .)

    out=$(jq -n \
        --arg break_type "$break_type" \
        --argjson triggers "$break_json" \
        '{
            wiggum_break: true,
            type: $break_type,
            triggers: $triggers
        }')
    echo "$out"

    # Log the break when called with a run ID (a directory argument is not a run).
    if [[ ! -d "$1" && -x "$SCRIPT_DIR/archeflow-event.sh" ]]; then
        "$SCRIPT_DIR/archeflow-event.sh" "$1" wiggum.break act "" "$(jq -c . <<<"$out")" >/dev/null 2>&1 || true
    fi
    return 0
}

# ============================================================
# Main dispatch
# ============================================================

main() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        -h|--help)
            usage 0
            ;;
        score)
            [[ $# -lt 2 ]] && usage
            compute_score "$1" "$2"
            ;;
        oscillation)
            [[ $# -lt 3 ]] && usage
            detect_oscillation "$1" "$2" "$3"
            ;;
        wiggum-check)
            [[ $# -lt 1 ]] && usage
            wiggum_check "$1"
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"
