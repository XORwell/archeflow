---
name: archeflow-sprint
description: Work through a workspace task queue (docs/orchestra/queue.json) across several repositories (Cursor adapter for the core sprint skill). Usage: /archeflow-sprint [--slots N] [--dry-run]
---

# ArcheFlow Sprint (Cursor)

Read `<archeflow-root>/skills/sprint/SKILL.md` and follow it, including its rules on mode
(ATTENDED unless the user says otherwise in this session) and on `proposed` items (dispatch
only after the user approves them).

## Find `<archeflow-root>`

The ArcheFlow checkout: the directory that contains `lib/archeflow-event.sh`, `skills/` and
`agents/`. If this file is `<root>/.cursor/skills/<name>/SKILL.md`, it is three levels up.
Otherwise ask the user where their ArcheFlow checkout is. Use its absolute path for every
`<archeflow-root>` below and in the loaded skill.

## Cursor tool mapping

| The core skill says | In Cursor |
|---------------------|-----------|
| spawn an agent with `subagent_type: "archeflow:<role>"` | `Task(subagent_type="generalPurpose", prompt="<full text of <archeflow-root>/agents/<role>.md>\n\n---\n\n<the prompt from the skill>")` |
| spawn several agents in one message | several `Task` calls in one message |
| run a command | `Shell(command="...")`, from the project root |
| write a file with your file tool | `Write` |

Everything else (steps, commands, artifacts, confirmations) is exactly as in the core skill.
