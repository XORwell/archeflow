#!/usr/bin/env bash
# archeflow-yaml.sh — dependency-free YAML (subset) to JSON converter.
#
#   archeflow-yaml.sh <file.yaml>        # prints compact JSON on stdout
#
# Used as the fallback when neither mikefarah yq nor python3+PyYAML is
# available, so lens merging works on a stock runner (bash, awk, jq only).
#
# Supported subset (what ArcheFlow's lenses/patterns/bundles use):
#   - block maps by indentation, block sequences ("- x"), sequences of maps
#     ("- key: v" with further keys indented under it)
#   - flow sequences of scalars ([a, "b", 3]) and empty {} / []
#   - scalars: "double" / 'single' quoted strings, integers, floats,
#     true/false/null/~, plain strings
#   - full-line and trailing " # comments" (outside quotes)
# Not supported: anchors/aliases, multi-line (| >) strings, nested flow
# collections, multiple documents. Unsupported input exits non-zero.

set -euo pipefail

[[ $# -eq 1 && -f "$1" ]] || { echo "usage: $0 <file.yaml>" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 1; }

awk '
function jstr(s) {
  gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s)
  return "\"" s "\""
}
function strip_comment(s,   i, c, q, out) {
  q = ""; out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q == "") {
      if (c == "\"" || c == "\047") q = c
      else if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) break
    } else if (c == q) q = ""
    out = out c
  }
  sub(/[ \t]+$/, "", out)
  return out
}
function scalar(v) {
  sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
  if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2); gsub(/\\"/, "\"", v); return jstr(v) }
  if (v ~ /^\047.*\047$/) { v = substr(v, 2, length(v) - 2); gsub(/\047\047/, "\047", v); return jstr(v) }
  if (v == "" || v == "~" || v == "null") return "null"
  if (v == "true" || v == "false") return v
  if (v ~ /^-?(0|[1-9][0-9]*)$/ || v ~ /^-?(0|[1-9][0-9]*)?\.[0-9]+$/) { sub(/^\./, "0.", v); sub(/^-\./, "-0.", v); return v }
  if (v == "{}") return "{}"
  if (v == "[]") return "[]"
  if (v ~ /^\[.*\]$/) return flow(substr(v, 2, length(v) - 2))
  if (v ~ /^[\[{|>&*!]/) { printf "archeflow-yaml: unsupported value at line %d: %s\n", NR, v > "/dev/stderr"; bad = 1; return "null" }
  return jstr(v)
}
function flow(body,   n, parts, i, out) {
  if (body ~ /^[ \t]*$/) return "[]"
  if (body ~ /[\[\]{}]/) { printf "archeflow-yaml: nested flow collection at line %d\n", NR > "/dev/stderr"; bad = 1; return "[]" }
  n = split(body, parts, ",")
  out = "["
  for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") scalar(parts[i])
  return out "]"
}
function emit(path, val) { print "[" path "," val "]" }
function join_path(base, comp) { return base == "" ? comp : base "," comp }
function handle_key(line, n,   key, rest) {
  # line has no leading spaces; n is its indent
  if (!match(line, /^("[^"]*"|\047[^\047]*\047|[^:]+):([ \t]|$)/)) {
    printf "archeflow-yaml: cannot parse line %d: %s\n", NR, line > "/dev/stderr"; bad = 1; return
  }
  key = substr(line, 1, RLENGTH); rest = substr(line, RLENGTH + 1)
  sub(/:([ \t]|$)$/, "", key); sub(/^[ \t]+/, "", rest)
  if (key ~ /^".*"$/ || key ~ /^\047.*\047$/) key = substr(key, 2, length(key) - 2)
  if (rest == "") { pend_path = join_path(pth[top], jstr(key)); pend_ind = n; pending = 1 }
  else emit("[" join_path(pth[top], jstr(key)) "]", scalar(rest))
}
BEGIN { top = 0; ind[0] = -1; pth[0] = ""; kind[0] = "map"; pending = 0; bad = 0 }
{
  raw = $0
  sub(/\r$/, "", raw)
  if (raw ~ /^[ \t]*(#.*)?$/ || raw ~ /^---[ \t]*$/) next
  if (raw ~ /^\t/) { printf "archeflow-yaml: tab indentation at line %d\n", NR > "/dev/stderr"; bad = 1; next }
  line = strip_comment(raw)
  match(line, /^ */); n = RLENGTH; line = substr(line, n + 1)
  isdash = (line ~ /^-([ \t]|$)/)

  while (top > 0 && ind[top] > n) top--
  if (pending) {
    if (isdash && n >= pend_ind) { top++; ind[top] = n; pth[top] = pend_path; kind[top] = "seq"; cnt[top] = 0 }
    else if (!isdash && n > pend_ind) { top++; ind[top] = n; pth[top] = pend_path; kind[top] = "map" }
    else emit("[" pend_path "]", "null")
    pending = 0
  }
  if (!isdash && kind[top] == "seq" && ind[top] == n) top--

  if (isdash) {
    if (kind[top] != "seq" || ind[top] != n) { printf "archeflow-yaml: unexpected list item at line %d\n", NR > "/dev/stderr"; bad = 1; next }
    item = join_path(pth[top], cnt[top]); cnt[top]++
    rest = substr(line, 2); sub(/^[ \t]+/, "", rest)
    if (rest ~ /^("[^"]*"|\047[^\047]*\047|[^:\[{"\047]+):([ \t]|$)/) {
      top++; ind[top] = n + 1 + (length(line) - 1 - length(rest)); pth[top] = item; kind[top] = "map"
      emit("[" item "]", "{}")
      handle_key(rest, ind[top])
    } else emit("[" item "]", scalar(rest))
    next
  }
  handle_key(line, n)
}
END {
  if (pending) emit("[" pend_path "]", "null")
  if (bad) exit 1
}
' "$1" | jq -cn 'reduce inputs as [$p, $v] ({}; if $v == {} and (getpath($p) | type) == "object" then . else setpath($p; $v) end)'
