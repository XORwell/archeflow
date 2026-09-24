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
#   Label blocks: a "### ..." heading plus a "**Impact:** CRITICAL" or
#     "**Severity:** WARNING" line.
#   Severity headings: a heading whose text starts with the severity, optionally
#     bold and after a number ("### 1. CRITICAL, Security: <title>",
#     "## **WARNING**: <title>"), or carries it in brackets ("### <title> [CRITICAL]").
#     The finding runs to the next heading of the same or a higher level; its
#     body (e.g. "- **Location:** file:line", "- **Evidence:** ..." bullets) is
#     searched for evidence. A "**Severity:**" line inside it is the same finding.
#   Lines starting with a severity ("CRITICAL: ...") plus their continuation lines.
#
# Output: one "  DOWNGRADE: <SEV> → INFO (<reason>) [line N]" per downgrade,
# then "Findings: N | Downgrades: M".
# Exit 0 = at least one downgrade, 1 = nothing to downgrade (or usage/error),
# 3 = the file contains upper-case severity words (CRITICAL/WARNING/INFO) but no
#     finding was parsed: the format is not recognised, nothing was checked
#     (a warning goes to stderr). Counts of none ("0 CRITICAL", "no WARNING")
#     do not count as severity words.
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
RE_HEADING='^[[:space:]]{0,3}(#{1,6})[[:space:]]+(.*)$'
# Severity at the start of a heading's text, after an optional number or
# "Finding 1." style prefix and optional bold: "1. CRITICAL, Security: ...".
RE_HEAD_LEAD='^((finding|issue|attack|challenge)[[:space:]]*)?(#?[0-9]+[.):]?[[:space:]]*)?(-|–|—)?[[:space:]]*(\*\*|__)?\[?(\*\*)?(CRITICAL|WARNING|INFO)(\*\*)?\]?(\*\*|__)?([^[:alnum:]_]|$)'
# Severity in brackets anywhere in a heading: "SQL injection [CRITICAL]", "(**WARNING**)".
RE_HEAD_BRACKET='[[(](\*\*)?(CRITICAL|WARNING|INFO)(\*\*)?[])]'
# Upper-case severity word anywhere (for the "nothing parsed" warning).
RE_ANY_SEV='(^|[^[:alnum:]_])(CRITICAL|WARNING|INFO)([^[:alnum:]_]|$)'
RE_NONE_SEV='(^|[^[:alnum:]_])(0|[Nn]o)[[:space:]]+(\*\*)?(CRITICAL|WARNING|INFO)'
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
REWRITE_HOW=()     # "cell:<n>:<token>", "tok:<token>" or "sub:<outer>" + REWRITE_TOK
REWRITE_TOK=()     # severity token inside <outer> for "sub:" rewrites
REWRITE_SEV=()     # original severity of each rewrite
REWRITE_WHY=()     # reason of each rewrite
REWRITE_LOG=()     # 1 = the finding's primary rewrite (one event per finding)
CUR_KIND=""        # "" | line | block | head
CUR_LEVEL=0        # heading level of a "head" finding
CUR_SEV=""
CUR_SEV_IDX=-1
CUR_MARKS=()       # "<idx>|<how>|<sev>" of every severity token of the finding
CUR_TEXT=""
TABLE_SEV_COL=-1

sev_rank() {
    case "$1" in CRITICAL) echo 3 ;; WARNING) echo 2 ;; INFO) echo 1 ;; *) echo 0 ;; esac
}

# add_mark <idx> <how> <token>: one severity token of the current finding. The
# finding's severity is the highest of its tokens.
add_mark() {
    local idx="$1" how="$2" sev="${3^^}"
    CUR_MARKS+=("$idx|$how|$sev")
    if [[ -z "$CUR_SEV" || $(sev_rank "$sev") -gt $(sev_rank "$CUR_SEV") ]]; then
        CUR_SEV="$sev"
        CUR_SEV_IDX=$idx
    fi
}

# evaluate <text> <sev> <idx> <mark>...: evaluate one finding; when it gets
# downgraded, record each of its CRITICAL/WARNING tokens for rewriting.
evaluate() {
    local text="$1" sev="$2" idx="$3" result reason mark m_idx m_how m_sev primary=1
    shift 3
    [[ "$sev" == CRITICAL || "$sev" == WARNING || "$sev" == INFO ]] || return 0
    TOTAL=$((TOTAL + 1))
    if result=$(scan_finding "$text" "$sev"); then
        DOWNGRADES=$((DOWNGRADES + 1))
        reason="${result#*|}"
        reason="${reason%|*}"
        echo "  DOWNGRADE: $sev → INFO ($reason) [line $((idx + 1))]"
        for mark in "$@"; do
            m_idx="${mark%%|*}"
            m_sev="${mark##*|}"
            m_how="${mark#*|}"
            m_how="${m_how%|*}"
            [[ "$m_sev" == CRITICAL || "$m_sev" == WARNING ]] || continue
            REWRITE_IDX+=("$m_idx")
            if [[ "$m_how" == sub:* ]]; then
                REWRITE_HOW+=("sub:${m_how#sub:*:}")
                REWRITE_TOK+=("$(t="${m_how#sub:}"; printf '%s' "${t%%:*}")")
            else
                REWRITE_HOW+=("$m_how")
                REWRITE_TOK+=("")
            fi
            REWRITE_SEV+=("$m_sev")
            REWRITE_WHY+=("$reason")
            if [[ "$primary" -eq 1 && "$m_idx" -eq "$idx" && "$m_sev" == "$sev" ]]; then
                REWRITE_LOG+=(1)
                primary=0
            else
                REWRITE_LOG+=(0)
            fi
        done
    fi
}

flush() {
    if [[ -n "$CUR_KIND" && -n "$CUR_SEV" && "$CUR_SEV_IDX" -ge 0 ]]; then
        evaluate "$CUR_TEXT" "$CUR_SEV" "$CUR_SEV_IDX" "${CUR_MARKS[@]}"
    fi
    CUR_KIND=""
    CUR_LEVEL=0
    CUR_SEV=""
    CUR_SEV_IDX=-1
    CUR_MARKS=()
    CUR_TEXT=""
}

# heading_mark <heading-text>: if the heading names a severity, print
# "<how>|<token>" for add_mark and return 0.
heading_mark() {
    local text="$1" outer
    if [[ "$text" =~ $RE_HEAD_LEAD ]]; then
        printf 'tok:%s|%s' "${BASH_REMATCH[7]}" "${BASH_REMATCH[7]}"
        return 0
    fi
    if [[ "$text" =~ $RE_HEAD_BRACKET ]]; then
        outer="${BASH_REMATCH[0]}"
        # "sub:<token>:<outer>": rewrite <token> inside <outer> only.
        printf 'sub:%s:%s|%s' "${BASH_REMATCH[2]}" "$outer" "${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
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
    evaluate "$line" "$sev" "$idx" "$idx|cell:$col:${token:-$sev}|$sev"
}

process_review() {
    local file="$1" mode="$2" line idx level hm

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
            level=${#BASH_REMATCH[1]}
            if hm=$(heading_mark "${BASH_REMATCH[2]}"); then
                flush
                CUR_KIND="head"
                CUR_LEVEL=$level
                CUR_TEXT="$line"
                add_mark "$idx" "${hm%|*}" "${hm##*|}"
            elif [[ "$CUR_KIND" == head && "$level" -gt "$CUR_LEVEL" ]]; then
                # A sub-heading belongs to the severity heading above it.
                CUR_TEXT+=$'\n'"$line"
            else
                flush
                CUR_KIND="block"
                CUR_TEXT="$line"
            fi
        elif [[ "$line" =~ $RE_LINE_SEV ]]; then
            flush
            CUR_KIND="line"
            CUR_TEXT="$line"
            add_mark "$idx" "tok:${BASH_REMATCH[2]}" "${BASH_REMATCH[2]}"
        elif [[ "$line" =~ $RE_LABEL_SEV && "$CUR_KIND" != "line" ]]; then
            if [[ -z "$CUR_KIND" ]]; then
                CUR_KIND="block"
                CUR_TEXT="$line"
            else
                CUR_TEXT+=$'\n'"$line"
            fi
            add_mark "$idx" "tok:${BASH_REMATCH[6]}" "${BASH_REMATCH[6]}"
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

    if [[ "$TOTAL" -eq 0 ]]; then
        for line in "${LINES[@]}"; do
            # "0 CRITICAL" / "no WARNING" state that there are none.
            while [[ "$line" =~ $RE_NONE_SEV ]]; do
                line="${line/"${BASH_REMATCH[0]}"/ }"
            done
            if [[ "$line" =~ $RE_ANY_SEV ]]; then
                echo "WARNING: severity words found but no findings parsed; check the output format" >&2
                return 3
            fi
        done
    fi
    [[ "$DOWNGRADES" -gt 0 ]] && return 0
    return 1
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
            sub:*)
                # Severity in brackets: rewrite it inside the bracket only.
                local outer="${how#sub:}"
                token="${REWRITE_TOK[$i]}"
                LINES[idx]="${line/"$outer"/${outer/"$token"/$mark}}"
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
        [[ "${REWRITE_LOG[$i]}" -eq 1 ]] || continue
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
