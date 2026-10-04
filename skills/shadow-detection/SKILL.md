---
name: shadow-detection
description: Corrective actions for ArcheFlow failure modes ("shadows") of agents and of the run, plus the escalation protocol and Wiggum Break.
user-invocable: false
---

# Failure Modes: Corrective Actions

Read this when `archeflow-shadow.sh detect` or `check-system` exits 0. The scripts do the
detecting and log each hit as `shadow.detected`; the rules, the Wiggum Break triggers and the
policy boundaries (checkpoints, budget) are in `reference.md` in this directory, on demand.

## Agent failure modes

| Role | Failure mode | Corrective prompt |
|------|--------------|-------------------|
| Explorer | Rabbit Hole | "Summarize top 3 findings and one recommendation in 300 words." |
| Creator | Over-Architect | "Design for the current order of magnitude. Remove abstractions for hypothetical requirements." |
| Maker | Rogue | "Read the proposal. Write a test. Commit. Revert out-of-scope files." |
| Guardian | Paranoid | "For each CRITICAL: would a senior engineer block a PR? If not, downgrade. Every rejection needs a specific fix." |
| Skeptic | Paralytic | "Rank by impact. Keep top 3 with alternatives. Delete the rest." |
| Trickster | False Alarm | "Delete findings outside the diff. Rank by likelihood x impact. Keep top 3-5." |
| Sage | Bureaucrat | "Limit to issues affecting maintainability in 6 months. Every finding needs a specific action." |

Intensity alone is not a failure mode: a Guardian blocking on two genuine vulnerabilities, or a
Trickster with five in-diff findings that all have reproduction steps, is doing its job. A
failure mode is behaviour disconnected from the goal.

## Run failure modes (`check-system`, archetype `system`)

| Shadow | Corrective action |
|--------|-------------------|
| Tunnel Vision | "Redistribute attention. Are we missing quality, testing, or design concerns?" |
| Echo Chamber | Suspicious fast consensus: re-run the Guardian with an adversarial prompt. |
| Gold Plating | Fix CRITICALs first; park INFO items. |
| Analysis Paralysis | Stop researching; ship a proposal with known gaps. |
| Cargo Cult | The injected lesson did not work: reword, strengthen or remove it. |
| Broken Window | Accumulated tech debt: suggest a cleanup sprint to the user. |
| Scope Creep | Revert to the proposal's scope; more files need an updated proposal first. |

## Escalation

| Occurrence | Agent failure mode | Run failure mode | Policy boundary |
|------------|--------------------|------------------|-----------------|
| 1st | corrective prompt, the agent continues | corrective action, run continues | boundary action (downgrade, checkpoint) |
| 2nd (same issue) | replace the agent | pause, report to the user | stop with clean state |
| 3rd | ask the user to re-scope the task | report a systemic issue | report that resource limits are reached |

## Wiggum Break

The circuit breaker: `<archeflow-root>/lib/archeflow-convergence.sh wiggum-check <run_id>` exits 0
with `{"wiggum_break": true, "type": "hard"|"soft", "triggers": [...]}` and logs a `wiggum.break`
event. Hard: stop now, keep the branch. Soft: finish the current step, then stop. Either way the
open findings are in the latest `findings-cycle-<N>.json`; report them.
