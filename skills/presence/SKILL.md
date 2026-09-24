---
name: presence
description: |
  Defines how ArcheFlow communicates its activity to the user -- visible but not noisy.
  Show value, not process. Auto-loaded by the run skill.
user-invocable: false
---

# ArcheFlow Presence -- Visible Value, Not Noise

## Output Rules

1. Show outcomes, not mechanics
2. One line per phase, not per agent
3. Numbers over words
4. Silence on clean passes
5. Value summary at the end

## Status Line Format

**Run start:**
```
-- archeflow -- <task> -- <workflow> (<max_cycles> cycles) --
```

**Phase complete (only if noteworthy):**
```
  V plan    explorer: 3 directions -> chose C | creator: 6 scenes
  V do      6004 words drafted
  T check   guardian: 1 fix needed | sage: 5 voice adjustments
  V act     approved, merged into main
```
Symbols: V = clean, T = issues found, X = failed/blocked.

**Run complete:**
```
-- done -- 2 cycles . 7 agents . 3 findings resolved . ~22 min --
   story drafted, reviewed, and polished. see stories/01-add-auth.md
```

ArcheFlow prints nothing at session start; the first line appears when a command runs.

## When to Be Silent

- Agent spawning/completion lifecycle
- Event emission
- Artifact routing
- Clean review passes (0 findings)
- Phase transitions with no visible output

## When to Speak

- Run start and complete (always)
- Findings found and fixes applied
- Budget warnings
- Shadow detected
- User decision needed
