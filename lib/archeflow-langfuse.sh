#!/usr/bin/env bash
# archeflow-langfuse.sh — Non-blocking, fail-silent bridge from ArcheFlow events to Langfuse.
#
# Reads ONE ArcheFlow event JSON object from stdin and forwards it to the Langfuse
# ingestion API as the appropriate observation type (trace / span / event / generation).
#
# Contract:
#   - Config comes from exactly ONE source (all four LANGFUSE_* values together):
#       1. the environment, if LANGFUSE_ENABLED=true is set there; otherwise
#       2. a user-level langfuse.env file, first found of:
#            ${XDG_CONFIG_HOME:-~/.config}/archeflow/langfuse.env
#            ~/.archeflow/langfuse.env
#     Nothing inside the repository is ever read: a project-local
#     .archeflow/langfuse.env could be supplied by the repository (committed,
#     reached through a symlinked .archeflow/, or as a case variant such as
#     LANGFUSE.env on a case-insensitive filesystem) and would send every run
#     event to a host the repository chose. Values are parsed as data, never
#     executed.
#   - The host must be https://, or http:// on a loopback address.
#   - If config is missing or LANGFUSE_ENABLED != "true", exit 0 silently.
#   - curl failures are logged to <config-dir>/langfuse.errors.log but never propagate.
#   - Unknown event types log a warning to stderr and exit 0.
#   - IDs are deterministic: trace.id = run_id; sub-observation id = run_id-<seq>.
#     Deterministic IDs let us idempotently *-update an observation later.
#
# Usage (normally invoked by archeflow-event.sh in the background):
#   echo "$EVENT_JSON" | archeflow-langfuse.sh
#
# Dependencies: bash, jq, curl (same as the rest of archeflow).
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -uo pipefail  # NB: no -e — we must never abort mid-flight and break orchestration.

# Snapshot and clear inherited LANGFUSE_* values, so a config file can never
# combine the user's exported keys with a host it chose (key exfiltration).
_ENV_ENABLED="${LANGFUSE_ENABLED:-}"
_ENV_HOST="${LANGFUSE_HOST:-}"
_ENV_PK="${LANGFUSE_PUBLIC_KEY:-}"
_ENV_SK="${LANGFUSE_SECRET_KEY:-}"
unset LANGFUSE_ENABLED LANGFUSE_HOST LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY

# Locate langfuse.env in the user's own configuration only. The working
# directory (and so the repository) is never consulted.
_find_langfuse_dir() {
    local d
    for d in "${XDG_CONFIG_HOME:-$HOME/.config}/archeflow" "$HOME/.archeflow"; do
        [[ -f "$d/langfuse.env" ]] && { printf '%s\n' "$d"; return 0; }
    done
    return 1
}

AF_DIR=""
CONFIG=""
ERRLOG=""

_log_err() {
    [[ -n "$ERRLOG" ]] || return 0
    [[ -L "$ERRLOG" ]] && return 0   # never append through a symlink
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$ERRLOG" 2>/dev/null || true
}

# Parse langfuse.env as KEY=VALUE data instead of sourcing it. Only the four
# LANGFUSE_* keys are accepted; optional "export ", surrounding quotes and
# trailing " # comments" (on unquoted values) are handled.
_load_config() {
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(LANGFUSE_[A-Z_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[2]}"
        val="${BASH_REMATCH[3]}"
        if [[ "$val" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ || "$val" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
            val="${BASH_REMATCH[1]}"
        else
            val="${val%%[[:space:]]#*}"
            val="${val%"${val##*[![:space:]]}"}"
        fi
        case "$key" in
            LANGFUSE_HOST|LANGFUSE_PUBLIC_KEY|LANGFUSE_SECRET_KEY|LANGFUSE_ENABLED)
                printf -v "$key" '%s' "$val" ;;
        esac
    done < "$CONFIG"
}

# ---- load config (one source) ----------------------------------------------
if [[ "$_ENV_ENABLED" == "true" ]]; then
    LANGFUSE_ENABLED="$_ENV_ENABLED"
    LANGFUSE_HOST="$_ENV_HOST"
    LANGFUSE_PUBLIC_KEY="$_ENV_PK"
    LANGFUSE_SECRET_KEY="$_ENV_SK"
    AF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/archeflow"
    [[ -d "$AF_DIR" ]] && ERRLOG="$AF_DIR/langfuse.errors.log"
else
    AF_DIR="$(_find_langfuse_dir || true)"
    [[ -n "$AF_DIR" ]] || exit 0
    CONFIG="$AF_DIR/langfuse.env"
    ERRLOG="$AF_DIR/langfuse.errors.log"
    _load_config 2>/dev/null || exit 0
fi
unset _ENV_ENABLED _ENV_HOST _ENV_PK _ENV_SK

[[ "${LANGFUSE_ENABLED:-false}" == "true" ]] || exit 0
[[ -n "${LANGFUSE_HOST:-}" && -n "${LANGFUSE_PUBLIC_KEY:-}" && -n "${LANGFUSE_SECRET_KEY:-}" ]] || {
    _log_err "config incomplete (host/public/secret missing)"
    exit 0
}

# Keys travel as Basic auth: only over TLS, or in clear text to this machine.
_host_allowed() {
    local h="$1" rest hostport host
    [[ "$h" =~ ^https?://[^[:space:]]+$ ]] || return 1
    rest="${h#*://}"
    hostport="${rest%%/*}"
    [[ "$hostport" == *@* ]] && return 1          # no userinfo in the URL
    [[ "$h" == https://* ]] && return 0
    if [[ "$hostport" == \[* ]]; then host="${hostport%%]*}]"; else host="${hostport%%:*}"; fi
    [[ "$host" == localhost || "$host" == "[::1]" ]] && return 0
    [[ "$host" =~ ^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && return 0
    return 1
}
_host_allowed "$LANGFUSE_HOST" || {
    _log_err "refusing LANGFUSE_HOST '${LANGFUSE_HOST}': use https://, or http:// on localhost/127.0.0.1/[::1]"
    exit 0
}

# ---- read event -------------------------------------------------------------
EVENT=$(cat)
[[ -n "$EVENT" ]] || exit 0
echo "$EVENT" | jq empty 2>/dev/null || { _log_err "stdin not valid JSON"; exit 0; }

# Extract common fields
RUN_ID=$(jq -r '.run_id // ""' <<<"$EVENT")
SEQ=$(jq -r '.seq // ""' <<<"$EVENT")
TS=$(jq -r '.ts // ""' <<<"$EVENT")
TYPE=$(jq -r '.type // ""' <<<"$EVENT")
PHASE=$(jq -r '.phase // ""' <<<"$EVENT")
AGENT=$(jq -r '.agent // ""' <<<"$EVENT")
DATA=$(jq -c '.data // {}' <<<"$EVENT")

[[ -n "$RUN_ID" && -n "$TYPE" ]] || { _log_err "event missing run_id or type"; exit 0; }

# ---- ID derivation ----------------------------------------------------------
# Trace id = run_id (deterministic).
# Phase span id = run_id--phase-<phase>  (one span per phase, updatable).
# Agent span id = run_id--agent-<phase>-<agent>-<seq>.
# Event id     = run_id-<seq>.
# Generation id= run_id--gen-<seq>.
TRACE_ID="$RUN_ID"
PHASE_SPAN_ID="${RUN_ID}--phase-${PHASE}"
AGENT_SPAN_ID="${RUN_ID}--agent-${PHASE}-${AGENT}-${SEQ}"
EVENT_ID="${RUN_ID}-${SEQ}"
GEN_ID="${RUN_ID}--gen-${SEQ}"

# Project tag (from CWD basename)
PROJECT=$(basename "$PWD")

# UUID for the *envelope* id (each ingestion batch item needs a unique id;
# the body.id is what carries our deterministic observation id).
# /proc is Linux-only; uuidgen covers macOS/BSD. The last resort is still
# unique per process (the former jq fallback produced a constant string, so
# every envelope on macOS shared one id).
ENVELOPE_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' \
    || echo "${RUN_ID}-${SEQ}-$$-${RANDOM}${RANDOM}")
[[ -n "$ENVELOPE_ID" ]] || ENVELOPE_ID="${RUN_ID}-${SEQ}-$$-${RANDOM}${RANDOM}"

# ---- build per-type body ----------------------------------------------------
build_item() {
    local item_type="$1"
    local body="$2"
    jq -cn \
        --arg id "$ENVELOPE_ID" \
        --arg ts "$TS" \
        --arg type "$item_type" \
        --argjson body "$body" \
        '{id:$id, timestamp:$ts, type:$type, body:$body}'
}

ITEM=""
PAYLOAD=""  # never inherit a PAYLOAD from the caller's environment
case "$TYPE" in
    run.start)
        # Create root trace AND the first phase span (plan) so downstream
        # parentObservationId references resolve. Without this the plan phase
        # would be implicitly created by its span-update, resulting in an
        # empty-name ghost span.
        WORKFLOW=$(jq -r '.workflow // ""' <<<"$DATA")
        DOMAIN=$(jq -r '.domain // ""' <<<"$DATA")
        # (task text travels in the trace input via $DATA)
        TRACE_BODY=$(jq -cn \
            --arg id "$TRACE_ID" \
            --arg name "run:${RUN_ID}" \
            --arg ts "$TS" \
            --arg project "$PROJECT" \
            --arg workflow "$WORKFLOW" \
            --arg domain "$DOMAIN" \
            --argjson input "$DATA" \
            '{
                id:$id,
                timestamp:$ts,
                name:$name,
                input:$input,
                metadata:{project:$project, workflow:$workflow, domain:$domain},
                tags:([$project, $workflow, $domain] | map(select(length>0)))
            }')
        FIRST_PHASE="${PHASE:-plan}"
        PHASE_BODY=$(jq -cn \
            --arg id "${RUN_ID}--phase-${FIRST_PHASE}" \
            --arg traceId "$TRACE_ID" \
            --arg name "phase:${FIRST_PHASE}" \
            --arg phase "$FIRST_PHASE" \
            --arg ts "$TS" \
            --arg project "$PROJECT" \
            '{id:$id, traceId:$traceId, name:$name, startTime:$ts, metadata:{project:$project, phase:$phase}}')
        A=$(build_item "trace-create" "$TRACE_BODY")
        ENVELOPE_ID2="${ENVELOPE_ID}-b"
        B=$(jq -cn \
            --arg id "$ENVELOPE_ID2" \
            --arg ts "$TS" \
            --argjson body "$PHASE_BODY" \
            '{id:$id, timestamp:$ts, type:"span-create", body:$body}')
        PAYLOAD=$(jq -cn --argjson a "$A" --argjson b "$B" '{batch:[$a,$b], metadata:{}}')
        ;;

    run.complete)
        BODY=$(jq -cn \
            --arg id "$TRACE_ID" \
            --arg ts "$TS" \
            --argjson output "$DATA" \
            '{id:$id, output:$output, metadata:{ended_at:$ts}}')
        ITEM=$(build_item "trace-create" "$BODY")  # trace-create is upsert-like
        ;;

    phase.transition)
        # Close the old phase span (if any) and open the new one.
        # We emit two items in one batch: update old + create new.
        FROM=$(jq -r '.from // ""' <<<"$DATA")
        TO=$(jq -r '.to // ""' <<<"$DATA")
        OLD_ID="${RUN_ID}--phase-${FROM}"
        NEW_ID="${RUN_ID}--phase-${TO}"

        UPDATE_BODY=""
        if [[ -n "$FROM" ]]; then
            UPDATE_BODY=$(jq -cn \
                --arg id "$OLD_ID" \
                --arg traceId "$TRACE_ID" \
                --arg ts "$TS" \
                '{id:$id, traceId:$traceId, endTime:$ts}')
        fi
        CREATE_BODY=$(jq -cn \
            --arg id "$NEW_ID" \
            --arg traceId "$TRACE_ID" \
            --arg name "phase:${TO}" \
            --arg phase "$TO" \
            --arg ts "$TS" \
            --arg project "$PROJECT" \
            '{id:$id, traceId:$traceId, name:$name, startTime:$ts, metadata:{project:$project, phase:$phase}}')

        if [[ -n "$UPDATE_BODY" ]]; then
            U=$(build_item "span-update" "$UPDATE_BODY")
            # slightly different envelope id for the second item
            ENVELOPE_ID2="${ENVELOPE_ID}-b"
            C=$(jq -cn \
                --arg id "$ENVELOPE_ID2" \
                --arg ts "$TS" \
                --argjson body "$CREATE_BODY" \
                '{id:$id, timestamp:$ts, type:"span-create", body:$body}')
            # Wrap both items directly; skip the single-ITEM path.
            BATCH=$(jq -cn --argjson a "$U" --argjson b "$C" '{batch:[$a,$b], metadata:{}}')
            PAYLOAD="$BATCH"
        else
            ITEM=$(build_item "span-create" "$CREATE_BODY")
        fi
        ;;

    agent.start)
        ARCH=$(jq -r '.archetype // ""' <<<"$DATA")
        BODY=$(jq -cn \
            --arg id "$AGENT_SPAN_ID" \
            --arg traceId "$TRACE_ID" \
            --arg parentObservationId "$PHASE_SPAN_ID" \
            --arg name "agent:${AGENT:-unknown}" \
            --arg ts "$TS" \
            --arg project "$PROJECT" \
            --arg archetype "$ARCH" \
            --arg phase "$PHASE" \
            --argjson input "$DATA" \
            '{
                id:$id,
                traceId:$traceId,
                parentObservationId:$parentObservationId,
                name:$name,
                startTime:$ts,
                input:$input,
                metadata:{project:$project, archetype:$archetype, phase:$phase}
            }')
        ITEM=$(build_item "span-create" "$BODY")
        ;;

    agent.complete)
        # To close the right span we need the seq of the matching agent.start.
        # CONTRACT: orchestrators should pass {"start_seq": <N>} in data where N
        # is the seq of the agent.start event. If missing, we fall back to this
        # event's own seq — which in Langfuse creates a *new* empty span rather
        # than closing the start span (ghost observation). That's harmless but
        # noisy; include start_seq in production emitters.
        START_SEQ=$(jq -r '.start_seq // empty' <<<"$DATA")
        CLOSE_ID="${RUN_ID}--agent-${PHASE}-${AGENT}-${START_SEQ:-$SEQ}"
        BODY=$(jq -cn \
            --arg id "$CLOSE_ID" \
            --arg traceId "$TRACE_ID" \
            --arg ts "$TS" \
            --argjson output "$DATA" \
            '{id:$id, traceId:$traceId, endTime:$ts, output:$output}')
        ITEM=$(build_item "span-update" "$BODY")
        ;;

    decision.point)
        BODY=$(jq -cn \
            --arg id "$EVENT_ID" \
            --arg traceId "$TRACE_ID" \
            --arg parentObservationId "$PHASE_SPAN_ID" \
            --arg name "decision:${AGENT:-_}" \
            --arg ts "$TS" \
            --arg project "$PROJECT" \
            --argjson input "$DATA" \
            '{
                id:$id, traceId:$traceId, parentObservationId:$parentObservationId,
                name:$name, startTime:$ts, input:$input,
                metadata:{project:$project, kind:"decision"}
            }')
        ITEM=$(build_item "event-create" "$BODY")
        ;;

    finding.raised)
        BODY=$(jq -cn \
            --arg id "$EVENT_ID" \
            --arg traceId "$TRACE_ID" \
            --arg parentObservationId "$PHASE_SPAN_ID" \
            --arg name "finding:${AGENT:-_}" \
            --arg ts "$TS" \
            --arg project "$PROJECT" \
            --argjson input "$DATA" \
            '{
                id:$id, traceId:$traceId, parentObservationId:$parentObservationId,
                name:$name, startTime:$ts, input:$input, level:"WARNING",
                metadata:{project:$project, kind:"finding"}
            }')
        ITEM=$(build_item "event-create" "$BODY")
        ;;

    fix.applied)
        BODY=$(jq -cn \
            --arg id "$EVENT_ID" \
            --arg traceId "$TRACE_ID" \
            --arg parentObservationId "$PHASE_SPAN_ID" \
            --arg name "fix:${AGENT:-_}" \
            --arg ts "$TS" \
            --arg project "$PROJECT" \
            --argjson input "$DATA" \
            '{
                id:$id, traceId:$traceId, parentObservationId:$parentObservationId,
                name:$name, startTime:$ts, input:$input,
                metadata:{project:$project, kind:"fix"}
            }')
        ITEM=$(build_item "event-create" "$BODY")
        ;;

    cost.recorded|token.recorded|generation.recorded|llm.call)
        MODEL=$(jq -r '.model // ""' <<<"$DATA")
        # Token counts: JSON numbers only (anything else becomes 0).
        IN_TOK=$(jq -r '((.input_tokens // .prompt_tokens // .tokens) | numbers) // 0' <<<"$DATA")
        OUT_TOK=$(jq -r '((.output_tokens // .completion_tokens) | numbers) // 0' <<<"$DATA")
        TOTAL_TOK=$(jq -r '(.total_tokens | numbers) // 0' <<<"$DATA")
        ARCH=$(jq -r '.archetype // ""' <<<"$DATA")
        BODY=$(jq -cn \
            --arg id "$GEN_ID" \
            --arg traceId "$TRACE_ID" \
            --arg parentObservationId "$PHASE_SPAN_ID" \
            --arg name "gen:${AGENT:-_}" \
            --arg ts "$TS" \
            --arg model "$MODEL" \
            --argjson inTok "${IN_TOK:-0}" \
            --argjson outTok "${OUT_TOK:-0}" \
            --argjson totalTok "${TOTAL_TOK:-0}" \
            --arg project "$PROJECT" \
            --arg archetype "$ARCH" \
            --arg phase "$PHASE" \
            --argjson input "$DATA" \
            '{
                id:$id, traceId:$traceId, parentObservationId:$parentObservationId,
                name:$name, startTime:$ts, endTime:$ts, model:$model, input:$input,
                usage:{input:$inTok, output:$outTok, total:$totalTok, unit:"TOKENS"},
                metadata:{project:$project, archetype:$archetype, phase:$phase}
            }')
        ITEM=$(build_item "generation-create" "$BODY")
        ;;

    *)
        echo "[langfuse] unknown event type: $TYPE" >&2
        exit 0
        ;;
esac

# ---- assemble payload -------------------------------------------------------
if [[ -z "${PAYLOAD:-}" ]]; then
    [[ -n "$ITEM" ]] || exit 0
    PAYLOAD=$(jq -cn --argjson i "$ITEM" '{batch:[$i], metadata:{}}')
fi

# ---- POST to Langfuse -------------------------------------------------------
AUTH=$(printf '%s:%s' "$LANGFUSE_PUBLIC_KEY" "$LANGFUSE_SECRET_KEY" | base64 -w0 2>/dev/null \
    || printf '%s:%s' "$LANGFUSE_PUBLIC_KEY" "$LANGFUSE_SECRET_KEY" | base64 | tr -d '\n')

# Private temp files (mktemp, mode 0600): the response body, and the auth
# header — passed via "-H @file" so the secret never appears in argv / `ps`.
RESP_FILE=$(mktemp "${TMPDIR:-/tmp}/archeflow-langfuse.XXXXXX" 2>/dev/null) || { _log_err "mktemp failed"; exit 0; }
HDR_FILE=$(mktemp "${TMPDIR:-/tmp}/archeflow-langfuse-hdr.XXXXXX" 2>/dev/null) || { rm -f "$RESP_FILE"; _log_err "mktemp failed"; exit 0; }
trap 'rm -f "$RESP_FILE" "$HDR_FILE" 2>/dev/null' EXIT
printf 'Authorization: Basic %s\nContent-Type: application/json\n' "$AUTH" > "$HDR_FILE"

HTTP_STATUS=$(curl -sS -o "$RESP_FILE" -w '%{http_code}' \
    --connect-timeout 2 --max-time 3 \
    -X POST "${LANGFUSE_HOST%/}/api/public/ingestion" \
    -H @"$HDR_FILE" \
    --data-binary "$PAYLOAD" 2>/dev/null) || HTTP_STATUS="000"

if [[ ! "$HTTP_STATUS" =~ ^2[0-9][0-9]$ && "$HTTP_STATUS" != "207" ]]; then
    BODY_SNIP=$(head -c 400 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')
    _log_err "POST ${LANGFUSE_HOST%/}/api/public/ingestion type=${TYPE} seq=${SEQ} http=${HTTP_STATUS} body=${BODY_SNIP}"
fi

exit 0
