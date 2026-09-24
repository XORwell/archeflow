#!/usr/bin/env bash
# archeflow-git.sh — Git branch strategy for ArcheFlow runs.
#
# A run works on its own branch (<branch_prefix><run_id>, default archeflow/<run_id>).
# The Maker works in a separate git worktree on <run-branch>-maker; "integrate"
# merges that work back into the run branch. "merge" merges the run branch into
# the base branch (the branch the run started from).
#
# Usage:
#   archeflow-git.sh init <run_id>                        Create the run branch and switch to it
#                                                         (resumes an existing run of the same id)
#   archeflow-git.sh worktree <run_id>                    Create the Maker worktree, print its path
#   archeflow-git.sh integrate <run_id>                   Merge the Maker's commits into the run branch
#   archeflow-git.sh commit <run_id> <phase> <msg> [files...]  Stage run artifacts (+files) and commit
#   archeflow-git.sh phase-commit <run_id> <phase>        Commit all artifacts of a phase
#   archeflow-git.sh merge <run_id> [--squash|--no-ff|--rebase]  Merge the run branch into its base
#   archeflow-git.sh rollback <run_id> --to <phase> [--yes]      Reset the run branch to a phase boundary
#   archeflow-git.sh status <run_id>                      Show branch status
#   archeflow-git.sh cleanup <run_id> [--yes]             Delete run branch and metadata after merge
#
# Configuration (.archeflow/config.yaml, keys under "git:"; a top-level key is
# accepted as a fallback): branch_prefix, commit_style, merge_strategy
# (default no-ff), auto_push, signing_key.
#
# Never prompts when stdin is not a terminal: destructive operations need --yes.
# No force-push, and the base branch's history is never rewritten.
#
# ArcheFlow's own configuration never travels through a run:
#   - init records test_command (runs/<run_id>/test-command) and a fingerprint of
#     the trusted configuration (config.yaml, hooks.yaml, lenses/, lessons, ...)
#     in runs/<run_id>/trusted-config;
#   - integrate refuses Maker commits that touch .archeflow/ (reviewers never see
#     those paths, and they would change what runs after the merge);
#   - merge refuses when the run branch changes anything under .archeflow/ other
#     than this run's own artifacts and event log, or when the trusted
#     configuration in the working tree changed since init.
# Every command refuses to run when .archeflow/ or one of its state directories
# is a symlink.

set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # read by die() in archeflow-common.sh
AF_LOG_PREFIX="archeflow-git"
# shellcheck source=lib/archeflow-common.sh
source "${SCRIPT_DIR}/archeflow-common.sh"

ARCHEFLOW_DIR=".archeflow"
CONFIG_FILE="${ARCHEFLOW_DIR}/config.yaml"

# Defaults (overridden by config if present)
BRANCH_PREFIX="archeflow/"
COMMIT_STYLE="conventional"    # conventional | simple
MERGE_STRATEGY="no-ff"         # no-ff | squash | rebase
AUTO_PUSH="false"
SIGNING_KEY=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info() {
  echo "[archeflow-git] $*" >&2
}

usage() {
  sed -n '9,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

# yaml_get <file> <key> [default]
# Value of <key> inside the top-level "git:" block, else of a top-level <key>.
# Nested keys elsewhere (e.g. variables.signing_key) are never matched.
# Strips trailing comments and surrounding quotes. POSIX awk only.
yaml_get() {
  local file="$1" key="$2" default="${3:-}" val=""
  if [[ -f "$file" ]]; then
    val=$(awk -v k="$key" '
      function clean(s) {
        sub(/^[[:space:]]+/, "", s)
        sub(/[[:space:]]+#.*$/, "", s)
        sub(/[[:space:]]+$/, "", s)
        if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2)
        return s
      }
      /^[^[:space:]#]/ { in_git = ($0 ~ /^git:[[:space:]]*(#.*)?$/) }
      {
        if (in_git && !g && match($0, "^[[:space:]]+" k ":")) { gv = clean(substr($0, RLENGTH + 1)); g = 1 }
        else if (!t && match($0, "^" k ":")) { tv = clean(substr($0, RLENGTH + 1)); t = 1 }
      }
      END { if (g) print gv; else if (t) print tv }
    ' "$file" 2>/dev/null) || val=""
  fi
  if [[ -n "$val" && "$val" != "null" && "$val" != "~" ]]; then
    printf '%s\n' "$val"
  else
    printf '%s\n' "$default"
  fi
}

# Branch prefix: a plain ref-name prefix. A leading "+" would turn
# "git push origin <branch>" into a forced push, a leading "-" into an option.
valid_prefix() {
  local p="$1"
  [[ "$p" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$p" != *..* && "$p" != *//* ]] || return 1
  git check-ref-format --branch "${p}x" >/dev/null 2>&1
}

# A branch name read from a file (base-branch) or config must be a valid,
# non-option ref name before it reaches git.
valid_branch() {
  local b="$1"
  [[ -n "$b" && "$b" != -* && "$b" != +* ]] || return 1
  git check-ref-format --branch "$b" >/dev/null 2>&1
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    BRANCH_PREFIX=$(yaml_get "$CONFIG_FILE" "branch_prefix" "$BRANCH_PREFIX")
    COMMIT_STYLE=$(yaml_get "$CONFIG_FILE" "commit_style" "$COMMIT_STYLE")
    MERGE_STRATEGY=$(yaml_get "$CONFIG_FILE" "merge_strategy" "$MERGE_STRATEGY")
    AUTO_PUSH=$(yaml_get "$CONFIG_FILE" "auto_push" "$AUTO_PUSH")
    SIGNING_KEY=$(yaml_get "$CONFIG_FILE" "signing_key" "$SIGNING_KEY")
  fi
  valid_prefix "$BRANCH_PREFIX" \
    || die "Invalid git.branch_prefix '${BRANCH_PREFIX}' (allowed: letters, digits, '.', '_', '/', '-'; must start with a letter or digit)."
  MERGE_STRATEGY="${MERGE_STRATEGY#--}"
}

branch_name() {
  echo "${BRANCH_PREFIX}${1}"
}

maker_branch_name() {
  echo "${BRANCH_PREFIX}${1}-maker"
}

branch_exists() {
  git show-ref --verify --quiet "refs/heads/$1" 2>/dev/null
}

# Base branch: recorded in .archeflow/runs/<run_id>/base-branch during init,
# else the repository default branch.
get_base_branch() {
  local run_id="$1" base=""
  local base_file="${ARCHEFLOW_DIR}/runs/${run_id}/base-branch"
  if [[ -f "$base_file" ]]; then
    base=$(head -1 "$base_file")
  else
    base=$(af_default_branch)
  fi
  valid_branch "$base" || die "Invalid base branch '${base}' (from ${base_file})."
  echo "$base"
}

# Run a git command with SSH commit signing when signing_key is configured.
# The key is passed as ONE argv element: string-splitting (git $sign_args ...)
# would let a crafted signing_key in a cloned repo's config inject extra "-c"
# options (e.g. core.fsmonitor=<cmd>, i.e. code execution).
git_signed() {
  if [[ -n "$SIGNING_KEY" ]]; then
    git -c "user.signingkey=${SIGNING_KEY}" -c gpg.format=ssh -c commit.gpgsign=true "$@"
  else
    git "$@"
  fi
}

assert_on_branch() {
  local expected="$1" current
  current=$(git branch --show-current 2>/dev/null || true)
  if [[ "$current" != "$expected" ]]; then
    die "Expected to be on branch '${expected}', but on '${current}'"
  fi
}

# Uncommitted changes to tracked files (untracked files, such as the run's own
# .archeflow/ state, do not count).
has_uncommitted_changes() {
  local dir="${1:-.}"
  ! git -C "$dir" diff --quiet 2>/dev/null || ! git -C "$dir" diff --cached --quiet 2>/dev/null
}

format_message() {
  local phase="$1" msg="$2"
  if [[ "$COMMIT_STYLE" == "simple" ]]; then
    echo "${phase}: ${msg}"
  else
    echo "archeflow(${phase}): ${msg}"
  fi
}

# Push if auto_push is enabled. Explicit refspec: never a forced push.
maybe_push() {
  local branch="$1"
  if [[ "$AUTO_PUSH" == "true" ]]; then
    info "Pushing ${branch} to remote..."
    git push origin "refs/heads/${branch}:refs/heads/${branch}" 2>/dev/null \
      || info "Push failed (non-fatal, remote may not exist)"
  fi
}

# Destructive confirmation: --yes, or an interactive "yes" on a terminal.
# In a non-TTY agent session without --yes this refuses instead of hanging.
confirm() {
  local assume_yes="$1" prompt="$2"
  [[ "$assume_yes" == "true" ]] && return 0
  if [[ ! -t 0 ]]; then
    info "${prompt} Re-run with --yes to confirm (no terminal to ask on)."
    return 1
  fi
  echo "${prompt} Type 'yes' to confirm:" >&2
  local answer=""
  read -r answer || true
  [[ "$answer" == "yes" ]]
}

worktree_path() {
  local root
  root=$(git rev-parse --show-toplevel)
  echo "${root}/${ARCHEFLOW_DIR}/worktrees/${1}"
}

# Path of the worktree that has <branch> checked out, if any.
worktree_of_branch() {
  local want="refs/heads/$1"
  git worktree list --porcelain 2>/dev/null | awk -v want="$want" '
    /^worktree / { path = substr($0, 10) }
    /^branch /   { if (substr($0, 8) == want) { print path; exit } }
  '
}

# True if every change of <branch> is already in <base>: <branch> is an
# ancestor of <base> (no-ff, rebase) or its combined patch is in <base> (squash).
is_merged_into() {
  local branch="$1" base="$2" mb tmp
  git merge-base --is-ancestor "$branch" "$base" 2>/dev/null && return 0
  mb=$(git merge-base "$base" "$branch" 2>/dev/null) || return 1
  tmp=$(git commit-tree "${branch}^{tree}" -p "$mb" -m "archeflow merged-check" 2>/dev/null) || return 1
  [[ "$(git cherry "$base" "$tmp" 2>/dev/null)" == -* ]]
}


# Trusted configuration: files under .archeflow/ that decide what runs (test
# command, hooks, auto_merge), what agents are told (lenses, lessons, roles) or
# how the run is shaped. Fingerprinted at init, verified before merge.
TRUSTED_PATHS=(config.yaml hooks.yaml lenses memory/lessons.jsonl archetypes domains teams patterns workflows multi-run.yaml queue.md)

# One line per trusted file: "<blob-id>  <path>" (a symlink: "symlink:<target>  <path>").
trusted_fingerprint() {
  local p f
  for p in "${TRUSTED_PATHS[@]}"; do
    f="${ARCHEFLOW_DIR}/${p}"
    if [[ -L "$f" ]]; then
      printf 'symlink:%s  %s\n' "$(readlink -- "$f")" "$f"
    elif [[ -f "$f" ]]; then
      printf '%s  %s\n' "$(git hash-object --no-filters -- "$f")" "$f"
    elif [[ -d "$f" ]]; then
      while IFS= read -r -d '' f; do
        if [[ -L "$f" ]]; then
          printf 'symlink:%s  %s\n' "$(readlink -- "$f")" "$f"
        else
          printf '%s  %s\n' "$(git hash-object --no-filters -- "$f")" "$f"
        fi
      done < <(find "$f" \( -type f -o -type l \) -print0 | LC_ALL=C sort -z)
    fi
  done
}

# Paths (NUL-separated input) under .archeflow/, matched case-insensitively
# (".ARCHEFLOW/x" is the same directory on macOS and Windows). Prints one per line.
# <allow-prefix>... : exact-case paths that are allowed and not printed.
archeflow_paths() {
  local path a allowed
  while IFS= read -r -d '' path; do
    shopt -s nocasematch
    if [[ "$path" == .archeflow || "$path" == .archeflow/* ]]; then
      shopt -u nocasematch
      allowed=0
      for a in "$@"; do
        [[ "$path" == "$a" || ( "$a" == */ && "$path" == "$a"* ) ]] && { allowed=1; break; }
      done
      [[ "$allowed" -eq 1 ]] || printf '%s\n' "$path"
    fi
    shopt -u nocasematch
  done
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_init() {
  local run_id="$1" branch current_branch
  branch=$(branch_name "$run_id")

  current_branch=$(git branch --show-current 2>/dev/null || true)
  [[ -n "$current_branch" ]] || die "Detached HEAD: check out the base branch before starting a run."

  # Resume (--dry-run, then --start-from): the run branch exists and this
  # run's metadata says it was created by "init <run_id>". Switch to it (if the
  # tree is clean) and keep the records from the first init: the test command
  # and configuration fingerprint are the ones from the run's start.
  if branch_exists "$branch"; then
    local base_file="${ARCHEFLOW_DIR}/runs/${run_id}/base-branch"
    if [[ -f "$base_file" && ! -L "$base_file" ]]; then
      if [[ "$current_branch" != "$branch" ]]; then
        has_uncommitted_changes && die "Uncommitted changes in tracked files. Commit or stash them before resuming run ${run_id}."
        git checkout --quiet "$branch" --
      fi
      info "Resuming run ${run_id} on existing branch ${branch} (base: $(get_base_branch "$run_id"))"
      return 0
    fi
    die "Branch '${branch}' already exists but has no run metadata (${base_file}). Use a different run_id or clean up first."
  fi

  # Refuse instead of stashing: a silent stash is never restored and looks like data loss.
  if has_uncommitted_changes; then
    die "Uncommitted changes in tracked files. Commit or stash them before starting a run."
  fi

  git checkout --quiet -b "$branch"
  info "Created and switched to branch: ${branch}"

  local run_dir="${ARCHEFLOW_DIR}/runs/${run_id}"
  mkdir -p "$run_dir"
  af_refuse_symlink "${run_dir}/base-branch" && af_refuse_symlink "${run_dir}/test-command" \
    && af_refuse_symlink "${run_dir}/trusted-config" || die "Refusing to write run metadata."
  echo "$current_branch" > "${run_dir}/base-branch"
  # The test command the user sees and confirms for this run; archeflow-rollback.sh
  # runs this recorded value and refuses if the config says something else later.
  af_config_test_command > "${run_dir}/test-command" 2>/dev/null || : > "${run_dir}/test-command"
  trusted_fingerprint > "${run_dir}/trusted-config"

  maybe_push "$branch"
  info "Init complete for run: ${run_id} (base: ${current_branch})"
}

# Create the Maker's worktree on <run-branch>-maker, branched from the run
# branch, under .archeflow/worktrees/<run_id>. Prints the absolute path.
# Idempotent: if the worktree already exists it prints the path again.
cmd_worktree() {
  local run_id="$1" branch wt_branch path existing
  branch=$(branch_name "$run_id")
  wt_branch=$(maker_branch_name "$run_id")
  path=$(worktree_path "$run_id")

  branch_exists "$branch" || die "Run branch '${branch}' does not exist. Run 'init ${run_id}' first."

  existing=$(worktree_of_branch "$wt_branch")
  if [[ -n "$existing" ]]; then
    info "Maker worktree already exists: ${existing}"
    echo "$existing"
    return 0
  fi
  if branch_exists "$wt_branch"; then
    die "Branch '${wt_branch}' exists without a worktree. Integrate or delete it first."
  fi
  [[ ! -e "$path" ]] || die "Path '${path}' already exists and is not the Maker worktree."

  mkdir -p "$(dirname "$path")"
  # Keep the worktrees directory out of the user's git status and commits.
  if [[ ! -e "$(dirname "$path")/.gitignore" && ! -L "$(dirname "$path")/.gitignore" ]]; then
    printf '*\n' > "$(dirname "$path")/.gitignore"
  fi

  git worktree add --quiet -b "$wt_branch" "$path" "$branch" >/dev/null
  info "Maker worktree: ${path} (branch ${wt_branch})"
  echo "$path"
}

# Merge the Maker's commits into the run branch (--no-ff), write the run's
# cumulative diff against the base branch to .archeflow/artifacts/<run_id>/
# do-maker.diff and the changed paths to do-maker-files.txt, then remove the
# worktree and the Maker branch.
cmd_integrate() {
  local run_id="$1" branch wt_branch path base ahead art
  branch=$(branch_name "$run_id")
  wt_branch=$(maker_branch_name "$run_id")
  assert_on_branch "$branch"
  has_uncommitted_changes && die "Uncommitted changes on '${branch}'. Commit or stash them first."

  branch_exists "$wt_branch" || die "No Maker branch '${wt_branch}'. Run 'worktree ${run_id}' and let the Maker commit there."

  path=$(worktree_of_branch "$wt_branch")
  if [[ -n "$path" ]]; then
    if has_uncommitted_changes "$path"; then
      die "The Maker left uncommitted changes to tracked files in ${path}. Commit them there (or discard them), then re-run integrate."
    fi
    local untracked
    untracked=$(git -C "$path" ls-files --others --exclude-standard 2>/dev/null | head -10)
    if [[ -n "$untracked" ]]; then
      die "Untracked files in ${path}: $(tr '\n' ' ' <<<"$untracked")-- commit the ones that belong to the change, delete generated ones (caches, build output), then re-run integrate."
    fi
  fi

  ahead=$(git rev-list --count "${branch}..${wt_branch}")
  if [[ "$ahead" == "0" ]]; then
    die "The Maker made no commits on '${wt_branch}'. Nothing to integrate (worktree kept: ${path:-none})."
  fi

  # The Maker never changes ArcheFlow's own files: the review diff excludes
  # .archeflow/, and config, hooks, lenses and lessons there decide what runs
  # after the merge and what later runs are told.
  local touched
  touched=$(git diff -z --name-only --no-renames "${branch}...${wt_branch}" -- | archeflow_paths)
  if [[ -n "$touched" ]]; then
    die "The Maker's commits change ArcheFlow's own files, which reviewers never see and which are never merged: $(tr '\n' ' ' <<<"$touched")-- nothing was integrated. Inspect branch '${wt_branch}' and drop those changes (or discard the Maker's work) before integrating."
  fi

  if ! git_signed merge --quiet --no-ff --no-edit \
       -m "$(format_message "do" "integrate maker work (${ahead} commits)")" \
       --end-of-options "$wt_branch"; then
    git merge --abort 2>/dev/null || true
    die "Merging '${wt_branch}' into '${branch}' hit conflicts; aborted. The Maker branch and worktree are intact."
  fi

  base=$(get_base_branch "$run_id")
  art="${ARCHEFLOW_DIR}/artifacts/${run_id}"
  mkdir -p "$art"
  af_refuse_symlink "${art}/do-maker.diff" && af_refuse_symlink "${art}/do-maker-files.txt" \
    || die "Refusing to write the Maker diff through a symlink."
  git diff "${base}...HEAD" -- . ":(exclude)${ARCHEFLOW_DIR}" > "${art}/do-maker.diff"
  git diff --name-only "${base}...HEAD" -- . ":(exclude)${ARCHEFLOW_DIR}" > "${art}/do-maker-files.txt"

  if [[ -n "$path" ]]; then
    git worktree remove "$path" 2>/dev/null || info "Could not remove worktree ${path}; remove it with 'git worktree remove'."
  fi
  git branch --quiet -d "$wt_branch" 2>/dev/null || info "Could not delete branch ${wt_branch}."

  info "Integrated ${ahead} Maker commit(s) into ${branch}. Diff: ${art}/do-maker.diff"
  maybe_push "$branch"
}

cmd_commit() {
  [[ $# -ge 3 ]] || die "Usage: commit <run_id> <phase> <msg> [files...]"
  local run_id="$1" phase="$2" msg="$3"
  shift 3
  local extra_files=("$@")

  local branch
  branch=$(branch_name "$run_id")
  assert_on_branch "$branch"

  local artifact_dir="${ARCHEFLOW_DIR}/artifacts/${run_id}"
  [[ -d "$artifact_dir" ]] && { git add -- "$artifact_dir" 2>/dev/null || true; }

  local event_file="${ARCHEFLOW_DIR}/events/${run_id}.jsonl"
  [[ -f "$event_file" ]] && { git add -- "$event_file" 2>/dev/null || true; }

  local f
  for f in "${extra_files[@]}"; do
    if [[ -e "$f" ]]; then
      git add -- "$f" 2>/dev/null || true
    else
      info "Warning: file '${f}' does not exist, skipping"
    fi
  done

  if git diff --cached --quiet 2>/dev/null; then
    info "Nothing to commit for ${phase}: ${msg}"
    return 0
  fi

  local commit_msg
  commit_msg=$(format_message "$phase" "$msg")
  git_signed commit -m "$commit_msg" --quiet

  info "Committed: ${commit_msg}"
  maybe_push "$branch"
}

cmd_phase_commit() {
  [[ $# -ge 2 ]] || die "Usage: phase-commit <run_id> <phase>"
  local run_id="$1" phase="$2"

  local branch
  branch=$(branch_name "$run_id")
  assert_on_branch "$branch"

  local artifact_dir="${ARCHEFLOW_DIR}/artifacts/${run_id}"

  local next_phase=""
  case "$phase" in
    plan)  next_phase="do" ;;
    do)    next_phase="check" ;;
    check) next_phase="act" ;;
    act)   next_phase="complete" ;;
    *)     next_phase="next" ;;
  esac

  if [[ -d "$artifact_dir" ]]; then
    local f
    for f in "${artifact_dir}/${phase}-"*; do
      if [[ -e "$f" ]]; then git add -- "$f" 2>/dev/null || true; fi
    done
  fi

  local event_file="${ARCHEFLOW_DIR}/events/${run_id}.jsonl"
  [[ -f "$event_file" ]] && { git add -- "$event_file" 2>/dev/null || true; }

  if git diff --cached --quiet 2>/dev/null; then
    info "Nothing to commit for phase transition: ${phase}→${next_phase}"
    return 0
  fi

  local commit_msg
  commit_msg=$(format_message "${phase}→${next_phase}" "phase transition")
  git_signed commit -m "$commit_msg" --quiet

  info "Committed phase transition: ${phase} → ${next_phase}"
  maybe_push "$branch"
}

cmd_merge() {
  local run_id="$1"
  local strategy="${2:-$MERGE_STRATEGY}"
  strategy="${strategy#--}"

  case "$strategy" in
    squash|no-ff|rebase) ;;
    *) die "Unknown merge strategy: ${strategy}. Use --no-ff, --squash, or --rebase." ;;
  esac

  local branch wt_branch
  branch=$(branch_name "$run_id")
  wt_branch=$(maker_branch_name "$run_id")

  # Merge from the run branch only: this is what makes the base branch and the
  # merged content unambiguous.
  assert_on_branch "$branch"

  if has_uncommitted_changes; then
    die "Uncommitted changes on branch '${branch}'. Commit or stash before merging."
  fi

  if branch_exists "$wt_branch" && [[ "$(git rev-list --count "${branch}..${wt_branch}")" != "0" ]]; then
    die "The Maker branch '${wt_branch}' has commits that are not integrated. Run 'integrate ${run_id}' first."
  fi

  local base_branch
  base_branch=$(get_base_branch "$run_id")
  branch_exists "$base_branch" || die "Base branch '${base_branch}' does not exist."

  # A second merge after a revert would be a silent no-op ("Already up to date").
  if git merge-base --is-ancestor "$branch" "$base_branch" 2>/dev/null; then
    die "'${branch}' has no commits that are not already in '${base_branch}' (already merged, or no changes). Nothing to merge."
  fi

  # Nothing under .archeflow/ reaches the base branch except this run's own
  # artifacts and event log (committed by 'commit'/'phase-commit').
  local touched
  touched=$(git diff -z --name-only --no-renames "${base_branch}...${branch}" -- \
    | archeflow_paths "${ARCHEFLOW_DIR}/artifacts/${run_id}/" "${ARCHEFLOW_DIR}/events/${run_id}.jsonl")
  if [[ -n "$touched" ]]; then
    die "'${branch}' changes ArcheFlow's own files: $(tr '\n' ' ' <<<"$touched")-- refusing to merge them into '${base_branch}'. Remove those changes from the run branch, then merge."
  fi

  # The configuration the run started with (test_command, hooks, auto_merge,
  # lenses, lessons) must still be in place: an agent could have rewritten it
  # in the working tree during the run.
  local fp_file="${ARCHEFLOW_DIR}/runs/${run_id}/trusted-config" changed
  if [[ -f "$fp_file" ]]; then
    changed=$(diff <(cat "$fp_file") <(trusted_fingerprint) | sed -n 's/^[<>] [^ ]*  //p' | sort -u || true)
    if [[ -n "$changed" ]]; then
      die "ArcheFlow configuration changed since the run started: $(tr '\n' ' ' <<<"$changed")-- refusing to merge. Review the change; if you made it, start a new run."
    fi
  else
    info "Warning: no configuration fingerprint for run ${run_id} (started by an older version); not verified."
  fi

  local commit_msg="archeflow: merge run ${run_id}"

  # rebase: replay the RUN branch onto base (while still on the run branch),
  # then fast-forward base. Base history is never rewritten.
  if [[ "$strategy" == "rebase" ]]; then
    if ! git_signed rebase --quiet --end-of-options "$base_branch"; then
      git rebase --abort 2>/dev/null || true
      die "Rebase of '${branch}' onto '${base_branch}' hit conflicts; aborted. Resolve manually or use --no-ff."
    fi
  fi

  git checkout --quiet "$base_branch" --
  info "Switched to base branch: ${base_branch}"

  case "$strategy" in
    squash)
      if ! git merge --quiet --squash --end-of-options "$branch"; then
        git reset --quiet --merge 2>/dev/null || true
        git checkout --quiet "$branch" --
        die "Squash merge of '${branch}' into '${base_branch}' hit conflicts; aborted. Back on '${branch}'."
      fi
      if ! git diff --cached --quiet 2>/dev/null; then
        git_signed commit -m "$commit_msg" --quiet
        info "Squash-merged ${branch} into ${base_branch}"
      else
        info "No changes to merge (branch identical to base)"
      fi
      ;;
    no-ff)
      if ! git_signed merge --quiet --no-ff -m "$commit_msg" --end-of-options "$branch"; then
        git merge --abort 2>/dev/null || true
        git checkout --quiet "$branch" --
        die "Merge of '${branch}' into '${base_branch}' hit conflicts; aborted. Back on '${branch}'."
      fi
      info "Merged ${branch} into ${base_branch} (no-ff)"
      ;;
    rebase)
      git merge --quiet --ff-only --end-of-options "$branch" \
        || die "Fast-forward of '${base_branch}' to '${branch}' failed."
      info "Rebased ${branch} onto ${base_branch} and fast-forwarded ${base_branch}"
      ;;
  esac

  info "Merge complete. Branch '${branch}' preserved for inspection."
  info "Run 'archeflow-git.sh cleanup ${run_id}' to delete the branch."
}

cmd_rollback() {
  local run_id="$1"
  shift

  local target_phase="" assume_yes="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)  [[ $# -ge 2 ]] || die "Missing value for --to"; target_phase="$2"; shift 2 ;;
      --yes) assume_yes="true"; shift ;;
      *) die "Unknown option: $1. Usage: rollback <run_id> --to <phase> [--yes]" ;;
    esac
  done

  [[ -n "$target_phase" ]] || die "Missing --to <phase>. Usage: rollback <run_id> --to <phase> [--yes]"

  local branch
  branch=$(branch_name "$run_id")
  assert_on_branch "$branch"

  local search_pattern
  case "$target_phase" in
    cycle-*) search_pattern="cycle ${target_phase#cycle-}" ;;
    *)
      search_pattern="archeflow(${target_phase}"
      [[ "$COMMIT_STYLE" == "simple" ]] && search_pattern="${target_phase}:"
      ;;
  esac

  local target_commit
  target_commit=$(git log --format="%H %s" "$branch" | grep -F -- "$search_pattern" | head -1 | awk '{print $1}')
  [[ -n "$target_commit" ]] || die "No commit found for phase '${target_phase}' on branch '${branch}'."

  local target_short commits_after
  target_short=$(git log --oneline -1 "$target_commit")
  commits_after=$(git log --oneline "${target_commit}..HEAD")

  if [[ -z "$commits_after" ]]; then
    info "Already at the target commit. Nothing to roll back."
    return 0
  fi

  {
    echo ""
    echo "Rolling back to: ${target_short}"
    echo ""
    echo "The following commits will be removed from ${branch}:"
    printf '%s\n' "$commits_after" | sed 's/^/  /'
    echo ""
  } >&2

  if ! confirm "$assume_yes" "This is destructive on the run branch."; then
    info "Rollback cancelled."
    return 1
  fi

  git reset --hard "$target_commit" --quiet
  info "Reset to: ${target_short}"

  # Trim the events JSONL to the rollback point (events with ts <= commit time).
  local event_file="${ARCHEFLOW_DIR}/events/${run_id}.jsonl"
  if [[ -f "$event_file" ]]; then
    local commit_ts tmp_file
    commit_ts=$(git log -1 --format="%aI" "$target_commit")
    tmp_file=$(af_tmpfile "$event_file")
    jq -c --arg ts "$commit_ts" 'select(.ts <= $ts)' "$event_file" > "$tmp_file" 2>/dev/null || true
    if [[ -s "$tmp_file" ]]; then
      mv "$tmp_file" "$event_file"
      info "Trimmed events JSONL to match rollback point"
    else
      rm -f "$tmp_file"
      info "Warning: could not trim events JSONL (file may need manual cleanup)"
    fi
  fi

  info "Rollback complete. You are now at the end of the '${target_phase}' phase."
}

cmd_status() {
  local run_id="$1" branch
  branch=$(branch_name "$run_id")

  branch_exists "$branch" || die "Branch '${branch}' does not exist."

  local base_branch ahead
  base_branch=$(get_base_branch "$run_id")
  ahead=$(git rev-list --count "${base_branch}..${branch}" 2>/dev/null || echo "?")

  echo "Branch: ${branch}"
  echo "Base: ${base_branch} (${ahead} commits ahead)"
  echo ""
  echo "Commits:"
  git log --oneline "${base_branch}..${branch}" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
  echo ""

  local latest_msg current_phase="unknown"
  latest_msg=$(git log -1 --format="%s" "$branch" 2>/dev/null || echo "")
  local re_conv='archeflow\(([^)]+)\)'
  local re_simple='^([a-z]+):'
  if [[ "$latest_msg" =~ $re_conv ]]; then
    current_phase="${BASH_REMATCH[1]}"
  elif [[ "$latest_msg" =~ $re_simple ]]; then
    current_phase="${BASH_REMATCH[1]}"
  fi
  echo "Current phase: ${current_phase}"

  local files_changed
  files_changed=$(git diff --name-only "${base_branch}...${branch}" 2>/dev/null | wc -l | tr -d ' ')
  echo "Files changed (total): ${files_changed}"

  local wt
  wt=$(worktree_of_branch "$(maker_branch_name "$run_id")")
  [[ -n "$wt" ]] && echo "Maker worktree: ${wt}"

  local current
  current=$(git branch --show-current 2>/dev/null || true)
  if [[ "$current" == "$branch" ]]; then
    if has_uncommitted_changes; then
      echo "Uncommitted changes: YES"
    else
      echo "Uncommitted changes: none"
    fi
  else
    echo "Uncommitted changes: (not on branch, cannot check)"
  fi
}

cmd_cleanup() {
  local run_id="$1"
  shift
  local assume_yes="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) assume_yes="true"; shift ;;
      *) die "Unknown option: $1. Usage: cleanup <run_id> [--yes]" ;;
    esac
  done

  local branch wt_branch current
  branch=$(branch_name "$run_id")
  wt_branch=$(maker_branch_name "$run_id")

  current=$(git branch --show-current 2>/dev/null || true)
  if [[ "$current" == "$branch" ]]; then
    die "Cannot delete branch '${branch}' while on it. Switch to another branch first."
  fi

  branch_exists "$branch" || die "Branch '${branch}' does not exist."

  local base_branch
  base_branch=$(get_base_branch "$run_id")

  if is_merged_into "$branch" "$base_branch"; then
    git branch --quiet -D "$branch"
  else
    if ! confirm "$assume_yes" "Branch '${branch}' is not merged into '${base_branch}'; deleting it loses its commits."; then
      info "Cleanup cancelled."
      return 1
    fi
    git branch --quiet -D "$branch"
  fi
  info "Deleted branch: ${branch}"

  # Leftover Maker worktree/branch (e.g. an aborted cycle).
  local wt
  wt=$(worktree_of_branch "$wt_branch")
  if [[ -n "$wt" ]]; then
    git worktree remove "$wt" 2>/dev/null \
      || info "Maker worktree ${wt} has changes; left in place (remove with 'git worktree remove --force')."
  fi
  if branch_exists "$wt_branch" && [[ -z "$(worktree_of_branch "$wt_branch")" ]]; then
    git branch --quiet -D "$wt_branch" 2>/dev/null || true
  fi

  af_refuse_symlink "${ARCHEFLOW_DIR}/runs/${run_id}" || die "Refusing to delete run metadata through a symlink."
  rm -rf "${ARCHEFLOW_DIR}/runs/${run_id}"
  info "Cleaned up run metadata for: ${run_id}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
  esac
  if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <command> <run_id> [args...]" >&2
    echo "" >&2
    echo "Commands:" >&2
    usage
    exit 1
  fi

  local cmd="$1"
  local run_id="$2"
  shift 2
  # Run IDs become file names under .archeflow/ and git branch names.
  af_require_run_id "$run_id"
  # A committed ".archeflow -> elsewhere" (or events/, worktrees/, runs/ ...)
  # would redirect every write and the cleanup's rm -rf.
  af_check_state_dirs "$ARCHEFLOW_DIR"

  load_config

  case "$cmd" in
    init)         cmd_init "$run_id" ;;
    worktree)     cmd_worktree "$run_id" ;;
    integrate)    cmd_integrate "$run_id" ;;
    commit)       cmd_commit "$run_id" "$@" ;;
    phase-commit) cmd_phase_commit "$run_id" "$@" ;;
    merge)        cmd_merge "$run_id" "$@" ;;
    rollback)     cmd_rollback "$run_id" "$@" ;;
    status)       cmd_status "$run_id" ;;
    cleanup)      cmd_cleanup "$run_id" "$@" ;;
    *)            die "Unknown command: ${cmd}" ;;
  esac
}

main "$@"
