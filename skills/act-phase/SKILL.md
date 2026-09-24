---
name: act-phase
description: |
  The Act phase of an ArcheFlow run: consolidate reviewer findings, route each one to the Creator or the Maker, decide whether to merge, cycle back or stop, and write act-feedback.md. Single source of truth for routing and the feedback format.
user-invocable: false
---

# Act Phase

Turn the Check phase output into a decision: **merge**, **cycle back**, or **stop**.

Act never edits code. Every fix goes through the next cycle (Creator and/or Maker) and is
reviewed again, so no unreviewed change reaches the base branch. The command sequence around
these steps (system check, convergence, Wiggum Break check, merge) is in `archeflow:run`, step 4.

## Step 1: Consolidate

Read all `check-*.md` of this cycle. Findings that `archeflow-evidence.sh validate` downgraded
now read INFO in those files; treat them as INFO. Build one list, grouped by severity (CRITICAL / WARNING / INFO):

| # | Source | Location | Severity | Category | Description | Suggested fix |
|---|--------|----------|----------|----------|-------------|---------------|
| 1 | guardian | src/auth/handler.ts:48 | CRITICAL | security | Empty string bypasses validation | Add length check |

**Deduplicate:** same file + same category + similar description = one finding. Keep the higher
severity and credit all sources (`guardian + skeptic`).

**Across cycles** (cycle 2+): compare with `findings-cycle-<N-1>.json`. Resolved: gone now.
Persisting: same id again, increment `cycles_open`. New: first appearance, `cycles_open: 1`.
For each resolved finding that a fix of the previous cycle addressed, emit `fix.applied`.

Write the list to `.archeflow/artifacts/<run_id>/findings-cycle-<N>.json`, an array of

```json
{"id": "src/auth/handler.ts:security", "file": "src/auth/handler.ts", "line": 48,
 "category": "security", "severity": "CRITICAL", "source": ["guardian"],
 "description": "Empty string bypasses validation", "routes_to": "creator", "cycles_open": 1}
```

`id` is `<file>:<category>` (add `:<n>` for a second distinct finding in the same file and
category). Keep ids stable across cycles: the convergence and Wiggum Break checks compare them.

## Step 2: Route

Canonical routing table:

| Source | Category | Routes to | Reason |
|--------|----------|-----------|--------|
| Guardian | security, breaking-change | Creator | design must change |
| Guardian | reliability, dependency | Creator | architectural decision needed |
| Skeptic | design, scalability | Creator | assumptions need revision |
| Sage | quality, consistency | Maker | implementation refinement |
| Sage | testing | Maker | test gap, not a design flaw |
| Trickster | reliability (design flaw) | Creator | needs redesign |
| Trickster | reliability (test gap), testing | Maker | needs more tests |

If the fix changes the approach, route to the Creator. If it changes code within the existing
approach, route to the Maker. When deduplicated sources disagree, the Creator wins.

## Step 3: Decide

Evaluate top to bottom; the first match wins.

| Condition | Decision |
|-----------|----------|
| Wiggum Break (hard, or soft at the end of this step) | **Stop**: keep the branch, report |
| Same CRITICAL open for 2+ consecutive cycles | **Escalate**: ask the user how to proceed |
| `fast` workflow and Guardian found 2+ CRITICAL (rule A1) | next cycle runs as `standard` (Skeptic + Sage added, fast path A2 disabled) and stays escalated |
| 0 CRITICAL and every reviewer APPROVED | **Merge** (`archeflow:run`, Merge) |
| Findings left and cycles left | **Cycle back** (Step 4) |
| Findings left, no cycles left | **Stop**: report open findings, keep the branch |

WARNING and INFO alone do not block a merge; list them in the report. Emit `cycle.boundary`
`{"cycle", "max_cycles", "exit_condition", "decision", "critical", "warning", "info"}`:
`exit_condition` is `approved`, `findings_open`, `max_cycles`, `escalated` or `wiggum_break`;
`decision` is `merge`, `cycle_back`, `stop` or `escalate` (schema: `archeflow:run`, `reference.md`).

## Step 4: Feedback for the next cycle

Write `.archeflow/artifacts/<run_id>/act-feedback.md`. The run injects each section only into the
agent it is routed to (Creator: plan step, Maker: do step):

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

Keep it under ~500 tokens: drop INFO first, then summarise WARNINGs by theme. An empty
`## Creator-Routed Issues` section means the next cycle keeps the current proposal and starts
at Do.

## Step 5: Archive the cycle

Before the next cycle starts, keep a record of this one in `.archeflow/artifacts/<run_id>/cycle-<N>/`
without taking away what the next cycle reads:

- **copy** `plan-*.md` and `act-feedback.md`: the next Creator and Maker read `act-feedback.md`,
  and the Maker, the Maker check, Skeptic, Sage and `check-system` read `plan-creator.md` from the
  top level. A new Creator run overwrites `plan-creator.md`; a kept proposal stays as it is.
- **move** `do-*` and `check-*`: `integrate` writes a new `do-maker.diff`, and reviews of this
  cycle must not be read as reviews of the next one.
- leave `findings-cycle-<N>.json` and `convergence-cycle-<N>.json` where they are (the
  convergence and Wiggum Break checks compare them across cycles).
