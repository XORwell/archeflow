---
name: progress
description: |
  Live progress file for ArcheFlow orchestrations. Regenerates `.archeflow/progress.md`
  after every event emission, giving users real-time visibility into run status, budget
  usage, and DAG shape -- watchable from a second terminal.
  <example>User: "What's happening with my run?"</example>
  <example>watch -n 2 cat .archeflow/progress.md</example>
user-invocable: false
---

# Live Progress -- Real-Time Run Visibility

Maintains `.archeflow/progress.md`, updated after every event during a run.

## Progress File Format

```markdown
# ArcheFlow Run: 2026-04-03-add-auth
**Status:** DO phase -- maker running (3/6 scenes drafted)
**Started:** 14:32 | **Elapsed:** 8 min
**Budget:** $1.45 / $10.00 (14%)

## Progress
- [x] PLAN: Explorer (87s, 21k tok, $0.02)
- [x] PLAN: Creator (167s, 26k tok, $0.08)
- [x] PLAN -> DO transition
- [ ] **DO: Maker** <- running (5 min elapsed)
- [ ] CHECK: Guardian
- [ ] CHECK: Sage
- [ ] ACT: Apply fixes

## Latest Event
#6 agent.start -- maker (do) -- 14:40
```

## Usage

The `run` skill calls `archeflow-progress.sh` after each event emission:
```
<archeflow-root>/lib/archeflow-progress.sh <run_id>
```

**From a second terminal:**
- One-shot: `cat .archeflow/progress.md`
- Continuous: `<archeflow-root>/lib/archeflow-progress.sh <run_id> --watch`
- JSON output: `<archeflow-root>/lib/archeflow-progress.sh <run_id> --json`

## How the Script Works

1. Read `.archeflow/events/<run_id>.jsonl`
2. Determine current phase and active agent
3. Build checklist from events (only started/completed agents shown)
4. Calculate budget from `agent.complete` cost data
5. Write `.archeflow/progress.md`

## Checklist Construction

| Event Type | Entry |
|-----------|-------|
| `agent.complete` | `- [x] PHASE: archetype (duration, tokens, cost)` |
| `agent.start` (no complete) | `- [ ] **PHASE: archetype** <- running` |
| `phase.transition` | `- [x] PHASE -> PHASE transition` |
| `cycle.boundary` | `- [x] Cycle N complete` |

Pending (not-yet-started) agents are NOT shown to avoid guessing.

## Budget Display

Source: `run.start` event or `.archeflow/config.yaml`. If no budget configured: show cost only.
