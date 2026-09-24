#!/usr/bin/env bash
# archeflow-ollama.sh — Call a local Ollama API for ArcheFlow archetype turns (no cloud tokens).
#
# Requires: curl, jq. Ollama daemon running (ollama serve).
# Env:
#   ARCHEFLOW_OLLAMA_BASE_URL — full base URL (wins over OLLAMA_HOST; set from config models.ollama.base_url)
#                               (legacy spelling ARCHFLOW_OLLAMA_BASE_URL is still honored as a fallback)
#   OLLAMA_HOST — host:port or http(s)://host:port (default 127.0.0.1:11434; Ollama CLI convention)
#   ARCHEFLOW_OLLAMA_ALLOW_REMOTE=1 — permit a non-loopback host. Without it, only
#                               localhost / 127.x / [::1] / 0.0.0.0 are contacted: the
#                               base URL usually comes from .archeflow/config.yaml, which
#                               a repository can supply, and every prompt (task text,
#                               code, diffs) is sent to that host.
#
# Usage:
#   archeflow-ollama.sh health
#   archeflow-ollama.sh tags
#   archeflow-ollama.sh chat <model> [--system-file FILE]   # user prompt on stdin
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

usage() {
  sed -n '1,13p' "$0" | tail -n +2
  echo "Commands:"
  echo "  health              GET /api/tags (exit 0 if Ollama responds)"
  echo "  tags                List model names (one per line)"
  echo "  chat <model> [--system-file PATH]   Read user message from stdin; print assistant text"
}

ollama_base_url() {
  local h="${ARCHEFLOW_OLLAMA_BASE_URL:-${ARCHFLOW_OLLAMA_BASE_URL:-}}"
  if [[ -z "$h" ]]; then
    h="${OLLAMA_HOST:-127.0.0.1:11434}"
  fi
  if [[ "$h" == *://* && "$h" != http://* && "$h" != https://* ]]; then
    echo "archeflow-ollama: invalid Ollama base URL: '${h}' (http or https only)" >&2
    return 1
  fi
  if [[ "$h" != http://* && "$h" != https://* ]]; then
    h="http://${h}"
  fi
  # Strip trailing slash
  h="${h%/}"
  local url_re='^https?://[]A-Za-z0-9._:[-]+(/[A-Za-z0-9._~/-]*)?$'
  if [[ ! "$h" =~ $url_re ]]; then
    echo "archeflow-ollama: invalid Ollama base URL: '${h}'" >&2
    return 1
  fi
  local hostport="${h#*://}" host
  hostport="${hostport%%/*}"
  if [[ "$hostport" == \[* ]]; then host="${hostport%%]*}]"; else host="${hostport%%:*}"; fi
  if ! _is_loopback "$host" && [[ "${ARCHEFLOW_OLLAMA_ALLOW_REMOTE:-}" != "1" ]]; then
    echo "archeflow-ollama: refusing non-local Ollama host '${host}' (prompts and code would leave this machine)." >&2
    echo "archeflow-ollama: set ARCHEFLOW_OLLAMA_ALLOW_REMOTE=1 in your own shell to allow it." >&2
    return 1
  fi
  echo "$h"
}

_is_loopback() {
  local host="$1"
  [[ "$host" == localhost || "$host" == "[::1]" || "$host" == 0.0.0.0 ]] && return 0
  [[ "$host" =~ ^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

cmd_health() {
  local base url
  base="$(ollama_base_url)" || return 1
  url="${base}/api/tags"
  if ! curl -fsS --max-time 5 "$url" >/dev/null; then
    echo "archeflow-ollama: cannot reach ${url} (is Ollama running?)" >&2
    return 1
  fi
}

cmd_tags() {
  local base json
  base="$(ollama_base_url)" || return 1
  json="$(curl -fsS --max-time 15 "${base}/api/tags")"
  echo "$json" | jq -r '.models[]?.name // empty'
}

cmd_chat() {
  local model system="" user_msg payload base resp err
  model="${1:-}"
  shift || true
  if [[ -z "$model" ]]; then
    echo "archeflow-ollama: chat requires a model name" >&2
    usage >&2
    return 1
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --system-file)
        if [[ $# -lt 2 || -z "$2" ]]; then
          echo "archeflow-ollama: --system-file requires a path" >&2
          return 1
        fi
        system="$(cat -- "$2")"
        shift 2
        ;;
      *)
        echo "archeflow-ollama: unknown option: $1" >&2
        return 1
        ;;
    esac
  done
  user_msg="$(cat)"
  if [[ -z "$user_msg" ]]; then
    echo "archeflow-ollama: stdin user message is empty" >&2
    return 1
  fi
  if [[ -n "$system" ]]; then
    payload="$(jq -n \
      --arg m "$model" \
      --arg s "$system" \
      --arg u "$user_msg" \
      '{model:$m, stream:false, messages:[{role:"system",content:$s},{role:"user",content:$u}]}')"
  else
    payload="$(jq -n \
      --arg m "$model" \
      --arg u "$user_msg" \
      '{model:$m, stream:false, messages:[{role:"user",content:$u}]}')"
  fi
  base="$(ollama_base_url)" || return 1
  if ! resp="$(curl -fsS --max-time 0 "${base}/api/chat" \
      -H "Content-Type: application/json" \
      -d "$payload")"; then
    echo "archeflow-ollama: POST ${base}/api/chat failed" >&2
    return 1
  fi
  err="$(echo "$resp" | jq -r '.error // empty')"
  if [[ -n "$err" ]]; then
    echo "archeflow-ollama: API error: $err" >&2
    return 1
  fi
  echo "$resp" | jq -r '.message.content // empty'
}

main() {
  local cmd
  cmd="${1:-}"
  if [[ $# -ge 1 ]]; then
    shift
  fi
  case "$cmd" in
    health) cmd_health ;;
    tags) cmd_tags ;;
    chat) cmd_chat "$@" ;;
    -h|--help|help|"") usage; [[ -n "$cmd" ]] || return 1 ;;
    *) echo "archeflow-ollama: unknown command: $cmd" >&2; usage >&2; return 1 ;;
  esac
}

main "$@"
