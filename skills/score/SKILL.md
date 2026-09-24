---
name: score
description: |
  Show how useful each ArcheFlow reviewer role has been across runs (signal-to-noise, fix rate, cost) with keep/optimize/remove recommendations.
  <example>User: "/archeflow:score"</example>
---

# ArcheFlow Effectiveness Scores

1. Run `<archeflow-root>/lib/archeflow-score.sh report` and show its table.
2. If the user names a team file: `<archeflow-root>/lib/archeflow-score.sh recommend <team.yaml>` for model-tier suggestions.
3. No data yet (`.archeflow/memory/effectiveness.jsonl` missing): say "No scores yet. Scores are recorded at the end of each `/archeflow:run`."

Scores need several runs before they mean anything; say so when fewer than 10 runs are recorded.
