---
name: workflow-design
description: Choosing a workflow for a run (fast, standard, thorough), adding focus with lenses and patterns, and the hooks specification (.archeflow/hooks.yaml).
user-invocable: false
---

# Workflow Design -- PDCA Cycles

PDCA cycles spiral upward: each cycle incorporates feedback from the previous one.

## Built-in Workflows

| Workflow | Plan | Do | Check | Exit | Max Cycles |
|----------|------|----|-------|------|------------|
| `fast` | Creator | Maker | Guardian | approve/reject | 1 |
| `standard` | Explorer + Creator | Maker | Guardian + Skeptic + Sage | all_approved | 2 |
| `thorough` | Explorer + Creator | Maker | Guardian + Skeptic + Sage + Trickster | all_approved | 3 |

`/archeflow:run` knows exactly these three workflows (`--workflow <name>`, or `workflow:` in
`.archeflow/config.yaml`). Files in `.archeflow/workflows/` and `.archeflow/teams/` (copied
there by bundles) describe a setup for people reading it; **the run does not read them**.

## Shaping a run

| Concern | Use |
|---------|-----|
| Security-sensitive change | `thorough` (adds Trickster), `--lens security` |
| Personal data | `--lens compliance-gdpr` |
| Prose (writing domain) | `--lens prose-voice` |
| Plan quality matters more than speed | `--pattern plan:debate` |
| Cheap review of many small changes | `--pattern check:cascade` |

Lenses and patterns are described in the run skill's `reference.md`. More than 3 cycles rarely
converges; if two cycles did not, change the task, not the cycle count.

## Hooks

The one hook specification (the run skill and `docs/hooks.md` follow it). Hooks live in
`.archeflow/hooks.yaml`, one top-level key per hook:

```yaml
pre-merge:
  command: "npm run lint && npm run typecheck"
  fail_action: abort
run-complete:
  command: "echo run $ARCHEFLOW_RUN_ID finished: $ARCHEFLOW_STATUS >> .archeflow/hooks.log"
  fail_action: warn
```

| Hook | Called at (`archeflow:run`) | Variables | Default `fail_action` |
|------|-----------------------------|-----------|-----------------------|
| `run-start` | Start, step 7 (after `run.start`) | `ARCHEFLOW_RUN_ID`, `ARCHEFLOW_WORKFLOW` | `warn` |
| `pre-merge` | Merge, step 1 (all reviewers approved, before the merge) | `ARCHEFLOW_RUN_ID`, `ARCHEFLOW_BRANCH`, `ARCHEFLOW_TARGET` | `abort` |
| `post-merge` | Merge, step 5 (after the merge and passing or skipped tests) | `ARCHEFLOW_RUN_ID`, `ARCHEFLOW_BRANCH`, `ARCHEFLOW_TARGET` | `warn` |
| `run-complete` | Completion, step 8 (any outcome) | `ARCHEFLOW_RUN_ID`, `ARCHEFLOW_STATUS`, `ARCHEFLOW_CYCLES` | `warn` |

There are no other hook points; other keys in `hooks.yaml` are ignored (say so if you find one).

`fail_action`: `warn` = log and continue; `abort` = emit a `decision` event
(`{"what": "hook", "chosen": "hook_abort"}`), stop the run and report.

Hooks are run by the orchestrating agent, not by a script. The file comes from the repository,
so show each hook command to the user and get a yes before its first run in a session; never run
a hook the user declined. To run one, write its `command` to
`.archeflow/artifacts/<run_id>/hook.sh` with your file tool, then from the project root:
`ARCHEFLOW_RUN_ID=<run_id> <other variables> bash .archeflow/artifacts/<run_id>/hook.sh`.

## Anti-Patterns

- Using `thorough` for small changes (cost without benefit)
- Re-running a run that hit a Wiggum Break without changing the task
- Skipping the Check phase
