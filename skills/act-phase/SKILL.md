---
name: act-phase
description: |
  Act phase of an ArcheFlow run: consolidate findings, route them to Creator or Maker, decide merge / cycle back / stop, write act-feedback.md.
user-invocable: false
---

# Act Phase

Turn the Check output into a decision. Act never edits code: every fix goes through the next
cycle and is reviewed again. The commands around these steps are in `archeflow:run`, step 4.

## Step 1: Consolidate

Read this cycle's `check-*.md`; findings the evidence gate downgraded read INFO there and count as
INFO. **Deduplicate:** same file + same category + similar description = one finding with the
higher severity, crediting all sources. **Cycle 2+:** compare with `findings-cycle-<N-1>.json`:
resolved (gone), persisting (same id, `cycles_open` + 1), new (`cycles_open: 1`); emit
`fix.applied` for each finding a previous fix resolved.

Write `.archeflow/artifacts/<run_id>/findings-cycle-<N>.json`, an array of

```json
{"id": "src/auth/handler.ts:security", "file": "src/auth/handler.ts", "line": 48,
 "category": "security", "severity": "CRITICAL", "source": ["guardian"],
 "description": "Empty string bypasses validation", "routes_to": "creator", "cycles_open": 1}
```

`id` = `<file>:<category>` (`:<n>` for a second distinct finding there). Keep ids stable across
cycles: convergence and the Wiggum Break check compare them.

## Step 2: Route

| Source | Category | Routes to |
|--------|----------|-----------|
| Guardian | security, breaking-change, reliability, dependency | Creator |
| Skeptic | design, scalability | Creator |
| Sage | quality, consistency, testing | Maker |
| Trickster | reliability (design flaw) | Creator |
| Trickster | reliability (test gap), testing | Maker |

A fix that changes the approach goes to the Creator; one within the approach to the Maker. When
merged sources disagree, the Creator wins.

## Step 3: Decide

First match wins. The last two columns are the `cycle.boundary` values.

| Condition | Decision | `exit_condition` | `decision` |
|-----------|----------|------------------|------------|
| Wiggum Break (hard, or soft at the end of this step) | stop, keep the branch, report | `wiggum_break` | `stop` |
| Same CRITICAL open 2+ consecutive cycles | ask the user how to proceed | `escalated` | `escalate` |
| `fast` and Guardian found 2+ CRITICAL | next cycle runs as `standard` (Skeptic + Sage, no fast path) and stays escalated | `escalated` | `cycle_back` |
| 0 CRITICAL and every reviewer APPROVED | merge (`archeflow:run`, Merge) | `approved` | `merge` |
| Findings left, cycles left | cycle back (Step 4) | `findings_open` | `cycle_back` |
| Findings left, no cycles left | stop, report open findings, keep the branch | `max_cycles` | `stop` |

WARNING and INFO alone never block a merge; list them in the report.

## Step 4: Feedback

Write `.archeflow/artifacts/<run_id>/act-feedback.md`; each section goes only to its agent
(Creator at Plan, Maker at Do). Keep it under ~500 tokens: drop INFO first, then summarise
WARNINGs by theme. An empty Creator section means the next cycle keeps the proposal and starts
at Do.

```markdown
## Cycle <N> -> Cycle <N+1>

## Creator-Routed Issues
| # | Source | Severity | Category | Location | Issue | Cycles open |
|---|--------|----------|----------|----------|-------|-------------|

## Maker-Routed Issues
| # | Source | Severity | Category | Location | Issue | Cycles open |
|---|--------|----------|----------|----------|-------|-------------|

## Resolved This Cycle
| # | Source | Issue | How resolved |
|---|--------|-------|--------------|
```

## Step 5: Archive the cycle

In `.archeflow/artifacts/<run_id>/cycle-<N>/`:

- **copy** `plan-*.md` and `act-feedback.md` (the next cycle reads them from the top level; a new
  Creator run overwrites `plan-creator.md`);
- **move** `do-*` and `check-*` (integrate writes a new diff; old reviews must not reach the next
  Check);
- leave `findings-cycle-<N>.json` and `convergence-cycle-<N>.json` in place.
