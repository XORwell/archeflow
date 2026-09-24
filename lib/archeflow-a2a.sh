#!/usr/bin/env bash
# archeflow-a2a.sh — Generate A2A (Agent-to-Agent) protocol Agent Cards.
#
# Reads archetype definitions from agents/*.md and produces a machine-readable
# Agent Card (JSON) following Google's A2A specification (v1.0.0, Apache 2.0).
# This makes ArcheFlow archetypes discoverable by any A2A-compliant system.
#
# Usage:
#   ./lib/archeflow-a2a.sh generate [--output <path>]   # Generate Agent Card JSON
#   ./lib/archeflow-a2a.sh serve [--port <port>]         # Serve at /.well-known/agent-card.json
#   ./lib/archeflow-a2a.sh validate [<path>]             # Validate an existing Agent Card
#
# Dependencies: jq, bash 4+
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/archeflow-common.sh
source "${SCRIPT_DIR}/archeflow-common.sh"
ARCHEFLOW_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENTS_DIR="${ARCHEFLOW_DIR}/agents"
CONFIG_FILE=".archeflow/config.yaml"
DEFAULT_OUTPUT=".archeflow/agent-card.json"

# --- Helpers ---

yaml_get() {
  local file="$1" key="$2" default="${3:-}"
  if [[ -f "$file" ]]; then
    local val
    val=$(grep -E "^\s*${key}:" "$file" 2>/dev/null | head -1 | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
    [[ -n "$val" && "$val" != "null" ]] && { echo "$val"; return; }
  fi
  echo "$default"
}

parse_frontmatter() {
  local file="$1" key="$2"
  awk '/^---$/{n++; next} n==1' "$file" | grep -E "^\s*${key}:" | head -1 \
    | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | sed 's/^|$//' \
    | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

parse_body_section() {
  local file="$1" header="$2"
  awk -v h="$header" '
    /^## /{found=($0 ~ h); next}
    found && /^## /{exit}
    found{print}
  ' "$file" | sed '/^$/d' | head -5
}

# Map archetype to PDCA phase
archetype_phase() {
  case "$1" in
    explorer|creator) echo "plan" ;;
    maker)            echo "do" ;;
    guardian|skeptic|sage|trickster) echo "check" ;;
    *) echo "custom" ;;
  esac
}

archetype_tags() {
  case "$1" in
    explorer)  echo '["research","analysis","context","dependencies","planning"]' ;;
    creator)   echo '["design","architecture","proposal","planning"]' ;;
    maker)     echo '["implementation","coding","testing","execution"]' ;;
    guardian)  echo '["security","review","vulnerability","reliability"]' ;;
    skeptic)   echo '["assumptions","challenges","alternatives","review"]' ;;
    sage)      echo '["quality","maintainability","patterns","review"]' ;;
    trickster) echo '["adversarial","edge-cases","chaos","testing"]' ;;
    *)         echo '["custom"]' ;;
  esac
}

archetype_examples() {
  case "$1" in
    explorer)  echo '["Research the auth module before redesign","Map dependencies for the payment flow","What does the codebase use for error handling?"]' ;;
    creator)   echo '["Design a solution for JWT authentication","Propose architecture for the new API","Create a plan for database migration"]' ;;
    maker)     echo '["Implement the auth changes from the proposal","Build the API endpoint with tests","Apply the migration plan"]' ;;
    guardian)  echo '["Review this PR for security issues","Check for breaking changes in the API","Audit dependency vulnerabilities"]' ;;
    skeptic)   echo '["Challenge the assumptions in this proposal","What if the auth provider goes down?","Are we solving the right problem?"]' ;;
    sage)      echo '["Senior engineer review of this PR","Is this maintainable in 6 months?","Does this follow codebase patterns?"]' ;;
    trickster) echo '["Try to break the new input handler","What happens with empty/null inputs?","Find race conditions in the queue"]' ;;
    *)         echo '[]' ;;
  esac
}

# --- Commands ---

cmd_generate() {
  local output="$DEFAULT_OUTPUT"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) output="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local version
  version=$(yaml_get "$CONFIG_FILE" "version" "0.9.0")

  # Build skills array from agent markdown files
  local skills="[]"

  for agent_file in "${AGENTS_DIR}"/*.md; do
    [[ -f "$agent_file" ]] || continue

    local name desc lens shadow phase tags examples
    name=$(parse_frontmatter "$agent_file" "name")
    [[ -z "$name" ]] && continue

    # Extract first line of description from frontmatter
    desc=$(awk '/^---$/{n++; next} n==1 && /description:/{found=1; next} found && /^  [A-Z]/{gsub(/^[[:space:]]+/,""); print; exit}' "$agent_file")
    if [[ -z "$desc" ]]; then
      desc=$(parse_frontmatter "$agent_file" "description")
    fi

    lens=$(parse_body_section "$agent_file" "Your Lens" | head -1 | sed 's/^"//;s/"$//')
    shadow=$(parse_body_section "$agent_file" "Shadow:" | head -1)
    phase=$(archetype_phase "$name")
    tags=$(archetype_tags "$name")
    examples=$(archetype_examples "$name")

    local skill
    skill=$(jq -cn \
      --arg id "archeflow-${name}" \
      --arg name "$name" \
      --arg desc "${desc:-Archetype agent}" \
      --arg phase "$phase" \
      --arg lens "${lens:-}" \
      --arg shadow "${shadow:-}" \
      --argjson tags "$tags" \
      --argjson examples "$examples" \
      '{
        id: $id,
        name: $name,
        description: $desc,
        tags: ($tags + [$phase, "archeflow", "pdca"]),
        examples: $examples,
        inputModes: ["text/plain", "application/json"],
        outputModes: ["text/plain", "application/json"],
        metadata: {
          phase: $phase,
          lens: $lens,
          shadow: $shadow
        }
      }')

    skills=$(echo "$skills" | jq --argjson s "$skill" '. + [$s]')
  done

  # Build the Agent Card
  local card
  card=$(jq -cn \
    --arg version "$version" \
    --argjson skills "$skills" \
    '{
      name: "ArcheFlow",
      description: "Multi-agent orchestration with archetypal roles and PDCA quality cycles. Spawns parallel agent teams for code review, implementation, and creative workflows across multiple projects.",
      url: "https://github.com/XORwell/archeflow",
      provider: {
        organization: "XORwell",
        url: "https://github.com/XORwell"
      },
      version: $version,
      documentationUrl: "https://github.com/XORwell/archeflow#readme",
      capabilities: {
        streaming: false,
        pushNotifications: false,
        stateTransitionHistory: true
      },
      authentication: {
        schemes: ["none"],
        credentials: null
      },
      defaultInputModes: ["text/plain", "application/json"],
      defaultOutputModes: ["text/plain", "application/json"],
      skills: $skills,
      metadata: {
        protocol: "a2a",
        protocolVersion: "1.0.0",
        archetypeCount: ($skills | length),
        phases: ["plan", "do", "check", "act"],
        workflows: ["fast", "standard", "thorough"],
        domains: ["code", "writing", "research"]
      }
    }')

  mkdir -p "$(dirname "$output")"
  af_refuse_symlink "$output" || exit 1
  echo "$card" | jq '.' > "$output"
  echo "[archeflow-a2a] Generated Agent Card: $output ($(echo "$skills" | jq length) skills)" >&2
}

cmd_validate() {
  local card_file="${1:-$DEFAULT_OUTPUT}"

  if [[ ! -f "$card_file" ]]; then
    echo "Error: Agent Card not found: $card_file" >&2
    exit 1
  fi

  local errors=0

  # Required top-level fields
  for field in name description url version skills; do
    if ! jq -e ".$field" "$card_file" > /dev/null 2>&1; then
      echo "MISSING: required field '$field'" >&2
      errors=$((errors + 1))
    fi
  done

  # Validate each skill
  local skill_count
  # The card may be repository-supplied: only a real array length is used.
  skill_count=$(af_as_int "$(jq '.skills | if type == "array" then length else 0 end' "$card_file" 2>/dev/null)")

  for ((i=0; i<skill_count; i++)); do
    for field in id name description; do
      if ! jq -e ".skills[$i].$field" "$card_file" > /dev/null 2>&1; then
        echo "MISSING: skill[$i] missing '$field'" >&2
        errors=$((errors + 1))
      fi
    done
  done

  if [[ "$errors" -eq 0 ]]; then
    echo "[archeflow-a2a] Agent Card valid: $card_file ($skill_count skills)" >&2
  else
    echo "[archeflow-a2a] Agent Card has $errors error(s)" >&2
    return 1
  fi
}

cmd_serve() {
  local port="8099"
  local bind="${ARCHEFLOW_A2A_BIND:-127.0.0.1}"
  local card_file="$DEFAULT_OUTPUT"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) [[ $# -ge 2 ]] || { echo "Error: --port requires a value" >&2; exit 1; }; port="$2"; shift 2 ;;
      --bind) [[ $# -ge 2 ]] || { echo "Error: --bind requires an address" >&2; exit 1; }; bind="$2"; shift 2 ;;
      [0-9]*) port="$1"; shift ;;  # legacy positional port
      *) echo "Error: unknown serve option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    echo "Error: invalid port '$port'" >&2
    exit 1
  fi
  command -v nc >/dev/null 2>&1 || { echo "Error: serve requires nc (netcat)" >&2; exit 1; }

  if [[ ! -f "$card_file" ]]; then
    echo "Generating Agent Card first..." >&2
    cmd_generate
  fi

  echo "[archeflow-a2a] Serving Agent Card on http://${bind}:${port}/.well-known/agent-card.json" >&2
  echo "[archeflow-a2a] Bound to ${bind} (set --bind / ARCHEFLOW_A2A_BIND to change). Press Ctrl+C to stop" >&2

  # Minimal HTTP server using netcat (no python dependency). Binds to loopback
  # by default; the former "nc -l <port>" fallback listened on all interfaces.
  local response length http
  while true; do
    response=$(cat "$card_file")
    length=$(printf '%s' "$response" | LC_ALL=C wc -c | tr -d ' ')  # bytes, not characters
    http=$(printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n%s' \
      "$length" "$response")
    # OpenBSD nc / ncat syntax first, then traditional (GNU/Debian) netcat syntax.
    printf '%s' "$http" | nc -l "$bind" "$port" >/dev/null 2>&1 \
      || printf '%s' "$http" | nc -l -s "$bind" -p "$port" -q 1 >/dev/null 2>&1 \
      || { echo "[archeflow-a2a] nc could not listen on ${bind}:${port}" >&2; break; }
  done
}

# --- Main ---

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <command> [args...]" >&2
  echo "" >&2
  echo "Commands:" >&2
  echo "  generate [--output <path>]  Generate A2A Agent Card JSON" >&2
  echo "  validate [<path>]           Validate an Agent Card" >&2
  echo "  serve [--port <port>] [--bind <addr>]  Serve Agent Card via HTTP (default 127.0.0.1:8099)" >&2
  exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
  generate) cmd_generate "$@" ;;
  validate) cmd_validate "$@" ;;
  serve)    cmd_serve "$@" ;;
  *)        echo "Unknown command: $COMMAND" >&2; exit 1 ;;
esac
