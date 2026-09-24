# Pattern Schema

A pattern defines how agents interact within a phase. Patterns are independent
of which archetypes participate — they describe the interaction shape, not the roles.

## Built-in patterns

| Pattern | Shape | Default for |
|---------|-------|-------------|
| `sequential` | A → B → C | Plan phase |
| `parallel-merge` | A \| B \| C → merge | Check phase (after Guardian) |
| `cascade` | A → (if findings) B → (if findings) C | — |
| `debate` | advocate \| critic → judge | — |
| `best-of-n` | A₁ \| A₂ \| ... Aₙ → score → pick | — |

## File format

```yaml
name: <kebab-case>
description: <one-line>
version: "1.0"

# How agents are spawned and how their outputs combine
shape: sequential | parallel-merge | cascade | debate | best-of-n

# Shape-specific configuration
config:
  # sequential: order matters, each agent sees prior output
  # parallel-merge: all spawn at once, outputs merged by dedup rules
  # cascade: see cascade.yaml
  # debate: see debate.yaml
  # best-of-n: see best-of-n.yaml (not yet implemented)
```

## How patterns interact with workflows

Workflows define WHICH archetypes participate per phase.
Patterns define HOW those archetypes interact within the phase.

```yaml
# .archeflow/config.yaml
patterns:
  plan: sequential          # default — Explorer then Creator
  check: cascade            # stop spawning once an agent finds nothing
```

If no pattern is specified for a phase, the built-in default applies:
- Plan: `sequential`
- Do: single agent (no pattern needed)
- Check: `parallel-merge` (with Guardian-first rule)

## Conventions

- Pattern files live in `patterns/` (built-in) or `.archeflow/patterns/` (project-local)
- Project-local patterns override built-in patterns of the same name
- Patterns are phase-agnostic — any pattern can be used in any phase
- The `debate` pattern requires exactly 3 roles; `cascade` requires 2+; others are flexible
