---
name: report
description: |
  Generate the full process report (phases, reviews, findings, fixes, cost) for an ArcheFlow run.
  <example>User: "/archeflow:report"</example>
  <example>User: "/archeflow:report 2026-04-06-jwt-auth"</example>
---

# ArcheFlow Run Report

1. Run ID: the argument, else the newest `.archeflow/events/*.jsonl` (ignore `index.jsonl`). Only accept IDs made of letters, digits, `.`, `_`, `-`.
2. Run `<archeflow-root>/lib/archeflow-report.sh .archeflow/events/<run_id>.jsonl` and show the Markdown it prints. To save it: add `--output .archeflow/artifacts/<run_id>/report.md`.
3. No event file for the ID: say "No events found for run `<run_id>`."
