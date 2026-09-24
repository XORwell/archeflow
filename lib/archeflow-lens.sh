#!/usr/bin/env bash
# archeflow-lens.sh — Lens management: list, show, validate, merge
# Lenses are stackable attention modifiers that layer onto the active domain.
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;; esac
set -euo pipefail

ARCHEFLOW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/archeflow-common.sh
source "$ARCHEFLOW_ROOT/lib/archeflow-common.sh"
BUILTIN_DIR="$ARCHEFLOW_ROOT/lenses"
PROJECT_DIR=".archeflow/lenses"

usage() {
  cat <<'EOF'
Usage: archeflow-lens.sh <command> [args]

Commands:
  list                     List available lenses (built-in + project)
  show <name>              Print a lens definition
  validate <name>          Check lens yaml for required fields
  merge <name> [<name>...] Merge lenses and print combined config (JSON)
  merge --from-config      Merge the lenses listed under "lenses:" in .archeflow/config.yaml
                           (the names are read and validated here, never typed into a shell)
  resolve <name>           Find the file path for a lens (project overrides built-in)
EOF
  exit 1
}

# Find lens file: project-local overrides built-in
resolve() {
  local name="$1"
  # Lens names are file stems; reject paths so "../../x" cannot pull an
  # arbitrary YAML file into agent prompts.
  if ! af_valid_name "$name"; then
    echo "error: invalid lens name '$name'" >&2
    return 1
  fi
  if [[ -f "$PROJECT_DIR/${name}.yaml" ]]; then
    echo "$PROJECT_DIR/${name}.yaml"
  elif [[ -f "$BUILTIN_DIR/${name}.yaml" ]]; then
    echo "$BUILTIN_DIR/${name}.yaml"
  else
    echo "error: lens '$name' not found" >&2
    return 1
  fi
}

cmd_list() {
  echo "Built-in lenses:"
  for f in "$BUILTIN_DIR"/*.yaml; do
    [[ -f "$f" ]] || continue
    local name desc
    name="$(basename "$f" .yaml)"
    desc="$(grep -m1 '^description:' "$f" | sed 's/^description: *//')"
    printf "  %-20s %s\n" "$name" "$desc"
  done

  if [[ -d "$PROJECT_DIR" ]]; then
    echo ""
    echo "Project lenses:"
    for f in "$PROJECT_DIR"/*.yaml; do
      [[ -f "$f" ]] || continue
      local name desc
      name="$(basename "$f" .yaml)"
      desc="$(grep -m1 '^description:' "$f" | sed 's/^description: *//')"
      printf "  %-20s %s\n" "$name" "$desc"
    done
  fi
}

cmd_show() {
  local name="${1:?lens name required}"
  local file
  file="$(resolve "$name")"
  cat "$file"
}

cmd_validate() {
  local name="${1:?lens name required}"
  local file errors=0
  file="$(resolve "$name")"

  for field in name description version; do
    if ! grep -q "^${field}:" "$file"; then
      echo "MISSING: $field" >&2
      errors=$((errors + 1))
    fi
  done

  if [[ $errors -eq 0 ]]; then
    echo "OK: $name"
  else
    echo "FAIL: $errors missing field(s)" >&2
    return 1
  fi
}

# context_inject lists files whose contents the run skill pastes into agent
# prompts. Project lenses come from the repository, so an entry like
# "~/.ssh/id_ed25519", "$HOME/.aws/credentials", "src/$(cmd).md" or "docs/*"
# would leak local secrets into prompts (or run a command, if an agent ever
# typed it into a shell). Every entry must be a plain relative path: only
# letters, digits, ".", "_", "-" and "/", no leading "-" or "/", no "."/".."
# components. If it exists it must resolve inside the project root (no symlink
# escape). Prints the offending entry and returns 1.
validate_context_inject() {
  local merged="$1" root entry resolved comp
  if ! jq -e '(.context_inject | type) == "object"
      and all(.context_inject[]; type == "array" and all(.[]; type == "string"))' <<<"$merged" >/dev/null 2>&1; then
    echo "error: context_inject must map phase names to lists of file paths" >&2
    return 1
  fi
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  root="$(cd "$root" && pwd -P)"
  while IFS= read -r -d '' entry; do
    if [[ ! "$entry" =~ ^[A-Za-z0-9._/-]+$ || "$entry" == -* || "$entry" == /* ]]; then
      echo "error: unsafe context_inject path '$entry' (plain relative paths only: letters, digits, '.', '_', '-', '/')" >&2
      return 1
    fi
    local -a comps=()
    IFS=/ read -r -a comps <<<"$entry"
    for comp in "${comps[@]}"; do
      if [[ -z "$comp" || "$comp" == "." || "$comp" == ".." ]]; then
        echo "error: unsafe context_inject path '$entry' (empty, '.' or '..' component)" >&2
        return 1
      fi
    done
    if [[ -e "$entry" || -L "$entry" ]]; then
      resolved="$(_resolve_path "$entry")" || resolved=""
      if [[ -z "$resolved" || ( "$resolved" != "$root" && "$resolved" != "$root"/* ) ]]; then
        echo "error: context_inject path '$entry' resolves outside the project root" >&2
        return 1
      fi
    fi
  done < <(jq -j '.context_inject[][] | (. + "\u0000")' <<<"$merged")
  return 0
}

# Physical absolute path of an existing file (follows symlinks).
_resolve_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -- "$p" 2>/dev/null
    return
  fi
  local dir base n=0
  while [[ -L "$p" && $n -lt 40 ]]; do
    dir="$(cd "$(dirname -- "$p")" && pwd -P)" || return 1
    p="$(readlink -- "$p")" || return 1
    [[ "$p" == /* ]] || p="$dir/$p"
    n=$((n + 1))
  done
  [[ -L "$p" ]] && return 1
  dir="$(cd "$(dirname -- "$p")" && pwd -P)" || return 1
  base="$(basename -- "$p")"
  printf '%s/%s\n' "$dir" "$base"
}

cmd_merge() {
  # Merge N lenses into a single combined JSON config.
  # Arrays union, scalars last-wins, extra_focus concatenates.
  # Requires jq.
  command -v jq >/dev/null 2>&1 || { echo "error: jq required for merge" >&2; exit 1; }

  if [[ "${1:-}" == "--from-config" ]]; then
    [[ $# -eq 1 ]] || { echo "error: --from-config takes no lens names" >&2; exit 1; }
    local cfg
    cfg="$(af_config_json)" || { echo "error: could not parse .archeflow/config.yaml" >&2; exit 1; }
    if ! jq -e '(.lenses // []) | type == "array" and all(.[]; type == "string")' <<<"$cfg" >/dev/null; then
      echo "error: 'lenses' in .archeflow/config.yaml must be a list of names" >&2
      exit 1
    fi
    local -a names=()
    mapfile -t names < <(jq -r '(.lenses // [])[]' <<<"$cfg")
    [[ ${#names[@]} -gt 0 ]] || { echo "error: no lenses configured in .archeflow/config.yaml" >&2; exit 1; }
    local n
    for n in "${names[@]}"; do
      af_valid_name "$n" || { echo "error: invalid lens name '$n' in .archeflow/config.yaml" >&2; exit 1; }
    done
    set -- "${names[@]}"
  fi
  [[ $# -gt 0 ]] || { echo "error: merge needs at least one lens name (or --from-config)" >&2; exit 1; }

  local merged='{"finding_categories":[],"context_inject":{},"attention":{},"shadow_overrides":{},"evidence_rules":[],"model_overrides":{}}'

  for name in "$@"; do
    local file
    file="$(resolve "$name")" || exit 1

    # YAML -> JSON (af_yaml_to_json): yq, python3+PyYAML, else the built-in
    # converter, so lens merging works on a stock runner with only bash/awk/jq.
    local json
    json="$(af_yaml_to_json "$file")" || { echo "error: could not parse lens $file" >&2; exit 1; }

    # Merge step: union arrays, override scalars, concat extra_focus
    merged="$(jq -n --argjson base "$merged" --argjson lens "$json" '
      # Union finding_categories
      ($base.finding_categories + ($lens.finding_categories // [])) | unique
      | . as $cats

      # Merge context_inject (union arrays per phase)
      | ($base.context_inject // {}) as $bc
      | ($lens.context_inject // {}) as $lc
      | ($bc | keys) + ($lc | keys) | unique
      | reduce .[] as $phase ({}; . + {
          ($phase): (($bc[$phase] // []) + ($lc[$phase] // []) | unique)
        })
      | . as $ctx

      # Merge attention (per archetype: override weight, concat extra_focus, union extra_categories)
      | ($base.attention // {}) as $ba
      | ($lens.attention // {}) as $la
      | ($ba | keys) + ($la | keys) | unique
      | reduce .[] as $arch ({}; . + {
          ($arch): {
            weight: ($la[$arch].weight // $ba[$arch].weight // 1.0),
            extra_focus: (
              [($ba[$arch].extra_focus // ""), ($la[$arch].extra_focus // "")]
              | map(select(. != ""))
              | join("; ")
            ),
            extra_categories: (
              (($ba[$arch].extra_categories // []) + ($la[$arch].extra_categories // []))
              | unique
            )
          }
        })
      | . as $att

      # Override shadow_overrides (last wins per archetype per param)
      | ($base.shadow_overrides // {}) * ($lens.shadow_overrides // {})
      | . as $shd

      # Union evidence_rules (dedup by category)
      | ($base.evidence_rules + ($lens.evidence_rules // []))
      | group_by(.category) | map(last)
      | . as $ev

      # Override model_overrides (last wins)
      | ($base.model_overrides // {}) + ($lens.model_overrides // {})
      | . as $mod

      # Assemble
      | {
          lenses: (($base.lenses // []) + [$lens.name]),
          finding_categories: $cats,
          context_inject: $ctx,
          attention: $att,
          shadow_overrides: $shd,
          evidence_rules: $ev,
          model_overrides: $mod
        }
    ')"
  done

  validate_context_inject "$merged" || exit 1
  echo "$merged"
}

cmd_resolve() {
  local name="${1:?lens name required}"
  resolve "$name"
}

# Dispatch
case "${1:-}" in
  list)     cmd_list ;;
  show)     cmd_show "${2:-}" ;;
  validate) cmd_validate "${2:-}" ;;
  merge)    shift; cmd_merge "$@" ;;
  resolve)  cmd_resolve "${2:-}" ;;
  *)        usage ;;
esac
