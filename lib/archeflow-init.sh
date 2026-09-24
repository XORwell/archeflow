#!/usr/bin/env bash
# archeflow-init.sh — Initialize an ArcheFlow project from a template bundle, clone from
# another project, save the current setup as a template, or list available templates.
#
# Usage:
#   archeflow-init.sh <bundle-name> [--set key=value ...]   Init from named bundle
#   archeflow-init.sh --from <project-path>                 Clone from another project
#   archeflow-init.sh --list                                List available templates
#   archeflow-init.sh --save <name>                         Save current setup as template
#   archeflow-init.sh --share <name> <path>                 Export template to directory
#
# Examples:
#   ./lib/archeflow-init.sh quick-fix
#   ./lib/archeflow-init.sh backend-feature --set max_cycles=3
#   ./lib/archeflow-init.sh --from ../backend-service
#   ./lib/archeflow-init.sh --save my-backend-setup
#   ./lib/archeflow-init.sh --list

set -euo pipefail

GLOBAL_TEMPLATES="${HOME}/.archeflow/templates"
LOCAL_TEMPLATES=".archeflow/templates"
# Bundles shipped with the plugin (lowest precedence).
BUILTIN_TEMPLATES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/templates"

# --- Helpers ----------------------------------------------------------------

# shellcheck disable=SC2034  # read by die() in archeflow-common.sh
AF_LOG_PREFIX=""
# shellcheck source=lib/archeflow-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archeflow-common.sh"
# Refuse a symlinked .archeflow/ (or events/, runs/, memory/ ...): writes would land outside the repo.
af_check_state_dirs
warn() { echo "WARNING: $*" >&2; }
info() { echo "  $*"; }

# Parse a scalar YAML value. Supports "key" and one level of nesting
# ("parent.child"). Pure awk on purpose: "yq" means two incompatible tools
# (mikefarah/Go vs kislyuk/jq-wrapper; GitHub runners ship the former), so
# using it made behavior depend on the host.
yaml_value() {
  local file="$1" key="$2"
  {
    local parent="" child="$key"
    if [[ "$key" == *.* ]]; then
      parent="${key%%.*}"
      child="${key#*.}"
    fi
    awk -v parent="$parent" -v child="$child" '
      function emit(line) {
        sub(/^[^:]*:[ \t]*/, "", line)
        sub(/[ \t]+#.*$/, "", line)
        sub(/[ \t]+$/, "", line)
        if (line ~ /^".*"$/ || line ~ /^\047.*\047$/) line = substr(line, 2, length(line) - 2)
        print line
        exit
      }
      parent == "" && index($0, child ":") == 1 { emit($0) }
      parent != "" && index($0, parent ":") == 1 { inside = 1; next }
      parent != "" && inside && /^[^ \t#]/ { inside = 0 }
      parent != "" && inside {
        line = $0
        sub(/^[ \t]+/, "", line)
        if (index(line, child ":") == 1) emit(line)
      }
    ' "$file" 2>/dev/null
  }
}

# Parse YAML list (simple — one item per "- " line under key).
yaml_list() {
  local file="$1" key="$2"
    sed -n "/^${key}:/,/^[^ -]/{ /^  *- /{ s/^  *- *//; s/^[\"']\(.*\)[\"']$/\1/; p; } }" "$file" 2>/dev/null
}

# Check if a directory has files matching a glob (safe for empty results).
has_files() {
  local dir="$1" pattern="${2:-*}"
  # shellcheck disable=SC2086
  compgen -G "${dir}/${pattern}" &>/dev/null
}

# Bundle names become path components under the template roots (and are
# rm -rf'd on --save overwrite), so restrict them to a safe charset.
validate_bundle_name() {
  local name="$1"
  if ! af_valid_name "$name"; then
    die "Invalid bundle name: '$name' (allowed: letters, digits, '.', '_', '-'; no path separators)"
  fi
}

# File names from a bundle manifest (includes.team etc.) must be plain file
# names inside the bundle; a shared bundle must not be able to read or write
# outside it via "../" or absolute paths. Returns 1 (with a warning) if unsafe.
safe_include_name() {
  local value="$1" field="$2"
  if [[ "$value" == */* || "$value" == *..* || "$value" == -* ]]; then
    warn "Ignoring unsafe includes.$field in manifest: '$value' (must be a plain file name)"
    return 1
  fi
}

# Keep secrets and run state out of the user's git: sprint agents commit "all
# changes", and langfuse.env holds API keys. Run state is local by default:
# events, artifacts, run metadata, the Maker's worktrees, memory (lessons are
# injected into prompts), review diffs, progress snapshots and the A2A card.
# Configuration (config.yaml, hooks.yaml, teams/, workflows/, domains/, lenses/,
# archetypes/, patterns/) stays trackable. Appends missing rules only.
AF_GITIGNORE_RULES=("langfuse.env" "*.errors.log" "*.lock" "*.lock.d/" "locks/"
  "events/" "artifacts/" "runs/" "worktrees/" "memory/"
  "review*.diff" "progress.md" "agent-card.json")
ensure_gitignore() {
  local gi=".archeflow/.gitignore" rule
  mkdir -p .archeflow
  af_refuse_symlink "$gi" || return 0
  if [[ ! -f "$gi" ]]; then
    printf '%s\n' "# ArcheFlow run state and secrets stay local; commit the configuration." > "$gi"
  fi
  for rule in "${AF_GITIGNORE_RULES[@]}"; do
    if ! grep -qxF -- "$rule" "$gi"; then
      printf '%s\n' "$rule" >> "$gi"
    fi
  done
}

# Confirm overwrite if target exists and has files.
confirm_overwrite() {
  local dir="$1" desc="$2"
  if [[ -d "$dir" ]] && has_files "$dir"; then
    warn "$desc already has files in $dir"
    if [[ -t 0 ]]; then
      read -r -p "  Overwrite? [y/N] " answer
      [[ "$answer" =~ ^[Yy]$ ]] || die "Aborted — will not overwrite existing files."
    else
      die "Non-interactive mode — will not overwrite existing files in $dir. Remove them first."
    fi
  fi
}

# --- Commands ---------------------------------------------------------------

cmd_list() {
  echo "ArcheFlow Templates"
  echo "===================="
  echo ""

  # Bundles
  local found_bundle=false
  echo "Bundles:"
  for base in "$LOCAL_TEMPLATES" "$GLOBAL_TEMPLATES" "$BUILTIN_TEMPLATES"; do
    local scope
    case "$base" in
      "$LOCAL_TEMPLATES") scope="local" ;;
      "$GLOBAL_TEMPLATES") scope="global" ;;
      *) scope="built-in" ;;
    esac
    if [[ -d "$base/bundles" ]]; then
      for manifest in "$base"/bundles/*/manifest.yaml; do
        [[ -f "$manifest" ]] || continue
        found_bundle=true
        local bname bdir desc
        bdir="$(dirname "$manifest")"
        bname="$(basename "$bdir")"
        desc="$(yaml_value "$manifest" "description")"
        printf "  %-25s %-45s [%s]\n" "$bname" "${desc:-(no description)}" "$scope"
      done
    fi
  done
  $found_bundle || echo "  (none)"
  echo ""

  # Individual templates
  echo "Individual Templates:"
  for category in workflows teams archetypes domains; do
    local found=false
    local label
    label="${category^}"  # Capitalize (portable; GNU sed \U is not)
    echo "  ${label}:"
    for base in "$LOCAL_TEMPLATES" "$GLOBAL_TEMPLATES"; do
      local scope
      [[ "$base" == "$LOCAL_TEMPLATES" ]] && scope="local" || scope="global"
      if [[ -d "$base/$category" ]]; then
        for f in "$base/$category"/*; do
          [[ -f "$f" ]] || continue
          found=true
          printf "    %-35s [%s]\n" "$(basename "$f")" "$scope"
        done
      fi
    done
    $found || echo "    (none)"
  done
}

cmd_init_bundle() {
  local bundle_name="$1"
  shift
  validate_bundle_name "$bundle_name"
  local -A overrides=()

  # Parse --set key=value arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --set)
        shift
        [[ $# -gt 0 ]] || die "--set requires a key=value argument"
        local k="${1%%=*}" v="${1#*=}"
        overrides["$k"]="$v"
        shift
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  # Find the bundle
  local bundle_dir=""
  for base in "$LOCAL_TEMPLATES" "$GLOBAL_TEMPLATES" "$BUILTIN_TEMPLATES"; do
    if [[ -f "$base/bundles/${bundle_name}/manifest.yaml" ]]; then
      bundle_dir="$base/bundles/${bundle_name}"
      break
    fi
  done
  [[ -n "$bundle_dir" ]] || die "Bundle not found: $bundle_name. Run '$0 --list' to see available templates."
  if [[ "$bundle_dir" == "$LOCAL_TEMPLATES"/* ]]; then
    # Project-local bundles come from the repository and take precedence over
    # the user's global and the built-in bundles of the same name.
    warn "Using project-local bundle $bundle_dir (supplied by this repository; it shadows any global/built-in '$bundle_name'). Review it before running."
  fi

  local manifest="$bundle_dir/manifest.yaml"
  echo "Initializing from bundle: $bundle_name"
  echo "  Source: $bundle_dir"
  echo ""

  # Check requires
  local req
  while IFS= read -r req; do
    [[ -z "$req" ]] && continue
    if [[ ! -e "$req" ]]; then
      die "Required file not found: $req. This bundle requires it in the project root."
    fi
    info "Requirement satisfied: $req"
  done < <(yaml_list "$manifest" "requires")

  # Create target directories
  mkdir -p .archeflow/teams .archeflow/workflows .archeflow/archetypes .archeflow/domains

  # Copy team
  local team_file
  team_file="$(yaml_value "$manifest" "includes.team" 2>/dev/null || true)"
  [[ -z "$team_file" ]] || safe_include_name "$team_file" team || team_file=""
  if [[ -n "$team_file" && -f "$bundle_dir/$team_file" ]]; then
    confirm_overwrite ".archeflow/teams" "Teams directory"
    cp "$bundle_dir/$team_file" ".archeflow/teams/$team_file"
    info "Team: $team_file -> .archeflow/teams/"
  elif [[ -n "$team_file" ]]; then
    # team_file might just be the name, check without path
    if [[ -f "$bundle_dir/team.yaml" ]]; then
      confirm_overwrite ".archeflow/teams" "Teams directory"
      cp "$bundle_dir/team.yaml" ".archeflow/teams/$team_file"
      info "Team: $team_file -> .archeflow/teams/"
    else
      warn "Team file not found in bundle: $team_file"
    fi
  fi

  # Copy workflow
  local wf_file
  wf_file="$(yaml_value "$manifest" "includes.workflow" 2>/dev/null || true)"
  [[ -z "$wf_file" ]] || safe_include_name "$wf_file" workflow || wf_file=""
  if [[ -n "$wf_file" && -f "$bundle_dir/$wf_file" ]]; then
    confirm_overwrite ".archeflow/workflows" "Workflows directory"
    cp "$bundle_dir/$wf_file" ".archeflow/workflows/$wf_file"
    info "Workflow: $wf_file -> .archeflow/workflows/"
  elif [[ -n "$wf_file" && -f "$bundle_dir/workflow.yaml" ]]; then
    confirm_overwrite ".archeflow/workflows" "Workflows directory"
    cp "$bundle_dir/workflow.yaml" ".archeflow/workflows/$wf_file"
    info "Workflow: $wf_file -> .archeflow/workflows/"
  elif [[ -n "$wf_file" ]]; then
    warn "Workflow file not found in bundle: $wf_file"
  fi

  # Copy archetypes
  local arch_count=0
  if [[ -d "$bundle_dir/archetypes" ]] && has_files "$bundle_dir/archetypes" "*.md"; then
    confirm_overwrite ".archeflow/archetypes" "Archetypes directory"
    for f in "$bundle_dir"/archetypes/*.md; do
      [[ -f "$f" ]] || continue
      cp "$f" ".archeflow/archetypes/$(basename "$f")"
      arch_count=$((arch_count + 1))
    done
    info "Archetypes: $arch_count files -> .archeflow/archetypes/"
  fi

  # Copy domain
  local domain_file
  domain_file="$(yaml_value "$manifest" "includes.domain" 2>/dev/null || true)"
  [[ -z "$domain_file" ]] || safe_include_name "$domain_file" domain || domain_file=""
  if [[ -n "$domain_file" && -f "$bundle_dir/$domain_file" ]]; then
    confirm_overwrite ".archeflow/domains" "Domains directory"
    cp "$bundle_dir/$domain_file" ".archeflow/domains/$domain_file"
    info "Domain: $domain_file -> .archeflow/domains/"
  elif [[ -n "$domain_file" && -f "$bundle_dir/domain.yaml" ]]; then
    confirm_overwrite ".archeflow/domains" "Domains directory"
    cp "$bundle_dir/domain.yaml" ".archeflow/domains/$domain_file"
    info "Domain: $domain_file -> .archeflow/domains/"
  elif [[ -n "$domain_file" ]]; then
    warn "Domain file not found in bundle: $domain_file"
  fi

  # Copy hooks if present
  if [[ -f "$bundle_dir/hooks.yaml" ]]; then
    cp "$bundle_dir/hooks.yaml" ".archeflow/hooks.yaml"
    info "Hooks: hooks.yaml -> .archeflow/"
    warn ".archeflow/hooks.yaml contains commands the agent will run during a run. Review it."
  fi

  ensure_gitignore

  # Generate config.yaml with variables
  local config_file=".archeflow/config.yaml"
  af_refuse_symlink "$config_file" || exit 1
  {
    echo "# Generated by archeflow init from bundle: $bundle_name"
    echo "bundle: $bundle_name"
    local version
    version="$(yaml_value "$manifest" "version")"
    echo "bundle_version: ${version:-1}"
    echo "initialized: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "variables:"

    # Read default variables from manifest
    local -A vars=()
    {
      # Parse the top-level variables: block (one level, scalar values)
      local in_vars=false
      while IFS= read -r line; do
        if [[ "$line" =~ ^variables: ]]; then
          in_vars=true; continue
        fi
        if $in_vars; then
          if [[ "$line" =~ ^[[:space:]]+([A-Za-z0-9_.-]+):[[:space:]]*(.*)$ ]]; then
            local vk="${BASH_REMATCH[1]}" vv="${BASH_REMATCH[2]}"
            # Strip trailing " # comment", surrounding whitespace, then quotes.
            vv="$(printf '%s' "$vv" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
            vv="$(printf '%s' "$vv" | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')"
            vars["$vk"]="$vv"
          elif [[ "$line" =~ ^[^[:space:]] ]]; then
            break
          fi
        fi
      done < "$manifest"
    }

    # Apply overrides
    for k in "${!overrides[@]}"; do
      vars["$k"]="${overrides[$k]}"
    done

    # Write variables
    if [[ ${#vars[@]} -eq 0 ]]; then
      echo "  # (no variables defined)"
    else
      while IFS= read -r k; do
        echo "  $k: ${vars[$k]}"
      done < <(printf '%s\n' "${!vars[@]}" | sort)
    fi

    # Carry the bundle's workflow (read by the run skill) and budget
    # (costs.budget_usd, read by archeflow-convergence.sh wiggum-check) from its
    # config.yaml into the project config.
    local cfg_inc budget warn_pct workflow
    cfg_inc="$(yaml_value "$manifest" "includes.config" 2>/dev/null || true)"
    [[ -z "$cfg_inc" ]] || safe_include_name "$cfg_inc" config || cfg_inc=""
    if [[ -n "$cfg_inc" && -f "$bundle_dir/$cfg_inc" ]]; then
      workflow="$(yaml_value "$bundle_dir/$cfg_inc" "workflow" 2>/dev/null || true)"
      case "$workflow" in
        fast|standard|thorough) echo "workflow: $workflow" ;;
        "") ;;
        *) warn "Ignoring unknown workflow in bundle config: '$workflow' (fast, standard or thorough)" ;;
      esac
      budget="$(yaml_value "$bundle_dir/$cfg_inc" "costs.budget_usd" 2>/dev/null || true)"
      warn_pct="$(yaml_value "$bundle_dir/$cfg_inc" "costs.warn_at_percent" 2>/dev/null || true)"
      if [[ "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "costs:"
        echo "  budget_usd: $budget"
        [[ "$warn_pct" =~ ^[0-9]+$ ]] && echo "  warn_at_percent: $warn_pct"
      fi
    fi
  } > "$config_file"
  info "Config: $config_file"

  echo ""
  echo "ArcheFlow initialized from bundle: $bundle_name"

  # Print variable summary
  if [[ ${#vars[@]} -gt 0 ]]; then
    local var_summary=""
    while IFS= read -r k; do
      [[ -n "$var_summary" ]] && var_summary+=", "
      var_summary+="${k}=${vars[$k]}"
    done < <(printf '%s\n' "${!vars[@]}" | sort)
    echo "  Variables: $var_summary"
  fi

  echo ""
  echo "Ready to run: archeflow:run"
}

cmd_init_from() {
  local source_path="$1"

  [[ -d "$source_path/.archeflow" ]] || die "No .archeflow/ directory found in $source_path"

  echo "Cloning ArcheFlow setup from: $source_path"
  echo ""

  mkdir -p .archeflow

  local copied=0
  for subdir in teams workflows archetypes domains; do
    if [[ -d "$source_path/.archeflow/$subdir" ]] && has_files "$source_path/.archeflow/$subdir"; then
      confirm_overwrite ".archeflow/$subdir" "$subdir directory"
      mkdir -p ".archeflow/$subdir"
      cp "$source_path/.archeflow/$subdir"/* ".archeflow/$subdir/"
      local count
      count=$(find ".archeflow/$subdir" -maxdepth 1 -type f | wc -l)
      info "$subdir/: $count files copied"
      copied=$((copied + count))
    fi
  done

  # Copy config.yaml if present
  if [[ -f "$source_path/.archeflow/config.yaml" ]]; then
    cp "$source_path/.archeflow/config.yaml" ".archeflow/config.yaml"
    info "config.yaml copied"
    copied=$((copied + 1))
  fi

  # Copy hooks.yaml if present
  if [[ -f "$source_path/.archeflow/hooks.yaml" ]]; then
    cp "$source_path/.archeflow/hooks.yaml" ".archeflow/hooks.yaml"
    info "hooks.yaml copied"
    warn ".archeflow/hooks.yaml contains commands the agent will run during a run. Review it."
    copied=$((copied + 1))
  fi

  ensure_gitignore

  # Explicitly skip run-specific directories
  for skip in events artifacts context templates; do
    if [[ -d "$source_path/.archeflow/$skip" ]]; then
      info "(skipped $skip/ — run-specific data)"
    fi
  done

  echo ""
  echo "Cloned $copied files from $source_path"
  echo "Ready to run: archeflow:run"
}

cmd_save() {
  local name="$1"
  validate_bundle_name "$name"

  [[ -d ".archeflow" ]] || die "No .archeflow/ directory in current project. Nothing to save."

  local bundle_dir="$GLOBAL_TEMPLATES/bundles/$name"

  if [[ -d "$bundle_dir" ]]; then
    warn "Template bundle already exists: $bundle_dir"
    if [[ -t 0 ]]; then
      read -r -p "  Overwrite? [y/N] " answer
      [[ "$answer" =~ ^[Yy]$ ]] || die "Aborted."
    else
      die "Non-interactive mode — will not overwrite existing bundle $name."
    fi
    rm -rf "$bundle_dir"
  fi

  mkdir -p "$bundle_dir"
  echo "Saving current setup as template: $name"
  echo ""

  local team_file="" wf_file="" domain_file=""
  local -a arch_files=()
  local file_count=0

  # Copy teams (take first .yaml file)
  if [[ -d ".archeflow/teams" ]] && has_files ".archeflow/teams" "*.yaml"; then
    team_file="$(ls .archeflow/teams/*.yaml 2>/dev/null | head -1)"
    if [[ -n "$team_file" ]]; then
      cp "$team_file" "$bundle_dir/$(basename "$team_file")"
      team_file="$(basename "$team_file")"
      info "Team: $team_file"
      file_count=$((file_count + 1))
    fi
  fi

  # Copy workflows (take first .yaml file)
  if [[ -d ".archeflow/workflows" ]] && has_files ".archeflow/workflows" "*.yaml"; then
    wf_file="$(ls .archeflow/workflows/*.yaml 2>/dev/null | head -1)"
    if [[ -n "$wf_file" ]]; then
      cp "$wf_file" "$bundle_dir/$(basename "$wf_file")"
      wf_file="$(basename "$wf_file")"
      info "Workflow: $wf_file"
      file_count=$((file_count + 1))
    fi
  fi

  # Copy archetypes
  if [[ -d ".archeflow/archetypes" ]] && has_files ".archeflow/archetypes" "*.md"; then
    mkdir -p "$bundle_dir/archetypes"
    for f in .archeflow/archetypes/*.md; do
      [[ -f "$f" ]] || continue
      cp "$f" "$bundle_dir/archetypes/"
      arch_files+=("$(basename "$f")")
      file_count=$((file_count + 1))
    done
    info "Archetypes: ${#arch_files[@]} files"
  fi

  # Copy domain (take first .yaml file)
  if [[ -d ".archeflow/domains" ]] && has_files ".archeflow/domains" "*.yaml"; then
    domain_file="$(ls .archeflow/domains/*.yaml 2>/dev/null | head -1)"
    if [[ -n "$domain_file" ]]; then
      cp "$domain_file" "$bundle_dir/$(basename "$domain_file")"
      domain_file="$(basename "$domain_file")"
      info "Domain: $domain_file"
      file_count=$((file_count + 1))
    fi
  fi

  # Copy hooks if present
  if [[ -f ".archeflow/hooks.yaml" ]]; then
    cp ".archeflow/hooks.yaml" "$bundle_dir/hooks.yaml"
    info "Hooks: hooks.yaml"
    file_count=$((file_count + 1))
  fi

  # Detect domain name from domain file
  local domain_name=""
  if [[ -n "$domain_file" && -f "$bundle_dir/$domain_file" ]]; then
    domain_name="$(yaml_value "$bundle_dir/$domain_file" "name")"
  fi

  # Read variables from config.yaml if present
  local has_vars=false
  local vars_yaml=""
  if [[ -f ".archeflow/config.yaml" ]]; then
    {
      local in_vars=false
      while IFS= read -r line; do
        if [[ "$line" =~ ^variables: ]]; then
          in_vars=true; continue
        fi
        if $in_vars; then
          if [[ "$line" =~ ^[[:space:]] ]]; then
            vars_yaml+="$line"$'\n'
            has_vars=true
          else
            break
          fi
        fi
      done < ".archeflow/config.yaml"
    }
  fi

  # Generate manifest
  local project_dir
  project_dir="$(basename "$(pwd)")"
  {
    echo "name: $name"
    echo "description: \"Saved from $project_dir\""
    echo "version: 1"
    [[ -n "$domain_name" ]] && echo "domain: $domain_name"
    echo "includes:"
    [[ -n "$team_file" ]] && echo "  team: $team_file"
    [[ -n "$wf_file" ]] && echo "  workflow: $wf_file"
    if [[ ${#arch_files[@]} -gt 0 ]]; then
      echo "  archetypes:"
      for a in "${arch_files[@]}"; do
        echo "    - $a"
      done
    fi
    [[ -n "$domain_file" ]] && echo "  domain: $domain_file"
    echo "requires: []"
    if $has_vars; then
      echo "variables:"
      echo "$vars_yaml"
    else
      echo "variables: {}"
    fi
  } > "$bundle_dir/manifest.yaml"

  file_count=$((file_count + 1))  # manifest itself

  echo ""
  echo "Template saved: $name"
  echo "  Location: $bundle_dir/"
  echo "  Files: $file_count"
  echo "  Use with: archeflow init $name"
}

cmd_share() {
  local name="$1" target="$2"
  validate_bundle_name "$name"

  local bundle_dir=""
  for base in "$LOCAL_TEMPLATES" "$GLOBAL_TEMPLATES" "$BUILTIN_TEMPLATES"; do
    if [[ -d "$base/bundles/$name" ]]; then
      bundle_dir="$base/bundles/$name"
      break
    fi
  done
  [[ -n "$bundle_dir" ]] || die "Bundle not found: $name. Run '$0 --list' to see available templates."

  mkdir -p "$target"
  [[ ! -e "$target/$name" ]] || die "Target already exists: $target/$name (remove it first)"
  cp -r -- "$bundle_dir" "$target/$name"

  echo "Exported: $target/$name/"
  echo "To import: cp -r $target/$name ~/.archeflow/templates/bundles/"
}

# --- Main -------------------------------------------------------------------

if [[ $# -eq 0 ]]; then
  echo "Usage:"
  echo "  $0 <bundle-name> [--set key=value ...]   Init from named bundle"
  echo "  $0 --from <project-path>                 Clone from another project"
  echo "  $0 --list                                List available templates"
  echo "  $0 --save <name>                         Save current setup as template"
  echo "  $0 --share <name> <path>                 Export template to directory"
  exit 0
fi

case "$1" in
  --list)
    cmd_list
    ;;
  --from)
    [[ $# -ge 2 ]] || die "--from requires a project path"
    cmd_init_from "$2"
    ;;
  --save)
    [[ $# -ge 2 ]] || die "--save requires a template name"
    cmd_save "$2"
    ;;
  --share)
    [[ $# -ge 3 ]] || die "--share requires a name and a target path"
    cmd_share "$2" "$3"
    ;;
  -h|--help)
    sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  -*)
    die "Unknown option: $1"
    ;;
  *)
    cmd_init_bundle "$@"
    ;;
esac
