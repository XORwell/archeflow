#!/usr/bin/env bash
# archeflow-yaml.sh — dependency-free YAML (subset) to JSON converter.
#
#   archeflow-yaml.sh <file.yaml|->          # typed JSON on stdout; exit 1 on unsupported input
#   archeflow-yaml.sh --text <file.yaml|->   # lenient: every scalar as its literal text
#
# The one YAML parser of ArcheFlow (bash, awk and jq only, the same result on
# every host). Scripts use it through the af_yaml_* helpers in
# archeflow-common.sh rather than calling it directly.
#
# --text is for looking up single values (af_yaml_get / af_yaml_list /
# af_yaml_map): numbers and booleans keep their spelling ("10.00" stays
# "10.00", on any jq version), null/~/empty stay null, and lines it cannot
# parse are skipped silently together with their more-indented continuation
# lines, so one odd line elsewhere in a config does not hide the other keys.
#
# Supported subset (what ArcheFlow's config, bundles, lenses and patterns use):
#   - block maps by indentation, block sequences ("- x"), sequences of maps
#     ("- key: v" with further keys indented under it)
#   - flow sequences of scalars ([a, "b", 3]) and empty {} / []
#   - scalars: "double" / 'single' quoted strings, integers, floats,
#     true/false/null/~, plain strings
#   - block scalars: | and > with the chomping indicators - and +
#   - full-line and trailing " # comments" (outside quotes)
# Not supported: anchors/aliases, tags, flow maps, nested flow collections,
# explicit indentation indicators (|2), multi-line quoted or plain scalars,
# multiple documents. Unsupported input exits non-zero (typed mode).
#
# Values are data: nothing read here is ever evaluated by a shell.

set -euo pipefail

text=0
if [[ "${1:-}" == "--text" ]]; then text=1; shift; fi
[[ $# -eq 1 && ( "$1" == "-" || -f "$1" ) ]] || { echo "usage: $0 [--text] <file.yaml|->" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 1; }

awk -v text="$text" '
function jstr(s) {
  gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s)
  gsub(/\n/, "\\n", s); gsub(/\r/, "\\r", s)
  return "\"" s "\""
}
function err(msg) {
  if (!text) printf "archeflow-yaml: %s at line %d\n", msg, NR > "/dev/stderr"
  bad = 1; skip = cur_n
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
  if (v == "{}") return "{}"
  if (v == "[]") return "[]"
  if (v ~ /^\[.*\]$/) return flow(substr(v, 2, length(v) - 2))
  if (v ~ /^[\[{|>&*!]/) { err("unsupported value: " v); return "null" }
  if (text) return jstr(v)
  if (v == "true" || v == "false") return v
  if (v ~ /^-?(0|[1-9][0-9]*)$/ || v ~ /^-?(0|[1-9][0-9]*)?\.[0-9]+$/) { sub(/^\./, "0.", v); sub(/^-\./, "-0.", v); return v }
  return jstr(v)
}
function flow(body,   n, parts, i, out) {
  if (body ~ /^[ \t]*$/) return "[]"
  if (body ~ /[\[\]{}]/) { err("nested flow collection"); return "[]" }
  n = split(body, parts, ",")
  out = "["
  for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") scalar(parts[i])
  return out "]"
}
function emit(path, val) { print "[" path "," val "]" }
function join_path(base, comp) { return base == "" ? comp : base "," comp }
# A value: a block scalar header ("|", ">-", ...) starts collecting the more
# indented lines that follow; anything else is a scalar or flow sequence.
function value(path, v, parent_ind) {
  if (v ~ /^[|>][-+]?$/) {
    blk = 1; blk_path = path; blk_style = substr(v, 1, 1); blk_chomp = substr(v, 2, 1)
    blk_parent = parent_ind; blk_ind = -1; bn = 0
    return
  }
  emit("[" path "]", scalar(v))
}
function finish_block(   i, out, nl, more, prev_more, started, trail) {
  blk = 0
  trail = 0
  while (bn > 0 && bl[bn] == "") { bn--; trail++ }
  out = ""; started = 0; nl = 0; prev_more = 0
  for (i = 1; i <= bn; i++) {
    if (blk_style == "|") { out = out (i > 1 ? "\n" : "") bl[i]; continue }
    if (bl[i] == "") { nl++; continue }
    more = (bl[i] ~ /^[ \t]/)
    if (!started) { out = out rep("\n", nl) bl[i]; started = 1 }
    else if (nl > 0) out = out ((more || prev_more) ? "\n" : "") rep("\n", nl) bl[i]
    else out = out ((more || prev_more) ? "\n" : " ") bl[i]
    nl = 0; prev_more = more
  }
  if (bn > 0 && blk_chomp != "-") out = out "\n"
  if (blk_chomp == "+") out = out rep("\n", trail)
  emit("[" blk_path "]", jstr(out))
}
function rep(s, k,   r) { r = ""; while (k-- > 0) r = r s; return r }
function handle_key(line, n,   key, rest) {
  # line has no leading spaces; n is its indent
  if (!match(line, /^("[^"]*"|\047[^\047]*\047|[^:]+):([ \t]|$)/)) { err("cannot parse line: " line); return }
  key = substr(line, 1, RLENGTH); rest = substr(line, RLENGTH + 1)
  sub(/:([ \t]|$)$/, "", key); sub(/^[ \t]+/, "", rest)
  if (key ~ /^".*"$/ || key ~ /^\047.*\047$/) key = substr(key, 2, length(key) - 2)
  if (rest == "") { pend_path = join_path(pth[top], jstr(key)); pend_ind = n; pending = 1 }
  else value(join_path(pth[top], jstr(key)), rest, n)
}
BEGIN { top = 0; ind[0] = -1; pth[0] = ""; kind[0] = "map"; pending = 0; bad = 0; blk = 0; skip = -1; root_ind = -1 }
{
  raw = $0
  sub(/\r$/, "", raw)
  if (blk) {
    # Block scalar content: blank lines and lines indented deeper than its key.
    if (raw ~ /^[ \t]*$/) { bl[++bn] = ""; next }
    match(raw, /^ */)
    if (RLENGTH > blk_parent && (blk_ind < 0 || RLENGTH >= blk_ind)) {
      if (blk_ind < 0) blk_ind = RLENGTH
      bl[++bn] = substr(raw, blk_ind + 1); next
    }
    finish_block()
  }
  if (raw ~ /^[ \t]*(#.*)?$/ || raw ~ /^---[ \t]*$/) next
  match(raw, /^ */); cur_n = RLENGTH
  if (skip >= 0) { if (cur_n > skip) next; skip = -1 }
  if (raw ~ /^ *\t/) { err("tab indentation"); next }
  line = strip_comment(raw)
  n = cur_n; line = substr(line, n + 1)
  isdash = (line ~ /^-([ \t]|$)/)
  if (root_ind < 0) root_ind = n

  while (top > 0 && ind[top] > n) top--
  if (pending) {
    if (isdash && n >= pend_ind) { top++; ind[top] = n; pth[top] = pend_path; kind[top] = "seq"; cnt[top] = 0 }
    else if (!isdash && n > pend_ind) { top++; ind[top] = n; pth[top] = pend_path; kind[top] = "map" }
    else emit("[" pend_path "]", "null")
    pending = 0
  }
  if (!isdash && kind[top] == "seq" && ind[top] == n) top--

  if (isdash) {
    if (kind[top] != "seq" || ind[top] != n) { err("unexpected list item"); next }
    item = join_path(pth[top], cnt[top]); cnt[top]++
    rest = substr(line, 2); sub(/^[ \t]+/, "", rest)
    if (rest ~ /^("[^"]*"|\047[^\047]*\047|[^:\[{"\047]+):([ \t]|$)/) {
      top++; ind[top] = n + 1 + (length(line) - 1 - length(rest)); pth[top] = item; kind[top] = "map"
      emit("[" item "]", "{}")
      handle_key(rest, ind[top])
    } else value(item, rest, n)
    next
  }
  # A key must sit exactly at the indentation of the map it belongs to.
  if (kind[top] != "map" || n != (top > 0 ? ind[top] : root_ind)) { err("unexpected indentation"); next }
  handle_key(line, n)
}
END {
  if (blk) finish_block()
  if (pending) emit("[" pend_path "]", "null")
  if (bad && !text) exit 1
}
' "$1" | if [[ "$text" == 1 ]]; then
  jq -cn 'reduce inputs as [$p, $v] ({}; try (if $v == {} and (getpath($p) | type) == "object" then . else setpath($p; $v) end) catch .)'
else
  jq -cn 'reduce inputs as [$p, $v] ({}; if $v == {} and (getpath($p) | type) == "object" then . else setpath($p; $v) end)'
fi
