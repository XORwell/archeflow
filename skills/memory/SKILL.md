---
name: memory
description: |
  Show or manage ArcheFlow's cross-run memory: lessons learned from past runs that are injected into agent prompts. Usage: /archeflow:memory [list | add <text> | forget <id>]
  <example>User: "/archeflow:memory"</example>
  <example>User: "/archeflow:memory add Always run the migration tests"</example>
  <example>User: "/archeflow:memory forget m-002"</example>
---

## Command

| Invocation | Run |
|------------|-----|
| `/archeflow:memory` or `list` | `<archeflow-root>/lib/archeflow-memory.sh list` |
| `add <text>` | write the text to `.archeflow/memory/new-lesson.txt` with your file tool, then `<archeflow-root>/lib/archeflow-memory.sh add preference "$(cat .archeflow/memory/new-lesson.txt)"` and delete the file |
| `forget <id>` | `<archeflow-root>/lib/archeflow-memory.sh forget <id>` (ids look like `m-002`) |

The rest of this file describes how runs use memory (`/archeflow:run` calls these steps itself).

# Cross-Run Memory

ArcheFlow forgets everything after each run. This skill extracts lessons from completed runs and injects them into future agent prompts, so recurring issues (timeline errors, missing null checks) are caught proactively.

## Storage

```
.archeflow/memory/lessons.jsonl     # Append-only, one lesson per line
.archeflow/memory/archive.jsonl     # Decayed lessons (frequency reached 0)
.archeflow/memory/audit.jsonl       # Injection audit trail
```

## Lesson Types

| Type | Source | Description |
|------|--------|-------------|
| `pattern` | Auto-detected | Recurring finding across runs (same category + similar description) |
| `preference` | Manual | User correction or workflow preference (injected immediately, skips frequency threshold) |
| `archetype_hint` | Auto-detected | Per-archetype insight (e.g., Sage catches voice drift in monologues) |
| `anti_pattern` | Manual or auto | Something that was tried and failed -- avoid repeating |

## Lesson JSON Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | `m-NNN` (monotonically increasing) |
| `ts` | ISO 8601 | Created or last updated |
| `run_id` | string | Run that created or last triggered this lesson |
| `type` | string | `pattern`, `preference`, `archetype_hint`, `anti_pattern` |
| `source` | string | Archetype name or `user_feedback` |
| `description` | string | Human-readable lesson text |
| `frequency` | integer | Times this lesson was triggered |
| `severity` | string | `bug`, `warning`, `info`, `recommendation` |
| `domain` | string | `writing`, `code`, `general`, or project-specific |
| `tags` | string[] | Keywords for matching and filtering |
| `archetype` | string? | For `archetype_hint` -- which archetype this applies to |
| `last_seen_run` | string | Run ID where last matched |
| `runs_since_last_seen` | integer | Counter for decay |

Example:
```jsonl
{"id":"m-001","ts":"2026-04-03T14:00:00Z","run_id":"2026-04-03-add-auth","type":"pattern","source":"guardian","description":"Timeline references must match story start day","frequency":2,"severity":"bug","domain":"writing","tags":["continuity","timeline"],"last_seen_run":"2026-04-03-add-auth","runs_since_last_seen":0}
```

---

## Auto-Detection

After each `run.complete`, extract lessons from findings:

```bash
<archeflow-root>/lib/archeflow-memory.sh extract .archeflow/events/<run_id>.jsonl
```

The script reads `review.verdict` events, matches findings against existing lessons by keyword overlap (50%+ threshold), increments frequency on matches, and creates new candidate lessons (frequency: 1) for unmatched findings with severity >= WARNING.

**Promotion rule:** A finding needs `frequency >= 2` (seen in 2+ runs) before injection. This filters out one-off noise. Preferences skip this threshold.

## Injection

Before spawning agents, inject relevant lessons:

```bash
<archeflow-root>/lib/archeflow-memory.sh inject <domain> <archetype>
```

Rules: filters by domain (or `general`), optionally by archetype, requires `frequency >= 2`, sorts by frequency descending, caps at 10 lessons. Lessons with `frequency >= 5` are always injected regardless of filters.

Injected as a markdown section appended to the agent's system prompt:

```markdown
## Known Issues (from past runs)
- Timeline references must match story start day [seen 3x, guardian]
- Voice drift common in monologue passages >200 words [seen 2x, sage]
```

## Decay

After each `run.complete`, apply decay: lessons not seen for 10 runs lose 1 frequency. When frequency reaches 0, the lesson is archived.

```bash
<archeflow-root>/lib/archeflow-memory.sh decay
```

## Manual Management

See the Command table at the top. Lessons added by hand are type `preference` and are injected
from the next run on.

## Audit Trail

Track which lessons are injected per run and whether they were effective. Pass `--audit <run_id>` to inject to log records. After a run, `audit-check <run_id>` compares injected lessons against review findings: no matching finding = helpful (issue prevented), matching finding = ineffective (issue repeated despite injection).

```bash
<archeflow-root>/lib/archeflow-memory.sh inject <domain> "" --audit <run_id>
<archeflow-root>/lib/archeflow-memory.sh audit-check <run_id>
```

## Integration Points

| Moment | Action | Script Command |
|--------|--------|----------------|
| After `run.complete` | Extract lessons from findings | `archeflow-memory.sh extract <events.jsonl>` |
| After extraction | Apply decay to all lessons | `archeflow-memory.sh decay` |
| Before agent spawn | Inject relevant lessons | `archeflow-memory.sh inject <domain> <archetype>` |
| User command | Add/list/forget lessons | `archeflow-memory.sh add/list/forget` |
