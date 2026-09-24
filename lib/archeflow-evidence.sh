#!/usr/bin/env bash
# archeflow-evidence.sh — Evidence validation for reviewer findings.
# Downgrades CRITICAL/WARNING findings to INFO when they contain
# hedging phrases without evidence or lack any supporting evidence.
#
# Usage:
#   archeflow-evidence.sh validate <review-file>  (rewrites downgraded severities to INFO in place)
#
# validate keeps the original next to it as <review-file>.orig, marks each
# rewritten severity as "INFO (downgraded: <reason>; original in <name>.orig)", keeps the
# file's mode, and, for a run artifact (.archeflow/artifacts/<run_id>/check-<role>.md),
# logs one "evidence.downgrade" event per downgrade (from, reason, line, role).
#   archeflow-evidence.sh scan <review-file>      (dry-run, report only)
#
# Recognised finding formats:
#   Table rows (archeflow:check-phase):
#     | Location | Severity | Category | Description | Fix |
#     | src/auth.ts:48 | CRITICAL | security | Empty string bypasses validation | Add length check |
#   Heading blocks (Skeptic / Trickster): a "### ..." heading plus a
#     "**Impact:** CRITICAL" or "**Severity:** WARNING" line.
#   Lines starting with a severity ("CRITICAL: ...") plus their continuation lines.
#
# Output: one "  DOWNGRADE: <SEV> → INFO (<reason>) [line N]" per downgrade,
# then "Findings: N | Downgrades: M".
# Exit 0 = at least one downgrade, 1 = nothing to downgrade (or usage/error).
#
# Dependencies: bash 4+
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac
set -euo pipefail

# shellcheck source=lib/archeflow-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archeflow-common.sh"
# Refuse a symlinked .archeflow/ (or events/, runs/, memory/ ...): writes would land outside the repo.
af_check_state_dirs

usage() {
    echo "Usage: archeflow-evidence.sh validate|scan <review-file>" >&2
    exit 1
}

HEDGE_PHRASES=(
    "might be"
    "could potentially"
    "appears to"
    "seems like"
    "may not"
    "possibly"
    "it is possible"
    "there could be"
    "it might"
    "perhaps"
    "conceivably"
    "one could argue"
)

# Extended regular expressions, matched case-insensitively.
EVIDENCE_MARKERS=(
    "output:"
    "error:"
    "line [0-9]"
    ":[0-9]"
    "stack trace"
    "exit code"
    '\$ '
    '```'
    "command:"
    "result:"
    "observed:"
    "expected:"
    "actual:"
    "reproduction:"
    "steps to reproduce"
)

# Severity at the start of a line: "CRITICAL: ...", "**WARNING** ...".
RE_LINE_SEV='^[[:space:]]*(\*\*)?(CRITICAL|WARNING|INFO)([^[:alpha:]]|$)'
# Severity label inside a heading block: "**Impact:** CRITICAL", "Severity: WARNING".
RE_LABEL_SEV='^[[:space:]]*([-*][[:space:]]+)?(\*\*)?(severity|impact)(:\*\*|\*\*:|:)[[:space:]]*(\*\*)?(CRITICAL|WARNING|INFO)([^[:alpha:]]|$)'
RE_HEADING='^[[:space:]]{0,3}#{1,6}[[:space:]]'
RE_TABLE_ROW='^[[:space:]]*\|'
RE_TABLE_SEP='^[[:space:]]*\|[[:space:]:|-]*$'

# scan_finding <text> <severity> — prints "DOWNGRADE|<reason>|<sev>→INFO" and
# returns 0 when a CRITICAL/WARNING finding must be downgraded.
scan_finding() {
    local text="$1" severity="$2" phrase marker
    [[ "$severity" != "CRITICAL" && "$severity" != "WARNING" ]] && return 1

    local has_hedge=0
    for phrase in "${HEDGE_PHRASES[@]}"; do
        if [[ "$text" == *"$phrase"* ]]; then
            has_hedge=1
            break
        fi
    done

    local has_evidence=0
    for marker in "${EVIDENCE_MARKERS[@]}"; do
        if [[ "$text" =~ $marker ]]; then
            has_evidence=1
            break
        fi
    done

    if [[ "$has_hedge" -eq 1 && "$has_evidence" -eq 0 ]]; then
        echo "DOWNGRADE|hedge_without_evidence|$severity→INFO"
        return 0
    fi
    if [[ "$has_evidence" -eq 0 ]]; then
        echo "DOWNGRADE|no_evidence|$severity→INFO"
        return 0
    fi
    return 1
}

# Cell helpers ---------------------------------------------------------------

# Trim whitespace, markdown emphasis and backticks; upper-case.
cell_value() {
    local v="$1"
    v="${v//\*/}"
    v="${v//\`/}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "${v^^}"
}

# Parser state (globals, reset per file) ---------------------------------------

LINES=()
TOTAL=0
DOWNGRADES=0
REWRITE_IDX=()     # line indices to rewrite
REWRITE_HOW=()     # "cell:<n>:<token>" or "tok:<token>"
REWRITE_SEV=()     # original severity of each rewrite
REWRITE_WHY=()     # reason of each rewrite
CUR_KIND=""        # "" | line | block
CUR_SEV=""
CUR_TOKEN=""
CUR_SEV_IDX=-1
CUR_TEXT=""
TABLE_SEV_COL=-1

# Evaluate one finding; record it for rewriting when it gets downgraded.
evaluate() {
    local text="$1" sev="$2" idx="$3" how="$4" result reason
    [[ "$sev" == CRITICAL || "$sev" == WARNING || "$sev" == INFO ]] || return 0
    TOTAL=$((TOTAL + 1))
    if result=$(scan_finding "$text" "$sev"); then
        DOWNGRADES=$((DOWNGRADES + 1))
        reason="${result#*|}"
        reason="${reason%|*}"
        echo "  DOWNGRADE: $sev → INFO ($reason) [line $((idx + 1))]"
        REWRITE_IDX+=("$idx")
        REWRITE_HOW+=("$how")
        REWRITE_SEV+=("$sev")
        REWRITE_WHY+=("$reason")
    fi
}

flush() {
    if [[ -n "$CUR_KIND" && -n "$CUR_SEV" && "$CUR_SEV_IDX" -ge 0 ]]; then
        evaluate "$CUR_TEXT" "$CUR_SEV" "$CUR_SEV_IDX" "tok:$CUR_TOKEN"
    fi
    CUR_KIND=""
    CUR_SEV=""
    CUR_TOKEN=""
    CUR_SEV_IDX=-1
    CUR_TEXT=""
}

table_row() {
    local line="$1" idx="$2" i v col=-1 sev=""
    local -a cells
    IFS='|' read -r -a cells <<< "$line"

    # Header row: remember which column holds the severity.
    for i in "${!cells[@]}"; do
        v=$(cell_value "${cells[$i]}")
        if [[ "$v" == SEVERITY || "$v" == IMPACT ]]; then
            TABLE_SEV_COL=$i
            return 0
        fi
    done

    if [[ "$TABLE_SEV_COL" -ge 0 ]]; then
        v=$(cell_value "${cells[$TABLE_SEV_COL]:-}")
        # "INFO (downgraded: ...)" written by an earlier validate
        [[ "$v" =~ ^(CRITICAL|WARNING|INFO)[[:space:]]*\( ]] && v="${BASH_REMATCH[1]}"
        [[ "$v" == CRITICAL || "$v" == WARNING || "$v" == INFO ]] && { col=$TABLE_SEV_COL; sev="$v"; }
    else
        for i in "${!cells[@]}"; do
            v=$(cell_value "${cells[$i]}")
            if [[ "$v" == CRITICAL || "$v" == WARNING || "$v" == INFO ]]; then
                col=$i
                sev="$v"
                break
            fi
        done
    fi
    [[ "$col" -ge 0 ]] || return 0

    # Token as written in the cell (keeps its case for the rewrite).
    local token
    [[ "${cells[$col]}" =~ (CRITICAL|WARNING|INFO) ]] && token="${BASH_REMATCH[1]}"
    evaluate "$line" "$sev" "$idx" "cell:$col:${token:-$sev}"
}

process_review() {
    local file="$1" mode="$2" line idx

    [[ -f "$file" ]] || { echo "Error: $file not found" >&2; exit 1; }
    mapfile -t LINES < "$file"

    shopt -s nocasematch
    for idx in "${!LINES[@]}"; do
        line="${LINES[$idx]}"
        line="${line%$'\r'}"

        if [[ "$line" =~ $RE_TABLE_ROW ]]; then
            flush
            [[ "$line" =~ $RE_TABLE_SEP ]] || table_row "$line" "$idx"
            continue
        fi
        TABLE_SEV_COL=-1

        if [[ "$line" =~ $RE_HEADING ]]; then
            flush
            CUR_KIND="block"
            CUR_TEXT="$line"
        elif [[ "$line" =~ $RE_LINE_SEV ]]; then
            flush
            CUR_KIND="line"
            CUR_TOKEN="${BASH_REMATCH[2]}"
            CUR_SEV="${CUR_TOKEN^^}"
            CUR_SEV_IDX=$idx
            CUR_TEXT="$line"
        elif [[ "$line" =~ $RE_LABEL_SEV && "$CUR_KIND" != "line" ]]; then
            if [[ -z "$CUR_KIND" ]]; then
                CUR_KIND="block"
                CUR_TEXT="$line"
            else
                CUR_TEXT+=$'\n'"$line"
            fi
            if [[ -z "$CUR_SEV" ]]; then
                CUR_TOKEN="${BASH_REMATCH[6]}"
                CUR_SEV="${CUR_TOKEN^^}"
                CUR_SEV_IDX=$idx
            fi
        elif [[ -n "$CUR_KIND" ]]; then
            CUR_TEXT+=$'\n'"$line"
        fi
    done
    flush
    shopt -u nocasematch

    if [[ "$mode" == "validate" && "$DOWNGRADES" -gt 0 ]]; then
        rewrite_file "$file"
        echo "  Rewrote $DOWNGRADES finding(s) to INFO in $file"
    fi

    echo ""
    echo "Findings: $TOTAL | Downgrades: $DOWNGRADES"

    [[ "$DOWNGRADES" -gt 0 ]]
}

# Replace the severity of every downgraded finding with an annotated INFO,
# atomically, after saving the original as <file>.orig.
rewrite_file() {
    local file="$1" i idx how col token line out mark
    local -a cells

    af_refuse_symlink "$file" && af_refuse_symlink "${file}.orig" || exit 1

    for i in "${!REWRITE_IDX[@]}"; do
        idx="${REWRITE_IDX[$i]}"
        how="${REWRITE_HOW[$i]}"
        line="${LINES[$idx]}"
        # The original severity is kept in <file>.orig and in the event, not
        # here: a "CRITICAL" in an INFO line would count as an open CRITICAL
        # for the failure-mode heuristics that grep review files.
        mark="INFO (downgraded: ${REWRITE_WHY[$i]//_/ }; original in ${file##*/}.orig)"
        case "$how" in
            cell:*)
                how="${how#cell:}"
                col="${how%%:*}"
                token="${how#*:}"
                IFS='|' read -r -a cells <<< "$line"
                cells[col]="${cells[col]/"$token"/$mark}"
                out=$(IFS='|'; printf '%s' "${cells[*]}")
                # read drops one trailing empty field ("... |").
                [[ "$line" == *'|' ]] && out+='|'
                LINES[idx]="$out"
                ;;
            tok:*)
                token="${how#tok:}"
                LINES[idx]="${line/"$token"/$mark}"
                ;;
        esac
    done

    # Keep the reviewer's original: a downgrade can be wrong (a real CRITICAL
    # that simply cited no evidence), and the user must be able to see it.
    if ! cp -p -- "$file" "${file}.orig"; then
        echo "Error: could not back up $file" >&2
        exit 1
    fi

    local tmp
    tmp=$(af_tmpfile "$file")
    # mktemp creates 0600: give the rewritten file the original's mode.
    chmod "$(_file_mode "$file")" "$tmp" 2>/dev/null || true
    if ! printf '%s\n' "${LINES[@]}" > "$tmp" || ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        echo "Error: could not rewrite $file" >&2
        exit 1
    fi
    log_downgrades "$file"
}

_file_mode() {
    stat -c %a -- "$1" 2>/dev/null || stat -f %Lp -- "$1" 2>/dev/null || echo 644
}

# One "evidence.downgrade" event per downgrade, when the file is a run's review
# artifact (.archeflow/artifacts/<run_id>/check-<role>.md). Logging never fails
# the gate.
log_downgrades() {
    local file="$1" run_id role i data
    local re='(^|/)\.archeflow/artifacts/([^/]+)/check-([a-z-]+)\.md$'
    [[ "$file" =~ $re ]] || return 0
    run_id="${BASH_REMATCH[2]}"
    role="${BASH_REMATCH[3]}"
    af_valid_name "$run_id" || return 0
    local event_sh
    event_sh="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archeflow-event.sh"
    [[ -x "$event_sh" ]] || return 0
    for i in "${!REWRITE_IDX[@]}"; do
        data=$(jq -cn --arg from "${REWRITE_SEV[$i]}" --arg reason "${REWRITE_WHY[$i]}" \
            --argjson line "$((REWRITE_IDX[i] + 1))" --arg file "$file" --arg role "$role" \
            '{from: $from, to: "INFO", reason: $reason, line: $line, file: $file, archetype: $role}') || continue
        "$event_sh" "$run_id" evidence.downgrade check "$role" "$data" >/dev/null 2>&1 \
            || echo "  warning: could not log evidence.downgrade event" >&2
    done
}

main() {
    local cmd="${1:-}"
    local file="${2:-}"

    [[ -z "$cmd" || -z "$file" ]] && usage

    case "$cmd" in
        validate|scan)
            echo "Evidence validation: $file"
            process_review "$file" "$cmd"
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"
