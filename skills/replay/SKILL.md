---
name: replay
description: |
  Replay a recorded ArcheFlow run: decision timeline and weighted what-if over the reviewers' verdicts. Usage: /archeflow:replay <run_id> [--timeline|--whatif|--compare] [--weights role=w,...]
  <example>User: "/archeflow:replay 2026-04-06-jwt-auth"</example>
  <example>User: "/archeflow:replay 2026-04-06-jwt-auth --whatif --weights guardian=2,sage=0.5"</example>
---

# ArcheFlow Run Replay

Inspect a run logged in `.archeflow/events/<run_id>.jsonl`: which roles drove the outcome, and
what a weighted vote would have decided. Only accept run IDs made of letters, digits, `.`, `_`, `-`.

## Commands (from the project root)

| Action | Command |
|--------|---------|
| Timeline (default) | `<archeflow-root>/lib/archeflow-replay.sh timeline <run_id>` |
| What-if | `<archeflow-root>/lib/archeflow-replay.sh whatif <run_id> [--weights guardian=2,sage=0.5] [--threshold 0.5] [--json]` |
| Both | `<archeflow-root>/lib/archeflow-replay.sh compare <run_id> [--weights ...]` |

- **Timeline** lists `decision.point` events and the Check-phase `review.verdict` events.
- **What-if** takes the last `review.verdict` per role. Original outcome: any non-approval blocks.
  Replay: each reviewer contributes weight x (1 if not approved, else 0); BLOCK if the weighted
  mean is at or above the threshold (default 0.5).
- `--json` prints machine-readable output.

## Recording decisions (during a run)

`/archeflow:run` records `decision.point` events after routing, fast-path and escalation choices.
Write the data object (`{"archetype": ..., "input": ..., "decision": ..., "confidence": 0.85}`)
to `.archeflow/artifacts/<run_id>/event.json` with your file tool, then:
`<archeflow-root>/lib/archeflow-event.sh <run_id> decision.point <phase> <role> "$(cat .archeflow/artifacts/<run_id>/event.json)"`.
Never paste summaries or task text into the command line itself.
