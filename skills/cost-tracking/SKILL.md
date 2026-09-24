---
name: cost-tracking
description: |
  Cost aggregation, budget enforcement, and model selection for ArcheFlow orchestrations.
  Tracks per-agent and per-run token costs, enforces budgets, and recommends the cheapest
  model that meets quality requirements per archetype and domain.
  <example>User: "How much did that orchestration cost?"</example>
  <example>Automatically active when budget is configured</example>
user-invocable: false
---

# Cost Tracking -- Budget-Aware Orchestration

Tracks costs per agent and per run, enforces budgets, and selects cost-optimal models.

## Model Pricing

| Model | Input ($/M tok) | Output ($/M tok) |
|-------|----------------:|-----------------:|
| claude-opus-4-6 | 15.00 | 75.00 |
| claude-sonnet-4-6 | 3.00 | 15.00 |
| claude-haiku-4-5 | 0.80 | 4.00 |

## Local provider (Ollama)

When `models.provider: ollama` in `.archeflow/config.yaml` or `ARCHEFLOW_MODEL_PROVIDER=ollama` (legacy `ARCHFLOW_MODEL_PROVIDER` also accepted):

- Record **USD 0** for API spend on those runs. Optionally log `compute: local` in the daily ledger line for transparency.
- Skip cloud budget enforcement for Ollama-backed steps (still respect wall-clock and disk if logging huge artifacts).
- If only some steps use `<archeflow-root>/lib/archeflow-ollama.sh` and the rest use Claude, split ledger entries by `provider` per agent.

**Prompt caching:** 90% discount on cached input tokens. Structure system prompts for cache hits.
**Batches API:** 50% discount. Use for non-time-sensitive bulk ops.

## Cost Calculation

```
cost = (input - cache_read) * input_price/1M
     + cache_read * input_price * 0.10/1M
     + output * output_price/1M
```

If exact tokens unavailable, estimate: `tokens ~= chars / 4`. Mark with `cost_estimated: true`.

## Default Model Assignments

| Archetype | Code | Writing |
|-----------|------|---------|
| Explorer | haiku | haiku |
| Creator | sonnet | sonnet |
| Maker | sonnet | **sonnet** |
| Guardian | haiku | haiku |
| Skeptic | haiku | haiku |
| Sage | sonnet | **sonnet** |
| Trickster | haiku | haiku |

Opus is user-opt-in only (team preset `model_overrides`).

**Resolution order:** team preset override > domain override > archetype default.

## Pre-Agent Cost Estimates

| Archetype | Typical Input | Typical Output |
|-----------|-------------:|---------------:|
| Explorer | 8k | 4k |
| Creator | 12k | 6k |
| Maker | 15k | 12k |
| Guardian | 10k | 3k |
| Skeptic | 8k | 3k |
| Sage | 12k | 4k |
| Trickster | 8k | 4k |

After 10+ runs, use actual averages from `metrics.jsonl` instead.

## Budget Configuration

```yaml
costs:
  budget_usd: 10.00        # per run; wiggum-check soft-breaks above 95%
  per_agent_usd: 3.00
  daily_usd: 50.00
  warn_at_percent: 75
```

Team preset budget overrides global config. No budget = unlimited (costs still tracked).

## Budget Enforcement

**Pre-agent:** Estimate cost. If > remaining budget: stop (autonomous) or warn (attended).

**Post-agent:** Update total. Warn at threshold. Stop if budget exceeded.

## Cost Optimization

1. **Prompt caching:** Stable content first (archetype instructions, voice profiles). Saves 30-50% on input.
2. **Guardian fast-path (A2):** 0 issues = skip remaining reviewers. Saves $0.30-0.80/cycle.
3. **Explorer cache:** Reuse recent research. Saves $0.02-0.05/hit.
4. **Batches API:** For autonomous/overnight review passes (50% discount).
5. **Early termination:** Clean Guardian + clean Maker self-review = skip remaining cycles.

## Daily Cost Tracking

Ledger at `.archeflow/costs/<YYYY-MM-DD>.jsonl`. One line per run with cost, tokens, models, domain. Daily budget enforcement reads this before starting new runs.
