#!/usr/bin/env bash
set -euo pipefail

# Shadow detection for ArcheFlow archetypes.
# Analyzes agent output artifacts and emits shadow.detected events
# when quantitative triggers are met.
#
# Usage:
#   archeflow-shadow.sh detect <archetype> <artifact-file> [--proposal <proposal-file>] [--diff <diff-file>]
#   archeflow-shadow.sh check-system <run_id | run-dir> [--cycle <N>]
#
# detect maker needs --diff (the run diff, do-maker.diff): the changed files come
# from the diff, the test-run evidence from the artifact (the Maker's report).
#
# With --run-id (detect) or a run ID (check-system), every detection is logged as a
# shadow.detected event. The cycle recorded in it is --cycle, else 1 + the number of
# cycle.boundary events already in the run's log.
#
# check-system reads what a real run writes: artifacts in .archeflow/artifacts/<run_id>/
# (plan-creator.md, do-maker.diff from "archeflow-git.sh integrate", check-*.md) and
# events in .archeflow/events/<run_id>.jsonl. A directory argument is also accepted
# (events: <dir>/events.jsonl, else <dir>/../../events/<basename>.jsonl).
#
# Exit codes: 0 = shadow detected, 1 = clean (or detection disabled), 2 = usage/input error.
#
# Dependencies: jq, bash 4+

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required. Install: https://jqlang.github.io/jq/" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: archeflow-shadow.sh detect <archetype> <artifact-file> [options]" >&2
    echo "       archeflow-shadow.sh check-system <run_id | run-dir> [--cycle <n>]" >&2
    echo "" >&2
    echo "Archetypes: explorer, creator, maker, guardian, skeptic, trickster, sage" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --proposal <file>   Creator's proposal (for maker scope check)" >&2
    echo "  --diff <file>       The run diff, do-maker.diff (required for maker; sage/trickster scope)" >&2
    echo "  --run-id <id>       Run ID for event logging" >&2
    echo "  --cycle <n>         PDCA cycle number (recorded in the event; used by wiggum-check)" >&2
    echo "  --task-words <n>    Expected proposal size for creator scope check" >&2
    echo "                      (or ARCHEFLOW_TASK_WORDS; check skipped if unset)" >&2
    exit "${1:-2}"
}

# --- Word count ---
count_words() {
    local file="$1"
    wc -w < "$file" | tr -d ' '
}

# --- Line count ---
count_lines() {
    local file="$1"
    wc -l < "$file" | tr -d ' '
}

# --- Count occurrences of a pattern ---
count_pattern() {
    local file="$1"
    local pattern="$2"
    local n
    n=$(grep -c -i "$pattern" "$file" 2>/dev/null) || true
    echo "${n:-0}"
}

# --- Count sections/headings ---
count_headings() {
    local file="$1"
    local pattern="$2"
    local n
    n=$(grep -c "^#" "$file" 2>/dev/null) || true
    echo "${n:-0}"
}

# --- Extract file references (path-like tokens) from prose ---
# A token counts as a file reference if it looks like name.ext. Excluded:
#   - abbreviations whose dot-separated parts are all single letters
#     ("e.g", "i.e", "a.k.a") -- these previously counted as files
#   - sentence joins where the "extension" is a capitalised word ("done.The")
# Prints one reference per occurrence (not deduplicated).
extract_file_refs() {
    local file="$1"
    grep -oE '[a-zA-Z0-9_/.-]+\.[a-zA-Z]{1,5}' "$file" 2>/dev/null \
        | grep -vE '^([A-Za-z]\.)+[A-Za-z]$' \
        | grep -vE '\.[A-Z][a-z]+$' \
        || true
}

# --- Extract files from a proposal ---
extract_proposal_files() {
    local file="$1"
    extract_file_refs "$file" | sort -u
}

# --- Extract files from a diff ---
extract_diff_files() {
    local file="$1"
    grep -E '^\+\+\+ b/' "$file" 2>/dev/null | sed 's/^+++ b\///' | sort -u
}

# ============================================================
# Shadow detection per archetype
# Returns 0 if shadow detected, 1 if clean
# Prints the shadow name and trigger to stdout on detection
# ============================================================

detect_explorer() {
    local artifact="$1"
    local words
    words=$(count_words "$artifact")

    local has_recommendation
    has_recommendation=$(grep -c -i -E "recommendation|summary|conclusion|next.step" "$artifact" 2>/dev/null || true)
    has_recommendation="${has_recommendation:-0}"

    local tangent_count
    tangent_count=$(grep -c -i -E "tangent|aside|also.worth|while.we.are|incidentally|by.the.way" "$artifact" 2>/dev/null || true)
    tangent_count="${tangent_count:-0}"

    local files_mentioned
    files_mentioned=$(extract_file_refs "$artifact" | wc -l | tr -d ' ')
    files_mentioned="${files_mentioned:-0}"

    local has_patterns
    has_patterns=$(grep -c -i -E "pattern|observation|finding|theme|takeaway" "$artifact" 2>/dev/null || true)
    has_patterns="${has_patterns:-0}"

    if [[ "$words" -gt 2000 && "$has_recommendation" -eq 0 ]]; then
        echo "rabbit_hole|Output >2000 words ($words) without recommendation section"
        return 0
    fi

    if [[ "$tangent_count" -gt 3 ]]; then
        echo "rabbit_hole|>3 tangents detected ($tangent_count)"
        return 0
    fi

    if [[ "$files_mentioned" -gt 15 && "$has_patterns" -eq 0 ]]; then
        echo "rabbit_hole|>15 files mentioned ($files_mentioned) without pattern synthesis"
        return 0
    fi

    return 1
}

detect_creator() {
    local artifact="$1"
    local task_words="${2:-}"

    local abstraction_count
    abstraction_count=$(grep -c -i "interface\|abstract.class\|base.class\|factory\|provider\|adapter\|wrapper\|middleware\|interceptor\|decorator\|strategy.pattern\|observer.pattern" "$artifact" 2>/dev/null) || abstraction_count=0

    local new_package_count
    new_package_count=$(grep -c -i "new.package\|new.module\|new.service\|new.library\|create.*package\|add.*dependency" "$artifact" 2>/dev/null) || new_package_count=0

    local future_proof_count
    future_proof_count=$(grep -c -i "future.proof\|extensib\|in.case\|might.need\|could.later\|prepare.for\|anticipat" "$artifact" 2>/dev/null) || future_proof_count=0

    local proposal_words
    proposal_words=$(count_words "$artifact")

    if [[ "$abstraction_count" -gt 2 ]]; then
        echo "over_architect|>2 new abstractions proposed ($abstraction_count)"
        return 0
    fi

    if [[ "$new_package_count" -gt 1 ]]; then
        echo "over_architect|>1 new package/dependency proposed ($new_package_count)"
        return 0
    fi

    if [[ "$future_proof_count" -gt 2 ]]; then
        echo "over_architect|Excessive future-proofing language ($future_proof_count occurrences)"
        return 0
    fi

    # Scope exceeds task >50%: proposal word count > 1.5x the expected size.
    # Only evaluated when the caller supplies the expected size (--task-words N
    # or ARCHEFLOW_TASK_WORDS); there is no built-in default any more.
    if [[ -n "$task_words" ]]; then
        if [[ "$proposal_words" -gt $((task_words * 3 / 2)) ]]; then
            echo "over_architect|Proposal scope exceeds task by >50% ($proposal_words words for ~$task_words word task)"
            return 0
        fi
    fi

    return 1
}

# --- Changed lines per file from a unified diff: "<lines>\t<path>" ---
# Lines = added + removed lines (headers excluded). Path from "diff --git a/X b/Y" (Y).
diff_file_lines() {
    local file="$1"
    awk '
        /^diff --git / { f = $NF; sub(/^b\//, "", f); if (!(f in n)) { n[f] = 0; order[++k] = f }; next }
        /^(\+\+\+|---) / { next }
        f != "" && /^[+-]/ { n[f]++ }
        END { for (i = 1; i <= k; i++) printf "%d\t%s\n", n[order[i]], order[i] }
    ' "$file" 2>/dev/null
}

# Test files: tests/, test/, spec/, __tests__/ directories, or test_*, *_test.*,
# *.test.*, *.spec.*, *_spec.*, *Test.* names.
is_test_path() {
    grep -qiE '(^|/)(tests?|specs?|__tests__|testdata)/|(^|/)test_[^/]*$|_test\.[^/]+$|\.(test|spec)\.[^/]+$|_spec\.[^/]+$|(^|/)[^/]*Tests?\.[A-Za-z]+$' <<<"$1"
}

# Not code: documentation, images, licence/changelog files, lock files.
is_doc_path() {
    grep -qiE '(^|/)docs?/|\.(md|markdown|rst|txt|adoc|org|png|jpe?g|gif|svg|ico|webp|pdf)$|(^|/)(license|licence|notice|authors|changelog|changes|contributing|readme)[^/]*$|(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|cargo\.lock|go\.sum|gemfile\.lock)$' <<<"$1"
}

# Evidence in the Maker's report that tests were run.
MAKER_TEST_EVIDENCE='tests? (pass|passed|passing|ran|run:|succeeded|green)|[0-9]+ (passed|passing)|passed|✓|pytest|jest|vitest|mocha|rspec|phpunit|bats|cargo test|go test|npm (run )?test|yarn test|make test|ctest|exit (code|status) 0|test output|test run'

# Maker (Rogue). Inputs: the Maker's report (test evidence), the run diff
# (do-maker.diff from "archeflow-git.sh integrate": changed files and lines), and
# optionally the Creator's proposal (scope). Only code files count: documentation,
# images, licence and lock files are ignored, test files are counted separately.
#   1. >= 3 code files changed and no test file changed
#   2. >= MAKER_MIN_CODE_LINES (10) changed code lines and no test-run evidence in the report
#   3. code files changed that the proposal does not mention (full path or file name)
detect_maker() {
    local report="$1"
    local proposal_file="${2:-}"
    local diff_file="${3:-}"

    local code_files=0 test_files=0 code_lines=0 code_list="" lines path
    while IFS=$'\t' read -r lines path; do
        [[ -z "$path" ]] && continue
        [[ "$lines" =~ ^[0-9]+$ ]] || lines=0
        if is_test_path "$path"; then
            test_files=$((test_files + 1))
        elif ! is_doc_path "$path"; then
            code_files=$((code_files + 1))
            code_lines=$((code_lines + lines))
            code_list+="$path"$'\n'
        fi
    done < <(diff_file_lines "$diff_file")

    if [[ "$code_files" -ge 3 && "$test_files" -eq 0 ]]; then
        echo "rogue|No test file changed with $code_files code files changed"
        return 0
    fi

    local min_lines="${MAKER_MIN_CODE_LINES:-10}"
    if [[ "$code_lines" -ge "$min_lines" ]] && ! grep -qiE "$MAKER_TEST_EVIDENCE" "$report" 2>/dev/null; then
        echo "rogue|No evidence in the report that tests ran ($code_lines code lines changed in $code_files files)"
        return 0
    fi

    if [[ -n "$proposal_file" && -f "$proposal_file" && -n "$code_list" ]]; then
        local proposal_files out_of_scope=0 changed
        proposal_files=$(extract_proposal_files "$proposal_file")
        while IFS= read -r changed; do
            [[ -z "$changed" ]] && continue
            # Mentioned by full path, or by a path/name ending in its file name.
            if ! awk -v c="$changed" -v b="${changed##*/}" '
                    $0 == c || $0 == b || substr($0, length($0) - length(b)) == "/" b { f = 1 }
                    END { exit !f }' <<<"$proposal_files"; then
                out_of_scope=$((out_of_scope + 1))
            fi
        done <<< "$code_list"

        if [[ "$out_of_scope" -gt 0 ]]; then
            echo "rogue|$out_of_scope code files changed outside proposal scope"
            return 0
        fi
    fi

    return 1
}

detect_guardian() {
    local artifact="$1"

    # Count only structured finding markers, not CRITICAL/WARNING in prose.
    # Deduplicate: LLM agents frequently repeat findings across output
    # sections (reasoning, formal list, summary). Normalize descriptions
    # by stripping file references, extra qualifiers, and case, then
    # count unique findings to avoid inflated ratios.
    _normalize_finding() {
        sed 's/^[^:]*:[[:space:]]*//' \
        | sed 's/[[:space:]]*(file[: ][^)]*)//' \
        | sed 's/[[:space:]]*in plain text//' \
        | sed 's/[[:space:]]*"[^"]*"//' \
        | sed 's/with potential.*//' \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[[:space:]]*$//' \
        | sort -u
    }

    local critical_count
    critical_count=$( {
        grep -oE "^[[:space:]]*(\*\*|[-*]|[0-9]+\.)?[[:space:]]*(CRITICAL|Critical)[[:space:]]*[:\|>\[](.*)" "$artifact" 2>/dev/null || true
        grep -oE "\|[[:space:]]*(CRITICAL|Critical)[[:space:]]*\|(.*)" "$artifact" 2>/dev/null || true
    } | _normalize_finding | wc -l | tr -d ' ')

    local warning_count
    warning_count=$( {
        grep -oE "^[[:space:]]*(\*\*|[-*]|[0-9]+\.)?[[:space:]]*(WARNING|Warning)[[:space:]]*[:\|>\[](.*)" "$artifact" 2>/dev/null || true
        grep -oE "\|[[:space:]]*(WARNING|Warning)[[:space:]]*\|(.*)" "$artifact" 2>/dev/null || true
    } | _normalize_finding | wc -l | tr -d ' ')

    local approved_count
    approved_count=$(grep -c -i "APPROVED\|no.issues\|looks.good\|clean\|pass" "$artifact" 2>/dev/null) || approved_count=0

    local findings_with_fix
    findings_with_fix=$(grep -c -i "fix:\|mitigation:\|recommend:\|resolution:\|solution:" "$artifact" 2>/dev/null) || findings_with_fix=0

    local total_findings=$((critical_count + warning_count))

    # Documented rule: CRITICAL:WARNING ratio strictly >2:1, min 3 CRITICALs.
    # (Previously integer division fired at exactly 2:1 and never with 0 WARNINGs.)
    if [[ "$critical_count" -ge 3 && "$critical_count" -gt $((warning_count * 2)) ]]; then
        echo "paranoid|CRITICAL:WARNING ratio >2:1 ($critical_count:$warning_count)"
        return 0
    fi

    local review_count
    review_count=$(grep -c -i "^##\|^###\|review\|assessment" "$artifact" 2>/dev/null || true)
    review_count="${review_count:-0}"

    if [[ "$review_count" -ge 3 && "$approved_count" -eq 0 ]]; then
        echo "paranoid|Zero approvals in $review_count reviews"
        return 0
    fi

    if [[ "$total_findings" -ge 2 && "$findings_with_fix" -gt 0 ]]; then
        local fix_ratio=$((findings_with_fix * 100 / total_findings))
        if [[ "$fix_ratio" -lt 50 ]]; then
            echo "paranoid|<50% findings include fix ($findings_with_fix/$total_findings)"
            return 0
        fi
    fi

    return 1
}

detect_skeptic() {
    local artifact="$1"

    local challenge_count
    challenge_count=$(grep -c -i "challenge\|concern\|question\|risk\|assumption\|problematic\|issue" "$artifact" 2>/dev/null) || challenge_count=0

    local alternative_count
    alternative_count=$(grep -c -i "alternative\|instead\|consider\|option\|approach\|suggest" "$artifact" 2>/dev/null) || alternative_count=0

    # Repeated concern: a concern clause runs from a concern keyword to the
    # end of its sentence (. ! ? followed by whitespace or end of line, so
    # "e.g." does not end it). Markdown emphasis (* _ `) is stripped first;
    # clauses are normalised (lowercase, > # | removed, whitespace collapsed); clauses with fewer than 4
    # words after the keyword are ignored -- bare fragments like "issues." or
    # "issue (e.g." are not concerns. The count is the number of distinct
    # normalised clauses that occur 2+ times.
    local repeated_concerns
    repeated_concerns=$(
        tr '\n' ' ' < "$artifact" \
        | sed -E 's/[*_`]+//g' \
        | grep -ioE "(concern|risk|issue|problem|question)s?[[:space:]]([^.!?]|[.!?][^[:space:]])*[.!?]([[:space:]]|$)" 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[>#|]+//g; s/[[:space:]]+/ /g; s/^ //; s/ $//' \
        | awk 'NF >= 5' \
        | sort | uniq -d | wc -l | tr -d ' '
    ) || repeated_concerns=0

    if [[ "$challenge_count" -gt 7 ]]; then
        local alt_ratio=0
        if [[ "$challenge_count" -gt 0 ]]; then
            alt_ratio=$((alternative_count * 100 / challenge_count))
        fi
        if [[ "$alt_ratio" -lt 50 ]]; then
            echo "paralytic|>7 challenges ($challenge_count) with <50% having alternatives ($alt_ratio%)"
            return 0
        fi
    fi

    if [[ "$repeated_concerns" -ge 2 ]]; then
        echo "paralytic|$repeated_concerns concerns repeated verbatim (2+ occurrences each)"
        return 0
    fi

    return 1
}

detect_trickster() {
    local artifact="$1"
    local diff_file="${2:-}"

    local finding_count
    finding_count=$(grep -c -i "finding\|issue\|vulnerability\|bug\|flaw\|defect" "$artifact" 2>/dev/null) || finding_count=0

    # Count findings without reproduction steps
    local total_finding_blocks
    total_finding_blocks=$(grep -c -iE "^(CRITICAL|WARNING|finding|issue)" "$artifact" 2>/dev/null || true)
    total_finding_blocks="${total_finding_blocks:-0}"

    local findings_with_repro
    findings_with_repro=$(grep -c -iE "repro|steps to|how to trigger|to reproduce|reproduction" "$artifact" 2>/dev/null || true)
    findings_with_repro="${findings_with_repro:-0}"

    local no_repro_count=0
    if [[ "$total_finding_blocks" -gt 0 ]]; then
        no_repro_count=$((total_finding_blocks - findings_with_repro))
    fi

    local findings_in_untouched=0
    if [[ -n "$diff_file" && -f "$diff_file" ]]; then
        local changed_files
        changed_files=$(extract_diff_files "$diff_file")

        local referenced_files
        referenced_files=$(extract_file_refs "$artifact" | sort -u)

        while IFS= read -r ref_file; do
            [[ -z "$ref_file" ]] && continue
            if ! echo "$changed_files" | grep -qF "$ref_file"; then
                findings_in_untouched=$((findings_in_untouched + 1))
            fi
        done <<< "$referenced_files"
    fi

    if [[ "$findings_in_untouched" -gt 0 ]]; then
        echo "false_alarm|Findings reference untouched files ($findings_in_untouched)"
        return 0
    fi

    local diff_file_count=5  # default
    if [[ -n "$diff_file" && -f "$diff_file" ]]; then
        diff_file_count=$(extract_diff_files "$diff_file" | wc -l || echo "5")
    fi

    if [[ "$finding_count" -gt 10 && "$diff_file_count" -lt 5 ]]; then
        echo "false_alarm|>10 findings ($finding_count) for <5 files ($diff_file_count)"
        return 0
    fi

    if [[ "$no_repro_count" -gt 3 ]]; then
        echo "false_alarm|>3 findings without reproduction steps ($no_repro_count)"
        return 0
    fi

    return 1
}

detect_sage() {
    local artifact="$1"
    local diff_file="${2:-}"

    local review_words
    review_words=$(count_words "$artifact")

    local diff_lines=100  # default
    if [[ -n "$diff_file" && -f "$diff_file" ]]; then
        diff_lines=$(count_lines "$diff_file")
        [[ "$diff_lines" -eq 0 ]] && diff_lines=1
    fi

    local consider_without_action
    consider_without_action=$(grep -c -i "consider\b" "$artifact" 2>/dev/null) || consider_without_action=0

    local actionable_count
    actionable_count=$(grep -c -i "must\|should\|fix\|change\|replace\|remove\|add\|update" "$artifact" 2>/dev/null) || actionable_count=0

    if [[ "$diff_lines" -gt 0 ]]; then
        local length_ratio=$((review_words / diff_lines))
        if [[ "$length_ratio" -ge 2 ]]; then
            echo "bureaucrat|Review words ($review_words) > 2x diff lines ($diff_lines)"
            return 0
        fi
    fi

    # Findings outside changeset
    if [[ -n "$diff_file" && -f "$diff_file" ]]; then
        local changed_files_sage
        changed_files_sage=$(extract_diff_files "$diff_file")
        local review_files_sage
        review_files_sage=$(extract_file_refs "$artifact" | sort -u)

        local outside_changeset=0
        while IFS= read -r rf; do
            [[ -z "$rf" ]] && continue
            if ! echo "$changed_files_sage" | grep -qF "$rf"; then
                outside_changeset=$((outside_changeset + 1))
            fi
        done <<< "$review_files_sage"

        local total_refs
        total_refs=$(echo "$review_files_sage" | grep -v '^$' | wc -l || echo "1")
        if [[ "$total_refs" -gt 2 && "$outside_changeset" -gt "$((total_refs / 2))" ]]; then
            echo "bureaucrat|Majority of findings reference files outside changeset ($outside_changeset/$total_refs)"
            return 0
        fi
    fi

    if [[ "$consider_without_action" -gt 2 && "$actionable_count" -lt "$consider_without_action" ]]; then
        echo "bureaucrat|>2 'consider' without action ($consider_without_action considers, $actionable_count actionable)"
        return 0
    fi

    return 1
}

# ============================================================
# System shadow detection
# ============================================================

# resolve_run <run_id | run-dir>: sets RUN_DIR (artifacts) and EVENT_FILE
# (empty if the run has no event log yet). Exits 2 if neither exists.
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
        [[ -d ".archeflow/artifacts/$arg" ]] && RUN_DIR=".archeflow/artifacts/$arg"
        [[ -f ".archeflow/events/$arg.jsonl" ]] && EVENT_FILE=".archeflow/events/$arg.jsonl"
        if [[ -n "$RUN_DIR" || -n "$EVENT_FILE" ]]; then
            return 0
        fi
    fi
    echo "Error: $arg not found (neither a run directory nor a run ID under .archeflow/)" >&2
    exit 2
}

detect_system_shadows() {
    local run_dir="$1"
    local event_file="${2:-}"
    local cycle="${3:-}"
    local detected=()

    local review_files=""
    [[ -n "$run_dir" ]] && review_files=$(find "$run_dir" -maxdepth 1 -name "check-*.md" 2>/dev/null)

    # Tunnel Vision: every finding of the cycle is in one category. Read from the
    # consolidated findings (findings-cycle-<N>.json, the cycle's, else the latest),
    # and only with 2+ reviewers (check-*.md) and 3+ findings: one reviewer, or a
    # clean run, cannot show tunnel vision.
    local reviewers=0
    [[ -n "$review_files" ]] && reviewers=$(printf '%s\n' "$review_files" | grep -c . || true)
    local findings_file=""
    if [[ -n "$run_dir" ]]; then
        if [[ -n "$cycle" && -f "$run_dir/findings-cycle-$cycle.json" ]]; then
            findings_file="$run_dir/findings-cycle-$cycle.json"
        else
            findings_file=$(find "$run_dir" -maxdepth 1 -name "findings-cycle-*.json" 2>/dev/null | sort -V | tail -1)
        fi
    fi
    if [[ "$reviewers" -ge 2 && -n "$findings_file" ]]; then
        local tv
        tv=$(jq -r '[ .[]? | objects ] as $f
            | ([ $f[] | .category | strings | ascii_downcase ] | unique) as $c
            | if ($f | length) >= 3 and ($c | length) == 1 then "\($f | length)\t\($c[0])" else "" end' \
            "$findings_file" 2>/dev/null) || tv=""
        if [[ -n "$tv" ]]; then
            detected+=("tunnel_vision|All ${tv%%$'\t'*} findings of $reviewers reviewers are in one category (${tv#*$'\t'})")
        fi
    fi

    # Scope Creep: maker changed >2x files in proposal
    local proposal="${run_dir:-.}/plan-creator.md"
    local maker_diff="${run_dir:-.}/do-maker.diff"
    if [[ -f "$proposal" && -f "$maker_diff" ]]; then
        local proposal_file_count
        proposal_file_count=$(extract_proposal_files "$proposal" | wc -l || echo "1")
        local diff_file_count
        diff_file_count=$(extract_diff_files "$maker_diff" | wc -l) || diff_file_count=0

        if [[ "$proposal_file_count" -gt 0 && "$diff_file_count" -gt $((proposal_file_count * 2)) ]]; then
            detected+=("scope_creep|Maker changed $diff_file_count files, proposal listed $proposal_file_count (>2x)")
        fi
    fi

    # Gold Plating: INFO fixes while CRITICALs remain
    if [[ -n "$review_files" ]]; then
        for rf in $review_files; do
            local open_criticals
            open_criticals=$(grep -c -i "CRITICAL" "$rf" 2>/dev/null) || open_criticals=0
            if [[ "$open_criticals" -gt 0 ]]; then
                local info_fixes
                info_fixes=$(grep -c -i "INFO.*fix\|fix.*INFO" "$rf" 2>/dev/null) || info_fixes=0
                if [[ "$info_fixes" -gt 0 ]]; then
                    detected+=("gold_plating|Working on INFO fixes while $open_criticals CRITICALs remain open")
                    break
                fi
            fi
        done
    fi

    # Echo Chamber: unanimous approval in the current cycle (the events after the
    # last cycle.boundary): 2+ review.verdict events, all APPROVED with no findings;
    # without review.verdict events, 2+ check-phase agent.complete events none of
    # which mentions CRITICAL/WARNING. Elapsed time is not measured.
    if [[ -n "$event_file" && -f "$event_file" ]]; then
        local echo_result
        echo_result=$(jq -rs '
            def isint: type == "number" and . == floor;
            [ .[] | objects | select(.seq | isint) ] as $ev
            | ([ $ev[] | select(.type == "cycle.boundary") | .seq ] | max // 0) as $b
            | [ $ev[] | select(.seq > $b) ] as $cur
            | [ $cur[] | select(.type == "review.verdict") ] as $v
            | if ($v | length) > 0 then
                if ($v | length) >= 2 and all($v[]; ((.data.verdict? // "") | tostring | ascii_upcase) == "APPROVED"
                                              and (((.data.findings? // []) | if type == "array" then length else 1 end) == 0))
                then ($v | length | tostring) else "" end
              else
                [ $cur[] | select(.type == "agent.complete" and .phase == "check") ] as $c
                | if ($c | length) >= 2 and all($c[]; (tostring | test("CRITICAL|WARNING") | not))
                  then ($c | length | tostring) else "" end
              end' "$event_file" 2>/dev/null) || echo_result=""
        if [[ "$echo_result" =~ ^[0-9]+$ ]]; then
            detected+=("echo_chamber|Unanimous approval from $echo_result reviewers")
        fi
    fi

    # Analysis Paralysis: plan phase >2x longer than do phase
    if [[ -n "$event_file" && -f "$event_file" ]]; then
        local plan_duration=0
        local do_duration=0

        local plan_events
        plan_events=$(grep '"phase":"plan"' "$event_file" 2>/dev/null | grep '"duration_ms"' || true)
        while IFS= read -r evt; do
            [[ -z "$evt" ]] && continue
            local dur
            dur=$(echo "$evt" | grep -oE '"duration_ms":[0-9]+' | grep -oE '[0-9]+') || dur=0
            plan_duration=$((plan_duration + dur))
        done <<< "$plan_events"

        local do_events
        do_events=$(grep '"phase":"do"' "$event_file" 2>/dev/null | grep '"duration_ms"' || true)
        while IFS= read -r evt; do
            [[ -z "$evt" ]] && continue
            local dur
            dur=$(echo "$evt" | grep -oE '"duration_ms":[0-9]+' | grep -oE '[0-9]+') || dur=0
            do_duration=$((do_duration + dur))
        done <<< "$do_events"

        if [[ "$do_duration" -gt 0 && "$plan_duration" -gt $((do_duration * 2)) ]]; then
            detected+=("analysis_paralysis|Plan phase (${plan_duration}ms) >2x Do phase (${do_duration}ms)")
        fi

        local explorer_spawns
        explorer_spawns=$(grep -c '"archetype":"explorer"' "$event_file" 2>/dev/null) || explorer_spawns=0
        if [[ "$explorer_spawns" -ge 3 ]]; then
            detected+=("analysis_paralysis|Explorer spawned $explorer_spawns times")
        fi
    fi

    # Broken Window: 3+ WARNINGs deferred across consecutive runs
    local memory_file=".archeflow/memory/lessons.jsonl"
    [[ -n "$run_dir" && -f "$run_dir/../../memory/lessons.jsonl" ]] && memory_file="$run_dir/../../memory/lessons.jsonl"
    if [[ -f "$memory_file" ]]; then
        local deferred_warnings
        deferred_warnings=$(grep -c '"severity":"warning"' "$memory_file" 2>/dev/null) || deferred_warnings=0
        if [[ "$deferred_warnings" -ge 3 ]]; then
            detected+=("broken_window|$deferred_warnings WARNINGs deferred across runs in memory")
        fi
    fi

    if [[ ${#detected[@]} -eq 0 ]]; then
        return 1
    fi

    for d in "${detected[@]}"; do
        echo "$d"
    done
    return 0
}

# ============================================================
# Event logging
# ============================================================

# Cycle of a run: 1 + the number of cycle.boundary events in its log.
current_cycle() {
    local ef=".archeflow/events/$1.jsonl" n=0
    [[ -f "$ef" ]] && { n=$(jq -c 'select(type == "object" and .type == "cycle.boundary")' "$ef" 2>/dev/null | wc -l | tr -d ' ') || n=0; }
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    echo $((n + 1))
}

# emit_shadow <run_id> <phase> <agent> <archetype> <shadow> <trigger> <cycle> <action>
emit_shadow() {
    [[ -x "${SCRIPT_DIR}/archeflow-event.sh" ]] || return 0
    local data
    data=$(jq -cn --arg a "$4" --arg s "$5" --arg t "$6" --arg c "$7" --arg act "$8" \
        '{archetype: $a, shadow: $s, trigger: $t, action: $act}
         + (if $c == "" then {} else {cycle: ($c | tonumber)} end)')
    "${SCRIPT_DIR}/archeflow-event.sh" "$1" "shadow.detected" "$2" "$3" "$data" >/dev/null 2>&1 || true
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
        detect)
            if [[ "${ARCHEFLOW_SHADOWS:-on}" == "off" ]]; then
                echo "SKIPPED: shadow detection disabled (ARCHEFLOW_SHADOWS=off)"
                exit 1
            fi

            local archetype="${1:-}"
            local artifact="${2:-}"
            shift 2 || usage

            local proposal_file=""
            local diff_file=""
            local run_id=""
            local task_words="${ARCHEFLOW_TASK_WORDS:-}"
            local cycle=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --proposal) proposal_file="$2"; shift 2 ;;
                    --diff)     diff_file="$2"; shift 2 ;;
                    --run-id)   run_id="$2"; shift 2 ;;
                    --task-words) task_words="$2"; shift 2 ;;
                    --cycle)    cycle="$2"; shift 2 ;;
                    *) echo "Unknown option: $1" >&2; exit 2 ;;
                esac
            done

            [[ -z "$archetype" || -z "$artifact" ]] && usage
            if [[ -n "$cycle" && ! "$cycle" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --cycle must be a positive integer" >&2; exit 2
            fi
            if [[ -n "$task_words" && ! "$task_words" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --task-words must be a positive integer" >&2; exit 2
            fi
            [[ ! -f "$artifact" ]] && { echo "Error: artifact file not found: $artifact" >&2; exit 2; }
            if [[ "$archetype" == "maker" ]]; then
                [[ -n "$diff_file" ]] || { echo "Error: detect maker needs --diff <do-maker.diff> (files come from the diff, test evidence from the report)" >&2; exit 2; }
                [[ -f "$diff_file" ]] || { echo "Error: diff file not found: $diff_file" >&2; exit 2; }
            fi
            if [[ -n "$run_id" ]] && [[ ! "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "$run_id" == *..* ]]; then
                echo "Error: invalid run ID: $run_id" >&2; exit 2
            fi

            local result=""
            case "$archetype" in
                explorer)  result=$(detect_explorer "$artifact") || true ;;
                creator)   result=$(detect_creator "$artifact" "$task_words") || true ;;
                maker)     result=$(detect_maker "$artifact" "$proposal_file" "$diff_file") || true ;;
                guardian)  result=$(detect_guardian "$artifact") || true ;;
                skeptic)   result=$(detect_skeptic "$artifact") || true ;;
                trickster) result=$(detect_trickster "$artifact" "$diff_file") || true ;;
                sage)      result=$(detect_sage "$artifact" "$diff_file") || true ;;
                *) echo "Error: unknown archetype: $archetype" >&2; exit 2 ;;
            esac

            if [[ -n "$result" ]]; then
                local shadow_name="${result%%|*}"
                local trigger="${result#*|}"
                echo "SHADOW_DETECTED: $archetype/$shadow_name — $trigger"

                if [[ -n "$run_id" ]]; then
                    local phase="check"
                    case "$archetype" in explorer|creator) phase="plan" ;; maker) phase="do" ;; esac
                    [[ -n "$cycle" ]] || cycle=$(current_cycle "$run_id")
                    emit_shadow "$run_id" "$phase" "$archetype" "$archetype" "$shadow_name" "$trigger" "$cycle" "correction_prompt"
                fi
                exit 0
            else
                echo "CLEAN: $archetype — no shadow detected"
                exit 1
            fi
            ;;

        check-system)
            if [[ "${ARCHEFLOW_SHADOWS:-on}" == "off" ]]; then
                echo "SKIPPED: shadow detection disabled (ARCHEFLOW_SHADOWS=off)"
                exit 1
            fi

            [[ -n "${1:-}" ]] || { echo "Error: run ID or run directory required" >&2; exit 2; }
            local target="$1" sys_cycle=""
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --cycle) [[ $# -ge 2 ]] || { echo "Error: --cycle needs a value" >&2; exit 2; }
                             sys_cycle="$2"; shift 2 ;;
                    *) echo "Unknown option: $1" >&2; exit 2 ;;
                esac
            done
            if [[ -n "$sys_cycle" && ! "$sys_cycle" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --cycle must be a positive integer" >&2; exit 2
            fi
            resolve_run "$target"

            local result
            if result=$(detect_system_shadows "$RUN_DIR" "$EVENT_FILE" "$sys_cycle"); then
                echo "SYSTEM_SHADOW_DETECTED:"
                echo "$result" | while IFS='|' read -r name trigger; do
                    echo "  - $name: $trigger"
                done
                # Log each detection when called with a run ID (not a directory).
                if [[ ! -d "$target" ]]; then
                    [[ -n "$sys_cycle" ]] || sys_cycle=$(current_cycle "$target")
                    local name trigger
                    while IFS='|' read -r name trigger; do
                        [[ -n "$name" ]] && emit_shadow "$target" "act" "system" "system" "$name" "$trigger" "$sys_cycle" "corrective_action"
                    done <<< "$result"
                fi
                exit 0
            else
                echo "CLEAN: no system shadows detected"
                exit 1
            fi
            ;;

        *)
            usage
            ;;
    esac
}

main "$@"
