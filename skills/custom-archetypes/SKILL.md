---
name: custom-archetypes
description: Use when the user wants to create domain-specific archetypes -- specialized agent roles beyond the 7 built-in ones.
user-invocable: false
---

# Custom Archetypes

Add domain expertise beyond the 7 built-ins: database specialist, compliance auditor, accessibility reviewer, etc.

## When to Create

- A recurring review concern isn't covered by built-ins
- You need domain knowledge (GDPR, PCI-DSS, WCAG, SQL optimization)
- Same custom instructions used across multiple orchestrations

## Definition Format

Create `.archeflow/archetypes/<id>.md`:

```markdown
# <Name>

## Identity
**ID:** <lowercase-with-hyphens>
**Role:** <one sentence>
**Lens:** <the one question this archetype always asks>
**Model tier:** cheap | standard | premium

## Behavior
<System prompt: what to look for, how to evaluate, output format, decision criteria>

## Outputs
<Message types: Research, Proposal, Challenge, RiskAssessment, QualityReport, Implementation>

## Shadow
**Name:** <dysfunction name>
**Strength inverted:** <how core strength becomes destructive>
**Symptoms:** <3 observable behaviors>
**Correction:** <specific prompt to course-correct>
```

## Composition

Combine two archetypes into a focused super-reviewer:

- Max 2 archetypes combined
- Combined shadow must address both source shadows
- Use when spawning both separately would waste tokens on overlapping context

## Team Presets

Save team configs in `.archeflow/teams/<name>.yaml`:

```yaml
name: backend
plan: [explorer, creator]
do: [maker]
check: [guardian, sage]
exit: all_approved
max_cycles: 2
```

Reference custom archetypes by ID in the `check` (or any phase) list.

## Rules

1. One concern per archetype
2. Concrete shadow with observable symptoms
3. Right model tier: analytical = cheap, creative = standard, judgment = premium
4. Specific lens question focuses behavior
5. Compose before creating from scratch
