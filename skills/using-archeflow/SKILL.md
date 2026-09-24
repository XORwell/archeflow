---
name: using-archeflow
description: Overview of ArcheFlow's commands and when to use which. The session-start hook injects the short version (ACTIVATION.md in this directory).
user-invocable: false
---

# Using ArcheFlow

## Commands

| Command | What it does |
|---------|--------------|
| `/archeflow:review` | Review uncommitted changes, a branch or a commit range with Guardian (plus Skeptic, Sage, Trickster on request). Any git repository, no setup. |
| `/archeflow:run <task>` | Plan, Do, Check, Act for one task on its own branch; merges after approval and your confirmation. Flags: `--workflow`, `--dry-run`, `--start-from`, `--lens`, `--pattern`. |
| `/archeflow:init [bundle]` | Create `.archeflow/` from a bundle (quick-fix, backend-feature, security-review). |
| `/archeflow:sprint` | Work through `docs/orchestra/queue.json` across the repositories of a workspace. |
| `/archeflow:scan` | Propose new queue items and flag stale ones (new items need your approval). |
| `/archeflow:status` | Current or last run, its branch, memory and config. |
| `/archeflow:report [run_id]` | Full process report of a run. |
| `/archeflow:dag [run_id]` | Event DAG of a run. |
| `/archeflow:replay <run_id>` | Decision timeline and weighted what-if. |
| `/archeflow:score` | Usefulness of each reviewer role across runs. |
| `/archeflow:memory` | List, add or forget cross-run lessons. |

## When to use what

| Need | Use |
|------|-----|
| Check work that already exists | `/archeflow:review` |
| Security-sensitive or multi-file change, public API, complex refactor | `/archeflow:run` |
| Clear, small change | do it directly, no orchestration |
| Many queued tasks across repositories | `/archeflow:sprint` |
| Zero cloud tokens | `models.provider: ollama` (see the run skill's `reference.md`) |

## Workflows

| Signal | Workflow | Roles |
|--------|----------|-------|
| small fix, low risk | `fast` | Creator -> Maker -> Guardian |
| feature, several files, moderate risk | `standard` | Explorer + Creator -> Maker -> Guardian + Skeptic + Sage |
| security, breaking change, public API | `thorough` | Explorer + Creator -> Maker -> all four reviewers |

## Without ArcheFlow

For a non-trivial change made directly: restate what you are changing, name one assumption,
and check what it could break.
