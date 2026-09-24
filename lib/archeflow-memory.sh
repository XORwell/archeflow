#!/usr/bin/env bash
# archeflow-memory.sh — Cross-run memory for ArcheFlow orchestrations.
#
# Extracts lessons from completed runs, injects known issues into agent prompts,
# and manages lesson lifecycle (add, list, decay, forget).
#
# Usage:
#   ./lib/archeflow-memory.sh extract <events.jsonl>     # Extract lessons from a completed run
#   ./lib/archeflow-memory.sh inject <domain> <archetype> # Output relevant lessons for injection
#   ./lib/archeflow-memory.sh add <type> <description>    # Manually add a lesson
#   ./lib/archeflow-memory.sh list                        # List all active lessons
#   ./lib/archeflow-memory.sh decay                       # Apply decay to all lessons
#   ./lib/archeflow-memory.sh forget <id>                 # Archive a lesson by ID
#   ./lib/archeflow-memory.sh regression-check <events>  # Detect regressions from previously fixed findings
#
# Dependencies: jq, bash 4+
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed. Install: https://jqlang.github.io/jq/" >&2; exit 1; }

# shellcheck source=lib/archeflow-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archeflow-common.sh"

MEMORY_DIR=".archeflow/memory"
LESSONS_FILE="${MEMORY_DIR}/lessons.jsonl"
ARCHIVE_FILE="${MEMORY_DIR}/archive.jsonl"

# --- Helpers ---

ensure_dir() {
  mkdir -p "$MEMORY_DIR"
}

next_id() {
  if [[ ! -f "$LESSONS_FILE" ]]; then
    echo "m-001"
    return
  fi
  # lessons.jsonl can come from the repository: only ids of the form m-<digits>
  # count, and the number goes through af_as_int before any arithmetic
  # (an id like "m-1+a[$(cmd)]" must never reach $(( ))).
  local max_num
  max_num=$(jq -r '.id | strings | ltrimstr("m-") | select(test("^[0-9]{1,9}$"))' "$LESSONS_FILE" 2>/dev/null \
    | sort -n \
    | tail -1)
  max_num=$(af_as_int "$max_num" "")
  if [[ -z "$max_num" ]]; then
    echo "m-001"
  else
    printf "m-%03d" $(( max_num + 1 ))
  fi
}

now_ts() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Tokenize a description into sorted unique lowercase keywords (min 3 chars)
tokenize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | awk 'length >= 3' | sort -u
}

# Calculate keyword overlap ratio between two descriptions
# Returns a value 0-100 (percentage)
keyword_overlap() {
  local desc_a="$1"
  local desc_b="$2"
  local tokens_a tokens_b common total_a

  tokens_a=$(tokenize "$desc_a")
  tokens_b=$(tokenize "$desc_b")

  if [[ -z "$tokens_a" || -z "$tokens_b" ]]; then
    echo "0"
    return
  fi

  total_a=$(echo "$tokens_a" | wc -l)
  common=$(comm -12 <(echo "$tokens_a") <(echo "$tokens_b") | wc -l)

  if [[ "$total_a" -eq 0 ]]; then
    echo "0"
  else
    echo $(( common * 100 / total_a ))
  fi
}

# --- Commands ---

cmd_extract() {
  local events_file="$1"

  if [[ ! -f "$events_file" ]]; then
    echo "Error: events file not found: $events_file" >&2
    exit 1
  fi

  ensure_dir

  # Extract run_id from the first event
  local run_id
  run_id=$(jq -r '.run_id' "$events_file" | head -1)

  # Extract all findings from review.verdict events
  local findings
  findings=$(jq -c '
    select(.type == "review.verdict") |
    .data as $d |
    ($d.findings // [])[] |
    {
      source: ($d.archetype // "unknown"),
      severity: .severity,
      description: .description,
      category: (.category // "general")
    }
  ' "$events_file" 2>/dev/null || true)

  if [[ -z "$findings" ]]; then
    echo "[archeflow-memory] No findings to extract from $events_file" >&2
    return 0
  fi

  local updated=0
  local added=0

  # Process each finding
  while IFS= read -r finding; do
    local desc source severity category
    desc=$(echo "$finding" | jq -r '.description')
    source=$(echo "$finding" | jq -r '.source')
    severity=$(echo "$finding" | jq -r '.severity')
    category=$(echo "$finding" | jq -r '.category')

    # Skip INFO-level findings for auto-extraction
    if [[ "$severity" == "info" || "$severity" == "recommendation" ]]; then
      continue
    fi

    # Check against existing lessons
    local matched=false
    if [[ -f "$LESSONS_FILE" ]]; then
      while IFS= read -r lesson; do
        local lesson_desc lesson_id overlap
        lesson_desc=$(echo "$lesson" | jq -r '.description')
        lesson_id=$(echo "$lesson" | jq -r '.id')
        overlap=$(keyword_overlap "$desc" "$lesson_desc")

        if [[ "$overlap" -ge 50 ]]; then
          # Match found — update existing lesson
          local tmp_file; tmp_file=$(af_tmpfile "$LESSONS_FILE")
          jq -c --arg lid "$lesson_id" --arg ts "$(now_ts)" --arg rid "$run_id" '
            if .id == $lid then
              .frequency = (((.frequency | numbers) // 0) + 1) |
              .ts = $ts |
              .last_seen_run = $rid |
              .runs_since_last_seen = 0
            else . end
          ' "$LESSONS_FILE" > "$tmp_file"
          mv "$tmp_file" "$LESSONS_FILE"
          matched=true
          updated=$((updated + 1))
          echo "[archeflow-memory] Updated lesson $lesson_id (freq +1): $lesson_desc" >&2
          break
        fi
      done < "$LESSONS_FILE"
    fi

    if [[ "$matched" == "false" ]]; then
      # New finding — add as candidate (frequency=1)
      local new_id
      new_id=$(next_id)
      local tags
      tags=$(echo "$desc" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | awk 'length >= 4' | head -5 | jq -R . | jq -sc .)

      af_append "$LESSONS_FILE" "$(jq -cn \
        --arg id "$new_id" \
        --arg ts "$(now_ts)" \
        --arg run_id "$run_id" \
        --arg source "$source" \
        --arg desc "$desc" \
        --arg severity "$severity" \
        --arg category "$category" \
        --argjson tags "$tags" \
        '{
          id: $id,
          ts: $ts,
          run_id: $run_id,
          type: "pattern",
          source: $source,
          description: $desc,
          frequency: 1,
          severity: $severity,
          domain: $category,
          tags: $tags,
          archetype: null,
          last_seen_run: $run_id,
          runs_since_last_seen: 0
        }')"

      added=$((added + 1))
      echo "[archeflow-memory] Added candidate lesson $new_id: $desc" >&2
    fi
  done <<< "$findings"

  echo "[archeflow-memory] Extract complete: $updated updated, $added new candidates" >&2
}

cmd_inject() {
  local domain="${1:-}"
  local archetype="${2:-}"

  # Parse optional --audit <run_id>
  local audit_run_id=""
  shift 2 2>/dev/null || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --audit) audit_run_id="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ ! -f "$LESSONS_FILE" ]]; then
    return 0
  fi

  # Build jq filter for relevant lessons
  # Rules:
  #   - frequency >= 2 for patterns/archetype_hints/anti_patterns
  #   - frequency >= 1 for preferences (always injected)
  #   - frequency >= 5 always injected (universal)
  #   - Filter by domain (match or "general") and archetype (if provided)
  #   - Sort by frequency desc, cap at 10
  local lessons
  lessons=$(jq -c --arg domain "$domain" --arg archetype "$archetype" '
    select(
      (.type == "preference") or
      (.frequency >= 5) or
      (
        (.frequency >= 2) and
        (
          ($domain == "") or
          (.domain == $domain) or
          (.domain == "general")
        ) and
        (
          ($archetype == "") or
          (.archetype == null) or
          (.archetype == $archetype)
        )
      )
    )
  ' "$LESSONS_FILE" 2>/dev/null | jq -sc 'sort_by(-.frequency) | .[:10][]' 2>/dev/null || true)

  if [[ -z "$lessons" ]]; then
    return 0
  fi

  # Collect injected lesson IDs for audit
  local injected_ids=()

  echo "## Known Issues (from past runs)"
  while IFS= read -r lesson; do
    local desc freq src lid
    desc=$(echo "$lesson" | jq -r '.description')
    freq=$(echo "$lesson" | jq -r '.frequency')
    src=$(echo "$lesson" | jq -r '.source')
    lid=$(echo "$lesson" | jq -r '.id')
    injected_ids+=("$lid")
    echo "- ${desc} [seen ${freq}x, ${src}]"
  done <<< "$lessons"

  # Write audit record if --audit was passed
  if [[ -n "$audit_run_id" && ${#injected_ids[@]} -gt 0 ]]; then
    ensure_dir
    local AUDIT_FILE="${MEMORY_DIR}/audit.jsonl"
    local ids_json
    ids_json=$(printf '%s\n' "${injected_ids[@]}" | jq -R . | jq -sc .)
    af_append "$AUDIT_FILE" "$(jq -cn \
      --arg ts "$(now_ts)" \
      --arg run_id "$audit_run_id" \
      --arg domain "$domain" \
      --arg archetype "$archetype" \
      --argjson lessons_injected "$ids_json" \
      --argjson lesson_count "${#injected_ids[@]}" \
      '{ts:$ts,run_id:$run_id,domain:$domain,archetype:$archetype,lessons_injected:$lessons_injected,lesson_count:$lesson_count}')"
  fi
}

cmd_audit_check() {
  local run_id="${1:?Usage: $0 audit-check <run_id>}"
  af_require_run_id "$run_id"
  local AUDIT_FILE="${MEMORY_DIR}/audit.jsonl"
  local EVENTS_FILE=".archeflow/events/${run_id}.jsonl"

  if [[ ! -f "$AUDIT_FILE" ]]; then
    echo "No audit records found." >&2
    return 0
  fi

  if [[ ! -f "$EVENTS_FILE" ]]; then
    echo "No events file found for run $run_id." >&2
    return 0
  fi

  # Get lessons injected for this run
  local injected
  injected=$(jq -c --arg rid "$run_id" 'select(.run_id == $rid)' "$AUDIT_FILE" 2>/dev/null || true)

  if [[ -z "$injected" ]]; then
    echo "No audit records for run $run_id." >&2
    return 0
  fi

  # Get all finding descriptions from review.verdict events
  local finding_descs
  finding_descs=$(jq -r '
    select(.type == "review.verdict") |
    .data.findings[]? | .description // empty
  ' "$EVENTS_FILE" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)

  # For each injected lesson, check if findings match the lesson's topic
  local lesson_ids
  lesson_ids=$(echo "$injected" | jq -r '.lessons_injected[]' 2>/dev/null | sort -u)

  while IFS= read -r lid; do
    [[ -z "$lid" ]] && continue

    # Get lesson description
    local lesson_desc
    lesson_desc=$(jq -r --arg lid "$lid" 'select(.id == $lid) | .description' "$LESSONS_FILE" 2>/dev/null | head -1)
    [[ -z "$lesson_desc" ]] && continue

    # Check keyword overlap between lesson and findings
    local lesson_tokens finding_overlap
    lesson_tokens=$(tokenize "$lesson_desc")
    finding_overlap=0

    if [[ -n "$finding_descs" ]]; then
      local finding_tokens
      finding_tokens=$(echo "$finding_descs" | tr -cs '[:alnum:]' '\n' | awk 'length >= 3' | sort -u)
      local common
      common=$(comm -12 <(echo "$lesson_tokens") <(echo "$finding_tokens") | wc -l)
      local total
      total=$(echo "$lesson_tokens" | wc -l)
      if [[ "$total" -gt 0 ]]; then
        finding_overlap=$(( common * 100 / total ))
      fi
    fi

    local effectiveness
    if [[ "$finding_overlap" -ge 30 ]]; then
      effectiveness="ineffective"  # Issue repeated despite lesson injection
    else
      effectiveness="helpful"  # Issue was prevented (no matching finding)
    fi

    # Append result to audit.jsonl
    af_append "$AUDIT_FILE" "$(jq -cn \
      --arg ts "$(now_ts)" \
      --arg run_id "$run_id" \
      --arg lesson_id "$lid" \
      --arg lesson_desc "$lesson_desc" \
      --arg effectiveness "$effectiveness" \
      --argjson overlap "$finding_overlap" \
      '{ts:$ts,run_id:$run_id,type:"effectiveness_check",lesson_id:$lesson_id,lesson_desc:$lesson_desc,effectiveness:$effectiveness,keyword_overlap_pct:$overlap}')"

    echo "[archeflow-memory] Lesson $lid ($effectiveness): $lesson_desc" >&2
  done <<< "$lesson_ids"
}

cmd_regression_check() {
  local events_file="${1:?Usage: $0 regression-check <events.jsonl>}"

  if [[ ! -f "$events_file" ]]; then
    echo "Error: events file not found: $events_file" >&2
    exit 1
  fi

  # Extract current run_id
  local run_id
  run_id=$(jq -r '.run_id' "$events_file" | head -1)

  # Find the previous run from index.jsonl
  local INDEX_FILE=".archeflow/events/index.jsonl"
  if [[ ! -f "$INDEX_FILE" ]]; then
    echo "[archeflow-memory] No index.jsonl found — skipping regression check." >&2
    return 0
  fi

  local prev_run_id
  # Get the most recent run that is not the current one (index is append-newest-last)
  prev_run_id=$(jq -r --arg rid "$run_id" 'select(.run_id != $rid) | .run_id' "$INDEX_FILE" 2>/dev/null | tail -1)
  # Note: tail -1 gives the last non-current entry, which is the most recent previous run

  if [[ -z "$prev_run_id" ]]; then
    echo "[archeflow-memory] No previous run found — skipping regression check." >&2
    return 0
  fi
  # index.jsonl is data: its run_id becomes a path, so validate it like any run ID.
  if ! af_valid_name "$prev_run_id"; then
    echo "[archeflow-memory] Ignoring invalid run_id in index.jsonl: '$prev_run_id'" >&2
    return 0
  fi

  local prev_events=".archeflow/events/${prev_run_id}.jsonl"
  if [[ ! -f "$prev_events" ]]; then
    echo "[archeflow-memory] Previous run events not found: $prev_events" >&2
    return 0
  fi

  # Extract resolved findings from previous run (fix.applied events)
  local resolved_findings
  resolved_findings=$(jq -r 'select(.type == "fix.applied") | .data.finding // empty' "$prev_events" 2>/dev/null || true)

  if [[ -z "$resolved_findings" ]]; then
    echo "[archeflow-memory] No resolved findings in previous run — nothing to regress." >&2
    return 0
  fi

  # Extract current run findings from review.verdict events
  local current_findings
  current_findings=$(jq -r '
    select(.type == "review.verdict") |
    .data.findings[]? | .description // empty
  ' "$events_file" 2>/dev/null || true)

  if [[ -z "$current_findings" ]]; then
    echo "[archeflow-memory] No findings in current run — no regressions." >&2
    return 0
  fi

  # Compare: for each resolved finding, check if it reappeared
  local regressions=0
  while IFS= read -r resolved; do
    [[ -z "$resolved" ]] && continue

    while IFS= read -r current; do
      [[ -z "$current" ]] && continue
      local overlap
      overlap=$(keyword_overlap "$resolved" "$current")
      if [[ "$overlap" -ge 50 ]]; then
        echo "REGRESSION: \"$resolved\" (fixed in $prev_run_id) reappeared as \"$current\""
        regressions=$((regressions + 1))
        break
      fi
    done <<< "$current_findings"
  done <<< "$resolved_findings"

  if [[ "$regressions" -gt 0 ]]; then
    echo "[archeflow-memory] $regressions regression(s) detected from run $prev_run_id." >&2
    return 1
  else
    echo "[archeflow-memory] No regressions detected." >&2
    return 0
  fi
}

cmd_add() {
  local type="${1:-preference}"
  local desc="${2:-}"

  if [[ -z "$desc" ]]; then
    echo "Usage: $0 add <type> <description>" >&2
    echo "Types: pattern, preference, archetype_hint, anti_pattern" >&2
    exit 1
  fi

  ensure_dir

  local new_id
  new_id=$(next_id)
  local tags
  tags=$(echo "$desc" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | awk 'length >= 4' | head -5 | jq -R . | jq -sc .)

  af_append "$LESSONS_FILE" "$(jq -cn \
    --arg id "$new_id" \
    --arg ts "$(now_ts)" \
    --arg type "$type" \
    --arg desc "$desc" \
    --argjson tags "$tags" \
    '{
      id: $id,
      ts: $ts,
      run_id: "manual",
      type: $type,
      source: "user_feedback",
      description: $desc,
      frequency: 1,
      severity: "info",
      domain: "general",
      tags: $tags,
      archetype: null,
      last_seen_run: "",
      runs_since_last_seen: 0
    }')"

  echo "[archeflow-memory] Added lesson $new_id ($type): $desc" >&2
}

cmd_list() {
  if [[ ! -f "$LESSONS_FILE" ]]; then
    echo "No lessons stored yet." >&2
    return 0
  fi

  printf "%-8s %-5s %-16s %-8s %s\n" "ID" "Freq" "Type" "Domain" "Description"
  printf "%-8s %-5s %-16s %-8s %s\n" "----" "----" "----" "------" "-----------"
  jq -r '[.id, (.frequency|tostring), .type, .domain, .description] | @tsv' "$LESSONS_FILE" \
    | while IFS=$'\t' read -r id freq type domain desc; do
        printf "%-8s %-5s %-16s %-8s %s\n" "$id" "$freq" "$type" "$domain" "$desc"
      done
}

cmd_decay() {
  if [[ ! -f "$LESSONS_FILE" ]]; then
    return 0
  fi

  ensure_dir

  af_refuse_symlink "$ARCHIVE_FILE" || exit 1
  local tmp_file; tmp_file=$(af_tmpfile "$LESSONS_FILE")
  local archived=0
  local decayed=0

  # Process each lesson
  : > "$tmp_file"
  while IFS= read -r lesson; do
    local runs_since freq id
    # Numeric fields come from a file the repository may supply: read them as
    # JSON numbers only and pass them through af_as_int before any arithmetic.
    runs_since=$(af_as_int "$(echo "$lesson" | jq -r '(.runs_since_last_seen | numbers | floor) // 0' 2>/dev/null)")
    freq=$(af_as_int "$(echo "$lesson" | jq -r '(.frequency | numbers | floor) // 0' 2>/dev/null)")
    id=$(echo "$lesson" | jq -r '.id')

    # Increment runs_since_last_seen
    runs_since=$((runs_since + 1))

    if [[ "$runs_since" -ge 10 ]]; then
      freq=$((freq - 1))
      runs_since=0
      decayed=$((decayed + 1))

      if [[ "$freq" -le 0 ]]; then
        # Archive the lesson
        echo "$lesson" | jq -c --arg ts "$(now_ts)" '.frequency = 0 | .ts = $ts' >> "$ARCHIVE_FILE"
        archived=$((archived + 1))
        echo "[archeflow-memory] Archived lesson $id (frequency reached 0)" >&2
        continue
      fi
    fi

    echo "$lesson" | jq -c \
      --argjson freq "$freq" \
      --argjson runs_since "$runs_since" \
      '.frequency = $freq | .runs_since_last_seen = $runs_since' >> "$tmp_file"
  done < "$LESSONS_FILE"

  mv "$tmp_file" "$LESSONS_FILE"
  echo "[archeflow-memory] Decay complete: $decayed decayed, $archived archived" >&2
}

cmd_forget() {
  local target_id="$1"

  if [[ ! -f "$LESSONS_FILE" ]]; then
    echo "No lessons file found." >&2
    exit 1
  fi

  ensure_dir

  # Check if the lesson exists
  if ! jq -e --arg tid "$target_id" 'select(.id == $tid)' "$LESSONS_FILE" > /dev/null 2>&1; then
    echo "Error: lesson $target_id not found." >&2
    exit 1
  fi

  # Archive the lesson
  af_refuse_symlink "$ARCHIVE_FILE" || exit 1
  jq -c --arg tid "$target_id" 'select(.id == $tid)' "$LESSONS_FILE" >> "$ARCHIVE_FILE"

  # Remove from lessons
  local tmp_file; tmp_file=$(af_tmpfile "$LESSONS_FILE")
  jq -c --arg tid "$target_id" 'select(.id != $tid)' "$LESSONS_FILE" > "$tmp_file"
  mv "$tmp_file" "$LESSONS_FILE"

  echo "[archeflow-memory] Forgot lesson $target_id (moved to archive)" >&2
}

# --- Main ---

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <command> [args...]" >&2
  echo "" >&2
  echo "Commands:" >&2
  echo "  extract <events.jsonl>       Extract lessons from a completed run" >&2
  echo "  inject <domain> <archetype> [--audit <run_id>]  Output relevant lessons for injection" >&2
  echo "  add <type> <description>     Manually add a lesson" >&2
  echo "  list                         List all active lessons" >&2
  echo "  decay                        Apply decay to all lessons" >&2
  echo "  forget <id>                  Archive a lesson by ID" >&2
  echo "  audit-check <run_id>         Check lesson effectiveness for a run" >&2
  echo "  regression-check <events.jsonl>  Detect regressions from previously fixed findings" >&2
  exit 1
fi


# Serialize mutating commands: concurrent read-modify-write of LESSONS_FILE from
# parallel agents would otherwise lose updates.
# shellcheck source=lib/archeflow-lock.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archeflow-lock.sh"
_af_serialize() {
  mkdir -p "$(dirname "$LESSONS_FILE")"
  af_lock "$LESSONS_FILE.lock" 30 || { echo "Error: could not lock $LESSONS_FILE" >&2; exit 1; }
  trap 'af_unlock "$LESSONS_FILE.lock"' EXIT
}

COMMAND="$1"
shift

case "$COMMAND" in
  extract|add|decay|forget) _af_serialize ;;
esac

case "$COMMAND" in
  extract)
    [[ $# -lt 1 ]] && { echo "Usage: $0 extract <events.jsonl>" >&2; exit 1; }
    cmd_extract "$1"
    ;;
  inject)
    cmd_inject "$@"
    ;;
  add)
    [[ $# -lt 2 ]] && { echo "Usage: $0 add <type> <description>" >&2; exit 1; }
    cmd_add "$1" "$2"
    ;;
  list)
    cmd_list
    ;;
  decay)
    cmd_decay
    ;;
  forget)
    [[ $# -lt 1 ]] && { echo "Usage: $0 forget <id>" >&2; exit 1; }
    cmd_forget "$1"
    ;;
  audit-check)
    [[ $# -lt 1 ]] && { echo "Usage: $0 audit-check <run_id>" >&2; exit 1; }
    cmd_audit_check "$1"
    ;;
  regression-check)
    [[ $# -lt 1 ]] && { echo "Usage: $0 regression-check <events.jsonl>" >&2; exit 1; }
    cmd_regression_check "$1"
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    exit 1
    ;;
esac
