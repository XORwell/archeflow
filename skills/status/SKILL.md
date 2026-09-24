---
name: status
description: |
  Show ArcheFlow status in this project: the active or last run, its phase and branch, open findings, memory and config.
  <example>User: "/archeflow:status"</example>
---

# ArcheFlow Status

1. If `.archeflow/` does not exist, say: "ArcheFlow is not set up here. Run `/archeflow:init`, or start with `/archeflow:review`." and stop.
2. Find the latest run: the last line of `.archeflow/events/index.jsonl` (completed runs), and the newest `.archeflow/events/<run_id>.jsonl` without a `run.complete` event (a run in progress). No event files: say "No runs yet. Start one with `/archeflow:run <task>`." and go to step 5.
3. For that run: `<archeflow-root>/lib/archeflow-report.sh .archeflow/events/<run_id>.jsonl --summary`
4. If the run's branch still exists (`.archeflow/runs/<run_id>/` exists): `<archeflow-root>/lib/archeflow-git.sh status <run_id>`. A run that ended with `awaiting_merge` is waiting for the user to merge it.
5. Memory: count lines in `.archeflow/memory/lessons.jsonl`. Config: workflow, `costs.budget_usd`, `git.auto_merge`, `test_command` from `.archeflow/config.yaml`.

Output:

```
archeflow · <domain> domain
Run: <run_id> · <status or current phase> · cycle <N>
  <summary line>
Branch: <run-branch> (<n> commits ahead of <base>)     # only if it still exists
Memory: <N> lessons · budget $<X> · auto_merge <on|off> · test_command <set|unset>
```
