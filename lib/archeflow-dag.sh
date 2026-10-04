#!/usr/bin/env bash
# archeflow-dag.sh — Render an ASCII DAG from ArcheFlow JSONL events.
#
# Usage: ./lib/archeflow-dag.sh <events.jsonl> [--color] [--no-color]
#
# Reads a JSONL event file and renders the causal DAG as ASCII art.
# Each event shows: #seq  description (phase) [metadata]
# Tree drawing uses Unicode box-drawing characters for branches.
#
# The rendering uses a "logical grouping" strategy: phase transitions and
# structural events appear as top-level siblings under root, with agents
# and sub-events nested beneath their phase section. This gives a readable
# timeline view while preserving DAG relationships.
#
# Requires: jq
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <events.jsonl> [--color] [--no-color]" >&2
  exit 1
fi

EVENT_FILE="$1"
shift

if ! command -v jq &> /dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

if [[ ! -f "$EVENT_FILE" ]]; then
  echo "Error: Event file not found: $EVENT_FILE" >&2
  exit 1
fi

# Color support: auto-detect terminal, allow override
USE_COLOR=auto
for arg in "$@"; do
  case "$arg" in
    --color) USE_COLOR=yes ;;
    --no-color) USE_COLOR=no ;;
  esac
done

if [[ "$USE_COLOR" == "auto" ]]; then
  if [[ -t 1 ]]; then
    USE_COLOR=yes
  else
    USE_COLOR=no
  fi
fi

# The whole DAG is built and rendered in a single jq pass (O(n log n) in the
# number of events). Earlier versions parsed the events into bash arrays and
# rendered recursively with a subshell per node, which took seconds for a
# thousand events.
#
# Event files may come from the repository, so only well-formed events are
# rendered: seq and parents must be non-negative integers. Strings are
# stripped of newlines (and the unit separator, for compatibility with the
# earlier line format) so one event is always one line. Labels are printed
# literally: backslash sequences in event data are not interpreted.
jq -rs --arg color "$USE_COLOR" '
  def mklabel:
    if .type == "run.start" then "run.start"
    elif .type == "agent.complete" then
      (.data.archetype // .agent // "unknown") + " (" + .phase + ")" +
      (if (.data.tokens // 0) > 0 then " [" + (.data.tokens | tostring) + " tok]" else "" end)
    elif .type == "decision.point" then
      (.data.archetype // .agent // "?") + " → " + (.data.decision // "?") +
      " (conf " + ((.data.confidence // 0) | tostring) + ")"
    elif .type == "decision" then
      "decision: " + (.data.what // "unknown") + " → " + (.data.chosen // "unknown")
    elif .type == "phase.transition" then
      "─── " + (.data.from // "?") + " → " + (.data.to // "?") + " ───"
    elif .type == "review.verdict" then
      (.data.archetype // .agent // "unknown") + " (" + .phase + ") → " +
      ((.data.verdict // "unknown") | ascii_upcase | gsub("_"; " "))
    elif .type == "fix.applied" then
      "fix (" + (.data.source // "unknown") + "): " + (.data.finding // "unknown")
    elif .type == "agent.start" then
      (.data.archetype // .agent // "unknown") + " started (" + .phase + ")"
    elif .type == "cycle.boundary" then
      "cycle " + ((.data.cycle // 0) | tostring) + "/" + ((.data.max_cycles // 0) | tostring) +
      " → " + ((.data.decision // .data.next_action // "continue") | tostring)
    elif .type == "wiggum.break" then
      "wiggum break (" + ((.data.type // "?") | tostring) + ")"
    elif .type == "run.merged" then
      "merged into " + ((.data.base // "base") | tostring)
    elif .type == "shadow.detected" then
      "shadow: " + (.data.archetype // "unknown") + " — " + (.data.shadow // "unknown")
    elif .type == "run.complete" then
      "run.complete [" + ((.data.agents_total // .data.agents // 0) | tostring) +
      " agents, " + ((.data.fixes_total // .data.fixes // 0) | tostring) + " fixes]"
    else .type
    end;
  def clean: tostring
    | if contains("\n") or contains("\r") or contains("\u001f") or contains("\u0000")
      then gsub("[\u001f\n\r]"; " ") | gsub("\u0000"; "") else . end;
  def isint: type == "number" and . >= 0 and . == floor and . < 1e15;

  # ANSI colors (empty without --color).
  (if $color == "yes" then
     {reset: "\u001b[0m", seq: "\u001b[1;37m", trans: "\u001b[0;36m",
      decision: "\u001b[1;33m", verdict: "\u001b[1;31m",
      plan: "\u001b[1;34m", do: "\u001b[1;32m", check: "\u001b[1;33m", act: "\u001b[1;35m"}
   else {reset: "", seq: "", trans: "", decision: "", verdict: "",
         plan: "", do: "", check: "", act: ""} end) as $C

  # seq (canonical decimal string) -> event; a later event with the same seq wins.
  | (reduce (.[] | select(type == "object" and (.seq | isint))
       | {s: (.seq | tostring),
          t: (.type // "" | clean),
          ph: (.phase // "" | clean),
          par: ((.parent // []) | if type == "array" then . else [] end | map(select(isint) | tostring)),
          l: ((try mklabel catch (.type // "?")) | clean)}
       | select(.s | test("^[0-9]+$"))) as $r
       ({}; .[$r.s] = $r)) as $ev
  | ([$ev[] | .s | tonumber] | sort | map(tostring)) as $order
  | if ($order | length) == 0 then "No events found.\n" | halt_error(1) else . end

  # The tree root is the first run.start (else the lowest seq). Structural events
  # (phase.transition, cycle.boundary, run.complete) are promoted to be direct
  # children of the root, creating a flat timeline backbone. Other events without
  # a parent, or whose parent is not in the file (or comes later), also hang under
  # the root, so no event is dropped. All other events use their first parent.
  | ([$order[] | select($ev[.].t == "run.start")] | first // $order[0]) as $root
  | ([$order[] | select(. != $root) | $ev[.] as $e | ($e.par[0]) as $fp
      | {n: tonumber,
         p: (if ($e.par | length) == 0
                or ($e.t == "phase.transition" or $e.t == "cycle.boundary" or $e.t == "run.complete")
                or ($ev[$fp] == null or $ev[$fp].t == "")
                or (($fp | tonumber) >= ($e.s | tonumber))
             then $root else $fp end)}]
     | group_by(.p) | map({key: .[0].p, value: (map(.n) | sort | map(tostring))}) | from_entries) as $kids

  | def render($s; $prefix; $last):
      $ev[$s] as $e
      | (if $e.l == "" then "unknown" else $e.l end) as $label
      | (if $e.t == "phase.transition" then $C.trans
         elif $e.t == "decision" or $e.t == "decision.point" then $C.decision
         elif $e.t == "review.verdict" then $C.verdict
         elif ($e.ph == "plan" or $e.ph == "do" or $e.ph == "check" or $e.ph == "act") then $C[$e.ph]
         else $C.reset end) as $lc
      | (if $s == $root then
           $C.seq + "#" + $s + $C.reset + "  " + $lc + $label + $C.reset
         else
           $prefix + (if $last then "└── " else "├── " end)
           + $C.seq + "#" + $s + (" " * ([3 - ($s | length), 0] | max)) + $C.reset
           + $lc + $label + $C.reset
         end),
        (($kids[$s] // []) as $k | ($k | length) as $n
         | range(0; $n) as $i
         | render($k[$i];
                  (if $s == $root then "" elif $last then $prefix + "    " else $prefix + "│   " end);
                  $i == $n - 1));
    render($root; ""; true)
' "$EVENT_FILE"
