---
name: autonomous-mode
description: Use when the user wants to run ArcheFlow orchestrations unattended -- overnight sessions, batch processing multiple tasks, or fully autonomous coding. Handles self-organization, progress logging, and safe stopping.
user-invocable: false
---

# Autonomous Mode

ArcheFlow runs can work through several tasks without a person watching each step. The quality
gates are LLM reviewers, so two settings stay with the user:

- **Permission mode.** Agents inherit the session's permission mode. The skill never asks for a
  bypass mode; if the user wants fewer prompts, they choose that when starting the session.
- **Merging.** A run merges into the base branch only with the user's yes, or when the user has
  set `git.auto_merge: true` in `.archeflow/config.yaml`. Without either, an unattended run ends
  with status `awaiting_merge` and the reviewed work waits on its branch.

## Task Queue Formats

**Inline:**
```
1. "Fix the login bug" (fast)
2. "Add user profile page" (standard)
```

**From file (`.archeflow/queue.md`):**
```markdown
- [ ] Fix the login bug | fast
- [ ] Add user profile page | standard | depends: fix login
- [ ] Security audit | thorough | done: Guardian approves AND load_test.sh passes
```

Tasks with `depends:` wait for the named task to complete. Tasks with `done:` have completion criteria checked in the Act phase.

## Safety Mechanisms

### Automatic Stop Conditions

- **3 consecutive failures:** Something systemic is wrong
- **Test suite broken:** `archeflow-rollback.sh` reverts the run's merge commit; halt
- **Budget exceeded:** Stop at limit
- **Shadow escalation:** Same shadow detected 3+ times across tasks
- **Destructive action detected:** Force push, branch deletion, schema drop

### Everything is Reversible

- Code lives on run branches until merged (with confirmation or `git.auto_merge: true`)
- Merges are `--no-ff` by default (one revertable merge commit per run)
- Failed tasks leave branches intact for inspection

### User Controls

- **Cancel:** Kill session, incomplete work stays on branches
- **Pause:** Stop after current task, resume later
- **Skip:** Move to next task
- **Review:** Read `.archeflow/session-log.md` for progress

## Session Log

Every session writes to `.archeflow/session-log.md` with per-task entries:
- Workflow, status, cycles, reviewer verdicts
- Files changed, tests added
- Branch and commit info
- Duration and timestamps
- Session summary at the end

## Budget-Aware Scheduling

| Budget Remaining | Action |
|-----------------|--------|
| > 50% | Run at selected workflow level |
| 25-50% | Downgrade thorough to standard, standard to fast |
| < 25% | All tasks as fast only |
| Exhausted | Stop, log remaining as skipped |

## Auto-Resume

On interruption the state is on disk: the event log (`.archeflow/events/<run_id>.jsonl`), the artifacts, and the run branch (`archeflow-git.sh status <run_id>`). On the next session, offer to resume with `/archeflow:run --start-from <phase>` or to start fresh.
