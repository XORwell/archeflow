---
name: shadow-detection
description: |
  Corrective action framework for agent dysfunction, system health, and operational policy.
  Three layers — archetype shadows, system shadows, policy boundaries — one escalation protocol.
user-invocable: false
---

# Corrective Action Framework

Detect dysfunction. Apply corrective action. Escalate if repeated.

Three layers, one protocol:
- **Archetype Shadows** — individual agent dysfunction (virtue pushed too far)
- **System Shadows** — orchestration-level dysfunction (process going wrong)
- **Policy Boundaries** — operational limits (time, cost, quality thresholds)

---

## Archetype Shadows

| Archetype | Shadow | Detect (any) | Corrective Action |
|-----------|--------|-------------|-------------------|
| Explorer | Rabbit Hole | Output >2000w without Recommendation; >3 tangents; >15 files no patterns; no synthesis in final 25% | "Summarize top 3 findings and one recommendation in 300 words." |
| Creator | Over-Architect | >2 new abstractions for one feature; "future-proof" in rationale; scope exceeds task >50% (proposal words > 1.5x `--task-words`/`ARCHEFLOW_TASK_WORDS`; skipped if unset); >1 new package | "Design for the current order of magnitude. Remove abstractions for hypothetical requirements." |
| Maker | Rogue | Zero test files with >=3 files changed; single monolithic commit; files outside proposal; no test run evidence | "Read the proposal. Write a test. Commit. Revert out-of-scope files." |
| Guardian | Paranoid | CRITICAL:WARNING ratio strictly >2:1 with >=3 CRITICALs (4:2 does not fire, 3:0 does); zero APPROVED in 3+ reviews; <50% findings include fix; findings require compromised systems | "For each CRITICAL: would a senior engineer block a PR? If not, downgrade. Every rejection needs a specific fix." |
| Skeptic | Paralytic | >7 challenges with <50% alternatives; 2+ distinct concern sentences each repeated (near-)verbatim; >3 findings outside scope | "Rank by impact. Keep top 3 with alternatives. Delete the rest." |
| Trickster | False Alarm | Findings in untouched code; >10 findings for <5 files; impossible scenarios; >3 without repro steps | "Delete findings outside the diff. Rank by likelihood x impact. Keep top 3-5." |
| Sage | Bureaucrat | Review words >2x diff lines; findings outside changeset; >2 "consider" without action; suggesting docs for trivial functions | "Limit to issues affecting maintainability in 6 months. Every finding needs a specific action." |

### Shadow Immunity

Intensity alone is not a shadow. **Shadow = behavior disconnected from the goal.**

- Explorer reading 20 files in a monorepo with scattered deps -- not rabbit hole if each is relevant
- Guardian blocking with 2 CRITICALs -- not paranoid if both are genuine vulnerabilities
- Trickster finding 5 edge cases -- not false alarm if all are in changed code with repro steps

---

## System Shadows

Orchestration-level dysfunction that isn't tied to one archetype.

| Shadow | Detect | Corrective Action |
|--------|--------|-------------------|
| **Tunnel Vision** | All reviewers flag same category (e.g., 4 security findings, 0 quality/testing) | "Redistribute attention. Are we missing quality, testing, or design concerns?" |
| **Echo Chamber** | Unanimous approval: 2+ check-phase `agent.complete` events and none mentions CRITICAL/WARNING (the script does not measure elapsed time or workflow; apply the "<30s on standard/thorough" judgement manually) | "Suspicious fast consensus. Re-run Guardian with adversarial prompt." |
| **Gold Plating** | Maker working on INFO fixes while CRITICALs remain open | "Fix CRITICALs first. Park INFO items." |
| **Analysis Paralysis** | Plan phase >2x longer than Do phase; Explorer spawned 3+ times | "Stop researching. Ship a proposal with known gaps." |
| **Cargo Cult** | Memory lesson injected but the same finding repeats anyway (judged by the orchestrator from `archeflow-memory.sh audit-check <run_id>`; not part of `check-system`) | "Lesson ineffective. Reword, strengthen, or remove it." |
| **Broken Window** | 3+ WARNING lessons recorded in the project's memory (`lessons.jsonl`), across any runs | "Accumulated tech debt. Schedule a cleanup sprint." |
| **Scope Creep** | Maker changes >2x files listed in proposal | "Revert to proposal scope. If more files needed, update the proposal first." |

Check: `<archeflow-root>/lib/archeflow-shadow.sh check-system <run_id>` after each cycle. It reads
`plan-creator.md`, `do-maker.diff` and `check-*.md` from `.archeflow/artifacts/<run_id>/` and the
run's event log. Exit 0: shadows found (listed); 1: clean; 2: error.

Per-agent check: `<archeflow-root>/lib/archeflow-shadow.sh detect <role> <artifact> --run-id <run_id> --cycle <N>`
(see `archeflow:run`, Failure-mode checks). Detections are logged as `shadow.detected` events,
which the Wiggum Break check counts.

---

## Policy Boundaries

Operational limits that protect session quality, cost, and resumability.

### Checkpoint Policy

Every **45 minutes** or **3 completed tasks** (whichever first):

1. Commit + push all work in progress
2. Write a handoff summary to the workspace status log (e.g. `docs/status.md`), if one exists
3. Log token spend so far
4. Compare output quality: last task vs first task
5. If quality degrading -> STOP with clean state
6. If budget >80% spent -> STOP with clean state
7. Otherwise -> continue

### Budget Gate

| Threshold | Action |
|-----------|--------|
| 50% budget spent | Log warning, continue |
| 80% budget spent | Downgrade models (sonnet->haiku for reviewers) |
| 95% budget spent | Complete current task, then STOP |
| 100% budget | STOP immediately, commit WIP |

### Wiggum Break (circuit breaker)

The **Wiggum Break** is ArcheFlow's circuit breaker: it stops a run that keeps going without
making progress, saves the state, and hands control back to the user. The name is a pun on the
"Ralph Wiggum" technique (Geoffrey Huntley's name for running a coding agent in a loop until the
job is done): the Wiggum Break is the rule that decides when such a loop has to stop.

Check: `<archeflow-root>/lib/archeflow-convergence.sh wiggum-check <run_id>`. It reads the run's
event log (`.archeflow/events/<run_id>.jsonl`) and artifacts (`.archeflow/artifacts/<run_id>/`:
`findings-cycle-<N>.json`, `convergence-cycle-<N>.json`). Exit 0 with
`{"wiggum_break": true, "type": "hard"|"soft", "triggers": [...]}`: break. Exit 1 with
`{"wiggum_break": false}`: continue. Exit 2: error (bad run ID, missing files).

**Hard breaks** (halt immediately, commit WIP):

| Trigger | Reason |
|---------|--------|
| 3 consecutive agent failures/timeouts (`agent.failed`/`agent.timeout` events) | Infrastructure issue, not a code problem |
| 3 consecutive task failures in sprint (tracked by the sprint runner, not `wiggum-check`) | Something systemic is wrong |
| Same shadow (archetype + shadow) detected 3+ times in one cycle (`data.cycle`; events without it count as cycle 1) | Task needs to be broken down or re-scoped |
| Test suite broken after merge (`archeflow-rollback.sh` reverted the merge and logged it) | Halt, keep the branch |
| 2+ oscillating findings (present→absent→present) | Fundamental tension in review criteria |

**Soft breaks** (finish current task, then halt):

| Signal | Reason |
|--------|--------|
| Cycle N findings identical to cycle N-1 | No progress — present best result |
| Convergence score <0.5 for 2 consecutive cycles | "This needs a different approach" |
| Budget above 95% (`costs.budget_usd`, from `estimated_cost_usd` in events) | Finish, then stop |

When a Wiggum Break fires, emit a `wiggum.break` event with trigger, run state, and unresolved findings.
The event log makes it easy to audit why a run was halted and whether the break was warranted.

### Context Pollution

| Signal | Action |
|--------|--------|
| >15 memory lessons injected into one prompt | Prune to top 5 by frequency |
| >20 findings tracked across cycles | Summarize into top 5 themes |
| Agent prompt exceeds estimated 50% of context window | Strip examples, keep rules only |

---

## Unified Escalation Protocol

All three layers use the same escalation:

| Step | Archetype Shadows | System Shadows | Policy Boundaries |
|------|-------------------|----------------|-------------------|
| **1st** | Apply corrective action, let agent continue | Apply corrective action, continue run | Apply boundary action (downgrade, checkpoint) |
| **2nd** (same issue) | Replace the agent -- shadow is entrenched | Pause run, report to user | Force stop with clean state |
| **3rd** (pattern) | Escalate to user: "task needs re-scoping" | Escalate to user: "systemic issue" | Escalate to user: "resource limits reached" |

---

## Integration

Shadow checks run **after each agent completes** during orchestration. System shadow checks run **at phase boundaries**. Policy checks run **on a timer and at task boundaries**.

The `run` skill references this framework at:
- Step 3 (Check phase): archetype shadow monitoring
- Step 4 (Act phase): convergence/diminishing returns
- Step 5 (Completion): effectiveness scoring
- Sprint skill: checkpoint policy between batches
