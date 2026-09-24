---
name: multi-project
description: |
  Multi-project orchestration for workspaces with 20+ repos. Builds a dependency DAG across
  projects, runs independent sub-runs in parallel, shares artifacts between dependent projects,
  and enforces a shared budget. Each sub-run uses the standard `run` skill internally.
  <example>User: "archeflow:multi-project" with a multi-run.yaml</example>
  <example>User: "Run this across archeflow, writing-tool, and book"</example>
user-invocable: false
---

# Multi-Project Orchestration

Coordinates ArcheFlow runs across multiple projects. Each project gets its own PDCA run (via `run` skill), but dependencies are respected, artifacts shared, and budget tracked globally.

## Multi-Run Definition

Defined in `.archeflow/multi-run.yaml` or passed via `--config`.

```yaml
name: "writing-project-v2"
projects:
  - id: archeflow
    path: "../archeflow"
    task: "Add memory injection to run skill"
    workflow: fast
    depends_on: []
  - id: writing-tool
    path: "../my-writing-tool"
    task: "Add voice validation command"
    depends_on: []
  - id: book
    path: "."
    task: "Write chapter #2"
    workflow: standard
    domain: writing
    depends_on: [archeflow, writing-tool]
budget:
  total_usd: 15.00
  per_project_usd: 10.00
```

**Approval (the file can come with the repository).** Before starting any sub-run, show the user
the whole plan: for every project its `id`, the resolved absolute path, the full `task` text,
workflow and domain, plus the budget. Start nothing without a yes for that plan in this session;
if the file changes, ask again. Refuse a project whose `path` contains characters other than
letters, digits, `.`, `_`, `-` and `/`, or does not resolve to an existing git repository inside
the workspace root. Never type a path or task from the file into a shell command: change
directory with the agent's working-directory setting, or quote the validated absolute path.

**Rules:** Unique `id` per project. `depends_on` references other `id` values. Cycles rejected at validation. At least one project must have empty `depends_on`. `workflow` and `domain` auto-select if omitted.

## Dependency Resolution

Topological sort of the project DAG determines execution order.

```
Layer 0 (immediate): [archeflow, writing-tool] # No deps, start now
Layer 1:             [book]                    # Depends on Layer 0
```

Independent projects in the same layer run in parallel. When a project completes, downstream projects with all deps met move to the ready queue.

Cycle detection via Kahn's algorithm. If sorted list is shorter than project list, report the cycle and abort.

## Parallel Execution

For each ready project of the approved plan, start a sub-run as a parallel subagent that works in that project's directory (the validated absolute path; do not use `isolation: "worktree"`, which would isolate the session's repository, not the project). Each sub-run follows `archeflow:run` with its own run_id, workflow, domain and budget slice; the run creates its own branch and Maker worktree inside the project.

When `parallel: false`, run sequentially in topological order.

## Cross-Project Artifacts

When project B depends on A, B's Explorer receives upstream artifact summaries:
- Only summaries injected (not full artifacts)
- Large artifacts (>200 lines): extract summary section only
- Cross-project injection happens only in Plan phase
- Downstream Explorer has filesystem access to full artifacts if needed

Artifact directory: `.archeflow/artifacts/<MULTI_RUN_ID>/<project_id>/`

## Budget Coordination

| Level | Type | Behavior |
|-------|------|----------|
| `total_usd` | Hard cap | Stops ALL projects when exceeded |
| `per_project_usd` | Soft cap | Warns but continues |

**Enforcement points:**
1. Before starting a sub-run: estimate cost, halt if > remaining budget
2. After each sub-run: update total, emit `budget.warning` at threshold, emit `budget.exceeded` at cap

Each sub-run receives `min(per_project_usd, remaining_total_budget)` as its budget.

## Failure Handling

| Scenario | Action |
|----------|--------|
| Project fails | Mark `failed`. Independent projects continue. |
| Dependency failed | Mark downstream as `blocked`. Do not start. |
| Budget exceeded | Halt current project. Skip downstream. |
| All entry-points fail | Entire multi-run fails. |

**Blocked project resolution:**
- Autonomous mode: skip blocked projects, continue independent ones
- Attended mode: offer skip / retry / abort

## Progress Tracking

Live progress at `.archeflow/multi-progress.md`, updated after every project state change:

```markdown
| Project | Status | Domain | Phase | Detail |
|---------|--------|--------|-------|--------|
| archeflow | completed | code | -- | 1 cycle, $1.20 |
| writing-tool | running | code | DO | maker drafting |
| book | blocked | writing | -- | waiting for writing-tool |

Budget: $3.00 / $15.00 (20%)
```

## Master Events

Written to `.archeflow/events/<MULTI_RUN_ID>.jsonl`:

| Event | When |
|-------|------|
| `multi.start` | Multi-run begins |
| `project.start` | Sub-run launches |
| `project.complete` | Sub-run succeeds |
| `project.failed` | Sub-run fails |
| `project.blocked` | Dependency failed |
| `project.unblocked` | All deps met |
| `budget.warning` | Threshold crossed |
| `budget.exceeded` | Hard cap hit |
| `multi.complete` | All projects done |

## Dry-Run and Resume

**`--dry-run`:** Validates DAG, runs `archeflow:run --dry-run` per project, shows cost estimate. Does not execute.

**`--resume <id>`:** Reconstructs state from master events. Retries failed projects, starts pending ones with deps met.

## Workspace Registry

If the workspace keeps a project registry (e.g. `docs/project-registry.md`): auto-discover paths by project id, validate existence, update registry after meaningful changes.

## Completion

Status values: `completed` (all done), `partial` (some failed/skipped), `failed` (none completed), `halted` (budget/abort).

Final report includes per-project results, cost breakdown by phase, and dependency graph execution timeline.
