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

# The report used to run several jq processes per event (25 s for a thousand
# events). It now reads the log in two jq passes: one for the run metadata and
# one that renders the Phases, Cycle Comparison and Artifacts sections. Both
# reproduce the earlier output byte for byte, including how `jq -r` prints
# non-string values and how "$(...)" drops trailing newlines, so the helpers
# below mirror those rules:
#   raw       what `jq -r` prints for a value (strings as-is, else indented JSON)
#   cap(f)    "$(echo "$event" | jq -r f)": outputs joined by newlines, trailing
#             newlines and NUL bytes dropped; null when f fails (the old script
#             aborted with status 5 there)
#   gcap(f)   the same for "... 2>/dev/null || true": output up to an error
JQ_LIB="${JQ_NUM}"'
  def pp($i):
    if type == "object" then
      (if length == 0 then "{}" else
        "{\n" + ([to_entries[] | $i + "  " + (.key | tojson) + ": " + (.value | pp($i + "  "))] | join(",\n"))
        + "\n" + $i + "}" end)
    elif type == "array" then
      (if length == 0 then "[]" else
        "[\n" + (map($i + "  " + pp($i + "  ")) | join(",\n")) + "\n" + $i + "]" end)
    else tojson end;
  def raw: if type == "string" then . else pp("") end;
  def rstrip_nl: if endswith("\n") then .[:-1] | rstrip_nl else . end;
  def nonul: if contains("\u0000") then split("\u0000") | join("") else . end;
  def cap(f): try ([f | raw] | join("\n") | nonul | rstrip_nl) catch null;
  def gcap(f): [try (f | raw)] | join("\n") | nonul | rstrip_nl;
  # "echo" treats a lone -n/-e/-E argument as an option and prints nothing.
  def echoed: if test("^-[neE]+$") then "" else . end;
'

# Run metadata, NUL-separated: status, then the fields read below.
# Status "abort" (exit 5, no output) mirrors the old script, which stopped when
# the last JSON value in the file was not an object (or null) or when the
# run.start fields could not be read.
read_meta() {
  jq -j -s "${JQ_LIB}"'
    def isnull: . == null;
    . as $all
    | [.[] | objects] as $ev
    | ([$ev[] | select(.type == "run.start")] | first) as $s
    | ([$ev[] | select(.type == "run.complete")] | first) as $c
    | if ($all | length) > 0 and ($all | last | type | . != "object" and . != "null")
      then ["abort"]
      else
        (if $s == null then ["", "", ""]
         else [($s | cap(.run_id // "unknown")), ($s | cap(.data.task // "unknown")),
               ($s | cap(.data.workflow // "unknown"))] end) as $ids
        | if ($ids | map(select(isnull)) | length) > 0 then ["abort"]
          else
            # Team: data.team if given, else the roles that took part, in order of appearance.
            ((if $s == null then "" else ($s | gcap(.data.team // empty
                | if type == "array" then map(tostring) | join(", ") else tostring end)) end)
             | if . != "" then . else
                 ($all | gcap([ .[] | objects
                   | select(.type == "agent.start" or .type == "agent.complete" or .type == "review.verdict")
                   | (.data.archetype? // .agent) | strings | select(. != "" and . != "system") ]
                   | reduce .[] as $r ([]; if index([$r]) then . else . + [$r] end) | join(", ")))
               end
             | if . == "" then "unknown" else . end) as $team
            | (if $c == null then [null, null, null, null]
               else [($c | cap(.data.status // "unknown")), ($c | cap(.data.cycles // "?")),
                     ($c | cap(.data.agents_total // .data.agents // "?")),
                     ($c | cap(.data.fixes_total // .data.fixes // "?"))] end) as $ov
            | (if $c == null then ""
               else ($c | gcap(.data.shadows // empty | tostring))
                    | if . != "" then . else ([$ev[] | select(.type == "shadow.detected")] | length | tostring) end
               end) as $shadows
            # Run duration in whole seconds, or "" if unknown.
            | (first(($all | try (
                  def t: (.ts | strings | try fromdateiso8601 catch null) // null;
                  [ .[] | objects ] as $ev
                  | ([ $ev[] | select(.type == "run.start") ] | first) as $s
                  | ([ $ev[] | select(.type == "run.complete") ] | last) as $c
                  | (if $c == null then null else ($c.data.duration_ms? | num) end) as $ms
                  | if $ms != null and $ms > 0 then ($ms / 1000 | floor | tostring)
                    elif $s != null and $c != null and ($s | t) != null and ($c | t) != null
                         and ($c | t) >= ($s | t) then (($c | t) - ($s | t) | floor | tostring)
                    else "" end)), "") // "") as $dur
            | (if $s == null then "" else ($s | cap(.data.config // empty)) end) as $config
            | ["ok"] + $ids
              + [$team,
                 (if ([$ev[] | select(.type == "run.merged")] | length) > 0 then "yes" else "" end),
                 (if $c != null then "yes" else "" end),
                 (if $c != null and ($ov | map(select(isnull)) | length) > 0 then "yes" else "" end)]
              + ($ov | map(. // ""))
              + [$shadows, $dur, ($config // ""), (if $config == null then "yes" else "" end)]
          end
      end
    | .[] | tostring | nonul + "\u0000"
  ' "$EVENT_FILE"
}

META=()
while IFS= read -r -d '' _field; do META+=("$_field"); done < <(read_meta || true)
if [[ "${META[0]:-}" != "ok" || ${#META[@]} -ne 16 ]]; then
  echo "Error: cannot read the event log: $EVENT_FILE" >&2
  exit 5
fi
RUN_ID="${META[1]}"
TASK="${META[2]}"
WORKFLOW="${META[3]}"
TEAM="${META[4]}"
# A merge confirmed after the run ended (awaiting_merge) is logged as run.merged.
MERGED="${META[5]}"
HAS_COMPLETE="${META[6]}"
COMPLETE_UNREADABLE="${META[7]}"
STATUS="${META[8]}"
CYCLES="${META[9]}"
AGENTS="${META[10]}"
FIXES="${META[11]}"
SHADOWS="${META[12]}"
DURATION_RAW="${META[13]}"
CONFIG="${META[14]}"
CONFIG_UNREADABLE="${META[15]}"

# "<1 min", "~N min", or nothing if unknown.
duration_display() {
  local secs
  secs=$(af_as_int "$DURATION_RAW" "")
  [[ -n "$secs" ]] || return 0
  if [[ "$secs" -lt 60 ]]; then
    echo "<1 min"
  else
    echo "~$((secs / 60)) min"
  fi
}

# --summary mode: one-line output and exit
if [[ "$MODE" == "summary" ]]; then
  if [[ -n "$HAS_COMPLETE" ]]; then
    [[ -z "$COMPLETE_UNREADABLE" ]] || exit 5
    [[ -n "$MERGED" ]] && STATUS="merged"
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

# Phases, Cycle Comparison and Artifacts sections in one jq pass. The Phases
# section walks the file line by line (as `while read` did: a last line without
# a newline is not rendered) and stops with status 5 at an event the old
# per-event jq calls could not read, after printing what came before it.
render_body() {
  jq -j -s --rawfile raw "$EVENT_FILE" "${JQ_LIB}"'
    def upcased: echoed | ascii_upcase;
    # Number of values in the sorted array $a that sort before $x.
    def below($a; $x):
      def go($lo; $hi):
        if $lo >= $hi then $lo
        else (($lo + $hi) / 2 | floor) as $m
          | if $a[$m] < $x then go($m + 1; $hi) else go($lo; $m) end end;
      go(0; $a | length);
    # af_as_int: a plain integer of up to 18 digits (leading zeros dropped), else "0".
    def as_int:
      if test("^-?[0-9]{1,18}$") then
        (if startswith("-") then "-" else "" end) as $sign
        | (ltrimstr("-") | sub("^0+"; "")) as $d
        | if $d == "" then "0" else $sign + $d end
      else "0" end;

    def event_text($e):
      ($e | cap(.type)) as $type
      | if $type == "agent.complete" then
          ($e | cap(.data.archetype // .agent // "unknown")) as $arch
          | ($e | gcap((.data.duration_ms | num) // 0 | . / 1000 | floor) | as_int) as $secs
          | ($e | gcap([ ((.data.tokens | num) // 0 | select(. > 0) | "\(.) tokens"),
                ((.data.estimated_cost_usd | num) // null | select(. != null) | "$\(. * 100 | round / 100)") ]
                | map(", " + .) | join(""))) as $extras
          | ($e | cap(.data.summary // "no summary")) as $summary
          | ($e | gcap((.data.artifacts // []) | if type == "array" then map(tostring) | join(", ") else tostring end)) as $arts
          | if $arch == null or $summary == null then {t: "", ab: true}
            else {t: ("**\($arch)** (\($secs)s\($extras))\n: \($summary)\n"
                      + (if $arts != "" then ": Artifacts: \($arts)\n" else "" end) + "\n")} end
        elif $type == "decision" then
          ($e | cap(.data.what // "unknown")) as $what
          | ($e | cap(.data.chosen // "unknown")) as $chosen
          | ($e | cap(.data.rationale // "")) as $why
          | if $what == null or $chosen == null or $why == null then {t: "", ab: true}
            else
              ("**Decision: \($what)**\n: Chosen: \($chosen)\n"
               + (if $why != "" then ": Rationale: \($why)\n" else "" end)) as $head
              | ($e | cap((.data.alternatives // [])[] | "  - ~" + .id + "~ " + .label + " — " + .reason_rejected)) as $alts
              | if $alts == null then {t: $head, ab: true}
                else {t: ($head + (if $alts != "" then ": Rejected:\n\($alts)\n" else "" end) + "\n")} end
            end
        elif $type == "review.verdict" then
          ($e | cap(.data.archetype // .agent // "unknown")) as $arch
          | ($e | cap(.data.verdict // "unknown")) as $verdict
          | if $arch == null or $verdict == null then {t: "", ab: true}
            else {t: ("**\($arch)** → \($verdict | upcased | split("_") | join(" "))\n"
                      + ([$e | try ((.data.findings // [])[] | "  - [" + .severity + "] " + .description | raw)]
                         | map(. + "\n") | join(""))
                      + "\n")} end
        elif $type == "fix.applied" then
          [$e | cap(.data.source // "unknown"), cap(.data.finding // "unknown"),
                cap(.data.file // ""), cap(.data.line // "")] as $f
          | if ($f | map(select(. == null)) | length) > 0 then {t: "", ab: true}
            elif $f[2] != "" and $f[3] != "null" and $f[3] != "" then
              {t: "- **Fix** (\($f[0])): \($f[1]) — `\($f[2]):\($f[3])`\n"}
            else {t: "- **Fix** (\($f[0])): \($f[1])\n"} end
        elif $type == "shadow.detected" then
          [$e | cap(.data.archetype // "unknown"), cap(.data.shadow // "unknown"), cap(.data.action // "unknown")] as $f
          | if ($f | map(select(. == null)) | length) > 0 then {t: "", ab: true}
            else {t: "- **Shadow** \($f[0]): \($f[1]) → \($f[2])\n\n"} end
        elif $type == "cycle.boundary" then
          # exit_condition/decision (reference.md); met/next_action from older logs.
          [$e | cap(.data.cycle // "?"), cap(.data.max_cycles // "?"),
                cap(.data.exit_condition // (if .data.met == true then "met"
                    elif .data.met == false then "not met" else "not recorded" end) | tostring),
                cap(.data.decision // .data.next_action // "not recorded" | tostring)] as $f
          | ($e | gcap([ ("critical", "warning", "info") as $k
                | select(.data[$k]? != null) | "\(.data[$k]) \($k | ascii_upcase)" ] | join(", "))) as $counts
          | if ($f | map(select(. == null)) | length) > 0 then {t: "", ab: true}
            else {t: ("\n---\n\n**Cycle \($f[0])/\($f[1])** — exit condition: \($f[2])"
                      + (if $counts != "" then " (\($counts))" else "" end) + " → \($f[3])\n\n")} end
        elif $type == "wiggum.break" then
          ($e | cap(.data.type // "?" | tostring)) as $btype
          | ($e | gcap([ (.data.triggers // [])[]? | .reason? | strings ] | join("; "))) as $reasons
          | if $btype == null then {t: "", ab: true}
            else {t: "- **Wiggum Break** (\($btype)): \($reasons)\n\n"} end
        elif $type == "run.merged" then
          ($e | cap(.data.base // "base branch" | tostring)) as $base
          | if $base == null then {t: "", ab: true} else {t: "- **Merged** into \($base)\n\n"} end
        else {t: ""} end;

    # One line of the log: phase header on a phase change, then the event.
    def line_step($ln; $cur):
      (if $ln | test("^[ \t\r]*$") then {e: null, type: "", phase: ""}
       else (try {e: ($ln | fromjson)} catch null)
         | if . == null then null
           else .e as $e | ($e | cap(.type)) as $type | ($e | cap(.phase)) as $phase
             | if $type == null or $phase == null then null
               else {e: $e, type: $type, phase: $phase} end
           end
       end) as $p
      | if $p == null then {cur: $cur, t: "", ab: true}
        else
          (if $p.phase != $cur and $p.type != "run.start" and $p.type != "run.complete"
           then {cur: $p.phase, h: "### \($p.phase | upcased)\n\n"} else {cur: $cur, h: ""} end) as $hd
          | (if $p.type == "" then {t: ""} else event_text($p.e) end) as $b
          | {cur: $hd.cur, t: ($hd.h + $b.t), ab: ($b.ab // false)}
        end;

    . as $all
    | [$all[] | objects] as $ev
    | ([$ev[] | select(.type == "run.complete")] | first) as $rc

    # Cycle Comparison, only when two or more cycle.boundary events carry a number.
    | def cycle_section:
        ([$ev[] | select(.type == "cycle.boundary") | try (.data.cycle | raw)]
          | join("\n") | split("\n") | map(select(test("[0-9]"))) | length) as $ncycles
        | if $ncycles < 2 then {t: ""}
          else
            "\n---\n\n## Cycle Comparison\n\n" as $head
            # A review.verdict belongs to cycle 1 + (number of cycle.boundary events before it).
            | (try ([$all[] | select(.type == "cycle.boundary") | .seq] | sort) catch null) as $bounds
            | (if $bounds == null then null else
                try [$all[] | select(.type == "review.verdict")
                     | {seq: .seq, verdict: .data.verdict, findings: (.data.findings // []),
                        cycle: (if ($bounds | length) == 0 then 1 else 1 + below($bounds; .seq) end)}]
                catch null end) as $recs
            | if $recs == null then {t: $head, ab: true}
              else
                ($recs | group_by(.cycle) | map({key: (.[0].cycle | tostring), value: .}) | from_entries) as $by
                | ($recs | map(.cycle) | unique) as $nums
                | def findings($c): try [$by[$c | tostring][] | .findings[] | {desc: .description, sev: .severity}] catch [];
                  def descset: reduce (.[] | .desc | strings) as $d ({}; .[$d] = true);
                  def has($set; $list; $d): if ($d | type) == "string" then $set[$d] != null else ($list | any(. == $d)) end;
                  {t: ($head + ([range(1; $nums | length) as $i
                    | findings($nums[$i - 1]) as $prev | findings($nums[$i]) as $curr
                    | ([$prev[].desc]) as $pd | ([$curr[].desc]) as $cd
                    | ($prev | descset) as $ps | ($curr | descset) as $cs
                    | (try (
                        ($curr | [.[] | select(.desc as $d | has($ps; $pd; $d) | not)]) as $new
                        | ($prev | [.[] | select(.desc as $d | has($cs; $cd; $d) | not)]) as $resolved
                        | ($curr | [.[] | select(.desc as $d | has($ps; $pd; $d))]) as $persistent
                        | (if ($new | length) > 0 then
                            ["**New findings:**"] + [$new[] | "- [" + .sev + "] " + .desc]
                          else [] end) +
                          (if ($resolved | length) > 0 then
                            ["", "**Resolved findings:**"] + [$resolved[] | "- [" + .sev + "] " + .desc]
                          else [] end) +
                          (if ($persistent | length) > 0 then
                            ["", "**Persistent findings:**"] + [$persistent[] | "- [" + .sev + "] " + .desc]
                          else [] end)
                        | map(raw) | join("\n") | nonul | rstrip_nl) catch "") as $diff
                    | "### Cycle \($nums[$i - 1]) → Cycle \($nums[$i])\n\n"
                      + (if $diff != "" then $diff else "(No findings to compare)" end) + "\n\n"
                  ] | join("")))}
              end
          end;

      # Artifacts: run.complete.data.artifacts, else those named by agent.complete events.
      def artifacts_section:
        if $rc == null then {t: ""}
        else ($rc | gcap((.data.artifacts // [])[]? | strings | "- `" + . + "`")) as $arts
          | (if $arts != "" then $arts
             else $all | gcap([ .[] | objects | select(.type == "agent.complete") | (.data.artifacts? // [])
                 | if type == "array" then .[] else . end | strings ] | unique | .[] | "- `" + . + "`") end) as $arts
          | {t: ("\n---\n\n## Artifacts\n\n" + (if $arts != "" then $arts else "(none recorded)" end) + "\n")}
        end;

    foreach (($raw | split("\n") | .[:-1][] | {line: .}), {cycles: true}, {artifacts: true}, {end: true}) as $item
      ({cur: "", t: "", ab: false};
       if .ab then .t = ""
       elif $item.line != null then line_step($item.line; .cur)
       elif $item.cycles then .cur as $c | cycle_section | .cur = $c | .ab = (.ab // false)
       elif $item.artifacts then .cur as $c | artifacts_section | .cur = $c | .ab = false
       else . + {t: ""} end;
       if $item.end then (if .ab then "archeflow-report: an event could not be read; report truncated\n" | halt_error(5) else empty end)
       else .t end)
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
  if [[ -n "$HAS_COMPLETE" ]]; then
    [[ -z "$COMPLETE_UNREADABLE" ]] || exit 5
    [[ -n "$MERGED" ]] && STATUS="merged"
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
  [[ -z "$CONFIG_UNREADABLE" ]] || exit 5
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

  echo "## Phases"
  echo ""
  render_body
}

if [[ -n "$OUTPUT" ]]; then
  generate_report > "$OUTPUT"
  echo "Report written to: $OUTPUT" >&2
else
  generate_report
fi
