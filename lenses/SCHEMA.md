# Lens Schema

A lens is a stackable attention modifier that layers onto the active domain.
Domains set the base (code/writing/research). Lenses sharpen focus.

## File format

```yaml
name: <kebab-case identifier>
description: <one-line purpose>
version: "1.0"

# Additional finding categories this lens introduces
finding_categories:
  - <category-name>

# Extra context files injected into agent prompts per phase
context_inject:
  always: [<file>]          # injected into every agent
  plan: [<file>]            # plan phase only
  check: [<file>]           # check phase only

# Adjust archetype attention within this lens
attention:
  <archetype>:
    weight: <float>         # multiplier on token budget (1.0 = default)
    extra_focus: "<text>"   # appended to the agent's review focus prompt
    extra_categories: [<cat>]  # categories this archetype should also flag

# Override shadow detection thresholds (more lenient or stricter)
shadow_overrides:
  <archetype>:
    <shadow_param>: <value>

# Extra evidence rules for lens-specific categories
evidence_rules:
  - category: <category-name>
    requires: [<field>, ...]  # what constitutes valid evidence

# Model overrides (lens can upgrade a model for specific archetypes)
model_overrides:
  <archetype>: <model>
```

## Stacking rules

1. Domain config loads first (base layer)
2. Lenses apply left-to-right in CLI order: `--lens security --lens compliance`
3. Arrays merge (union): `finding_categories`, `context_inject`, `extra_categories`
4. Scalars override (last wins): `weight`, `model_overrides`, `shadow_overrides`
5. `extra_focus` strings concatenate with "; " separator
6. A lens never removes what a domain or prior lens added — lenses are additive

## Conventions

- One lens per yaml file in `lenses/` or `.archeflow/lenses/`
- Project-local lenses (`.archeflow/lenses/`) override built-in lenses of the same name
- Lens names must be unique within a run
- Keep lenses small and focused — a lens that touches everything is a domain
