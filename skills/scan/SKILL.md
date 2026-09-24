---
name: scan
description: |
  Scan the workspace for new work and stale entries and propose queue changes for docs/orchestra/queue.json. New items are added as "proposed" and are never dispatched without the user's approval. Usage: /archeflow:scan [--dry-run]
  <example>User: "/archeflow:scan"</example>
  <example>User: "/archeflow:scan --dry-run"</example>
---

# Queue Maintenance

Keeps `docs/orchestra/queue.json` fresh by scanning the workspace for actionable work,
removing completed/stale items, and proposing new entries.

## When This Runs

1. **Sprint start (automatic)**: if `last_maintained` in `queue.json` is missing or older than 3 days
2. **Manual**: `/archeflow:scan`, or the user asks to refresh the queue
3. **Sprint end**: After all batches complete, quick scan for newly unblocked work

## Scan Protocol

### Step 1: Inventory Active Projects

**The scan never executes project code.** It reads files and runs read-only git queries, nothing
else: no test suites, builds, package scripts or Makefiles, and no command a project's files
suggest. A project's own `.git/config` can run code on an ordinary `git status`
(`core.fsmonitor`, `core.pager`, ...), so every git command in the scan disables those hooks:

```
git -C <project> -c core.fsmonitor=false -c core.pager=cat -c core.hooksPath=/dev/null --no-optional-locks <command>
```

For each non-archived directory in the workspace root:
- Skip: `docs/`, `scripts/`, `deploy/`, `.claude/`, `node_modules/`, hidden directories, and anything the workspace marks as archived/parked
- Read: `CLAUDE.md`, `docs/status.md`, `README.md` (first 50 lines each)
- Check: `log --oneline -5` (with the git prefix above) for recent activity
- Check: `status --short` (with the git prefix above) for uncommitted work
- Check: `docs/plans/*.md` for documented but unstarted plans

### Step 2: Discover Actionable Work

For each project, identify work signals:

| Signal | Source | Queue Action |
|--------|--------|--------------|
| Documented "Next Action" in status.md | status.md | Propose as new item (`proposed`) |
| Documented "Next Action" in a workspace project registry (if one exists) | registry | Propose as new item |
| Uncommitted changes >1 day old | git status | Propose "review & commit" item |
| Failing CI | a CI result file already in the project (never run the tests yourself) | Propose "fix tests" item |
| TODO/FIXME in recently changed files | git diff + grep | Note in item description |
| Deadline approaching (<14 days) | status.md, CLAUDE.md | Bump priority |
| No activity >30 days | git log | Flag as STALE for review |
| New project not in queue or registry | directory exists | Propose addition |

### Step 3: Compare Against Current Queue

- Match discovered work against existing `queue.json` items by project + task similarity
- **Already tracked**: Skip (don't duplicate)
- **Completed in queue but new work found**: Propose new item
- **In queue but project archived/deleted**: Flag for removal
- **Dependency satisfied**: Check if blocked items can be unblocked

### Step 4: Propose Changes

Output a structured diff of the queue:

```
Queue Maintenance Report (2026-04-11)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

REMOVE (completed/stale):
  - p1-worktree-dispatch: completed 2026-04-01
  - p3-legacy-importer: project archived

ADD (discovered):
  + [P1] docs-site: Fix broken links in chapters 5-7
  + [P2] research-paper: Submit to conference (deadline May 30)

UNBLOCK:
  ~ p2-billing-v2: dependency p0-auth-refactor now satisfiable

UPDATE:
  ↑ research-paper P2→P1: deadline <30 days away

STALE (no activity >30 days):
  ? old-prototype: last commit 2026-03-10

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Step 5: Apply Changes

Everything the scan finds comes from files in the workspace (status logs, CLAUDE.md, READMEs,
TODOs), which anyone who can commit to a project controls. So:

- **New items** are written with `"status": "proposed"` and `"source": "<project>/<file>"`, with
  the discovered text quoted in `task`. They are never `pending`: the sprint dispatches a
  proposed item only after the user approves it in the session. This holds in every mode.
- **Removals** and **priority changes** are shown to the user and applied only after a yes.
- **Unblocking** (a dependency is now `completed`) needs no confirmation: it changes no task text.
- `--dry-run`: show the report, change nothing.
- Then set `last_maintained` to the current UTC time and increment `version` (an integer).
- If the workspace keeps a project registry (e.g. `docs/project-registry.md`), mention touched
  projects in the report; do not edit it.

Write the queue with `jq`, passing every value with `--arg`/`--rawfile`, to a temp file, then
`mv` it over `docs/orchestra/queue.json`.

## Queue Item Discovery Heuristics

### Priority Assignment

| Signal | Default Priority |
|--------|-----------------|
| Tests failing | P1 |
| Uncommitted infra/security changes | P1 |
| Documented deadline <14 days | P1 |
| Documented "next action" in status.md | P2 |
| New project with README but no queue entry | P2 |
| TODO/FIXME accumulation (>5 in recent changes) | P2 |
| Stale project needing archive decision | P3 |
| Nice-to-have feature from docs/plans | P3 |

### Estimate Assignment

| Signal | Estimate |
|--------|----------|
| Single file fix, commit pending changes | S |
| Multi-file but scoped (test fix, config update) | M |
| Feature implementation, multi-module | L |
| Full book/paper writing, major refactor | XL |

### ID Generation

Format: `<project>-<short-kebab-description>`
Example: `docs-site-fix-broken-links-ch5-7`

## Freshness Tracking

Add to `queue.json` root:
```json
{
  "last_maintained": "2026-04-11T08:00:00Z",
  "version": 6
}
```

The sprint checks `last_maintained`. If it is missing or older than 3 days, it runs this scan before dispatching.

## What This Does NOT Do

- Does not execute tasks (that's the sprint runner)
- Does not create PDCA runs (that's `/archeflow:run`)
- Does not auto-archive projects (flags them for user decision)
- Does not read file contents beyond status/config files (keeps scan cheap)
- Does not run expensive operations (no LLM calls)
- Does not execute project code: no tests, builds or scripts, in any project, without asking the user first
