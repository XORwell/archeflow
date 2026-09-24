---
name: dag
description: |
  Show the event DAG (which agent ran, what it produced, which findings led to which fixes) of the current or last ArcheFlow run.
  <example>User: "/archeflow:dag"</example>
  <example>User: "/archeflow:dag 2026-04-06-jwt-auth"</example>
---

# ArcheFlow Run DAG

1. Run ID: the argument, else the newest `.archeflow/events/*.jsonl` (ignore `index.jsonl`). Only accept IDs made of letters, digits, `.`, `_`, `-`.
2. Run `<archeflow-root>/lib/archeflow-dag.sh .archeflow/events/<run_id>.jsonl --no-color` and show its output unchanged.
3. No event file for the ID: say "No events found for run `<run_id>`."
