---
name: archeflow-review
description: Review uncommitted changes, a branch or a commit range with ArcheFlow's reviewer roles (Cursor adapter for the core review skill). Usage: /archeflow-review [--branch <name>] [--commit <range>] [--reviewers guardian,sage]
---

# ArcheFlow Review (Cursor)

Read `<archeflow-root>/skills/review/SKILL.md` and follow it.

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
