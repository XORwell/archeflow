#!/usr/bin/env bash
# archeflow-langfuse-backfill.sh — Replay a run's JSONL event log into Langfuse.
#
# Reads .archeflow/events/<run_id>.jsonl line-by-line and pipes each event
# through archeflow-langfuse.sh. Useful for backfilling historical runs after
# enabling Langfuse, or re-ingesting after a Langfuse data wipe.
#
# Usage:
#   archeflow-langfuse-backfill.sh <run_id>
#   archeflow-langfuse-backfill.sh --all        # replay every .jsonl in events dir
#
# Exits 0 even if individual events fail (the bridge itself is fail-silent).
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${LIB_DIR}/archeflow-langfuse.sh"
# shellcheck source=lib/archeflow-common.sh
source "${LIB_DIR}/archeflow-common.sh"
EVENTS_DIR=".archeflow/events"

if [[ ! -x "$BRIDGE" ]]; then
    echo "Error: archeflow-langfuse.sh not found or not executable at $BRIDGE" >&2
    exit 1
fi

replay_file() {
    local file="$1"
    local rid count=0
    rid=$(basename "$file" .jsonl)
    echo "[backfill] replaying $rid ($(wc -l <"$file") events)"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        printf '%s\n' "$line" | "$BRIDGE" || true
        count=$((count + 1))
        # gentle pacing so we don't hammer Langfuse on a big backlog
        (( count % 25 == 0 )) && sleep 0.1 || true
    done < "$file"
    echo "[backfill] $rid: sent $count events"
}

usage() {
    echo "Usage: $0 <run_id>     (replay .archeflow/events/<run_id>.jsonl)" >&2
    echo "       $0 --all        (replay every *.jsonl in $EVENTS_DIR)" >&2
    exit 1
}

[[ $# -ge 1 ]] || usage

if [[ "$1" == "--all" ]]; then
    shopt -s nullglob
    files=("$EVENTS_DIR"/*.jsonl)
    shopt -u nullglob
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "No event files in $EVENTS_DIR" >&2
        exit 0
    fi
    for f in "${files[@]}"; do
        replay_file "$f"
    done
else
    RUN_ID="$1"
    af_require_run_id "$RUN_ID"
    FILE="${EVENTS_DIR}/${RUN_ID}.jsonl"
    [[ -f "$FILE" ]] || { echo "Error: $FILE not found" >&2; exit 1; }
    replay_file "$FILE"
fi
