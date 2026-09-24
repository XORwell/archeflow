---
name: git-integration
description: |
  How an ArcheFlow run uses git: a branch per run, a separate worktree for the Maker, integration back into the run branch, the merge into the base branch, rollback and cleanup. Reference for archeflow-git.sh and its configuration.
user-invocable: false
---

# Git Integration

All git operations of a run go through `<archeflow-root>/lib/archeflow-git.sh`. The script
never prompts without a terminal (destructive operations need `--yes`), never force-pushes, and
never rewrites the base branch's history.

## Branches

```
<base> (the branch the run started from, e.g. main or master)
└── archeflow/<run_id>                 run branch: created by init, merged by merge
    └── archeflow/<run_id>-maker       Maker branch, in .archeflow/worktrees/<run_id>/
                                        (created by worktree, merged back and removed by integrate)
```

## Commands (in the order a run uses them)

| Step | Command | Effect |
|------|---------|--------|
| run start | `init <run_id>` | refuses on uncommitted changes to tracked files (never stashes); creates and switches to the run branch; records the base branch in `.archeflow/runs/<run_id>/base-branch` |
| Do | `worktree <run_id>` | creates the Maker worktree from the run branch, prints its absolute path (idempotent) |
| Do | `integrate <run_id>` | merges the Maker's commits into the run branch (`--no-ff`), writes `do-maker.diff` and `do-maker-files.txt` (diff against the base), removes worktree and Maker branch; refuses if the Maker left uncommitted changes or made no commits |
| merge | `merge <run_id> [--no-ff\|--squash\|--rebase]` | must be run on the run branch; refuses while Maker work is not integrated; merges into the recorded base and leaves you on it; on conflict aborts and returns to the run branch |
| after merge | `cleanup <run_id> [--yes]` | deletes the run branch (squash-merged counts as merged) and `.archeflow/runs/<run_id>/`; an unmerged branch needs `--yes` |
| any time | `status <run_id>` | commits ahead of base, current phase, Maker worktree |
| any time | `rollback <run_id> --to <plan\|do\|check\|act\|cycle-N> [--yes]` | resets the run branch to the last commit of that phase |
| optional | `commit <run_id> <phase> "<msg>" [files]`, `phase-commit <run_id> <phase>` | commit run artifacts on the run branch (see below) |

The merge commit message is always `feat: archeflow run <run_id> complete`;
`archeflow-rollback.sh` reverts only a HEAD commit with exactly that subject.

## Configuration (`.archeflow/config.yaml`)

```yaml
git:
  enabled: true              # false: no branch, no worktree; the Maker edits the working tree
  branch_prefix: "archeflow/"   # letters, digits, . _ / - ; must not start with + or -
  merge_strategy: no-ff      # no-ff (default, revertable merge commit) | squash | rebase
  auto_merge: false          # true: merge without asking once all reviewers approve
  commit_artifacts: false    # true: commit run artifacts on the run branch at each phase
  commit_style: conventional # conventional | simple
  auto_push: false           # push the run branch (explicit refspec, never forced)
  signing_key: null          # SSH key for signed commits
test_command: "npm test"     # top level; run after the merge by archeflow-rollback.sh
```

Keys are read from the `git:` block; a top-level key of the same name is accepted as a
fallback. `enabled`, `auto_merge` and `commit_artifacts` are read by the agent following
`archeflow:run`; the others by the script.

## Merging into the base branch

The run merges only after every reviewer approved, and only with the user's yes unless
`git.auto_merge: true`. The reviewers are language models reviewing code another model wrote;
the confirmation keeps a person in the loop before anything reaches the base branch. After the
merge, `test_command` (if set) runs through `archeflow-rollback.sh <run_id>`: exit 0 pass,
exit 1 failed and the merge commit was reverted, exit 3 failed and nothing was reverted (HEAD was
not this run's merge commit), exit 2 no test command.

## Run state and artifacts

`.archeflow/artifacts/`, `.archeflow/events/`, `.archeflow/runs/` and `.archeflow/worktrees/`
are run state, not source. By default nothing under `.archeflow/` is committed, so a merge brings
only the Maker's changes into the base branch. With `git.commit_artifacts: true` the orchestrator
runs `phase-commit <run_id> <phase>` at each phase boundary for an audit trail in git history;
those files then land in the base branch on merge.

## Safety rules

- Never force-push; never rewrite the base branch.
- A failed run keeps its branch for inspection.
- Merge conflicts are reported, never force-resolved.
- The Maker works only in its worktree; the orchestrator's checkout stays on the run branch.
