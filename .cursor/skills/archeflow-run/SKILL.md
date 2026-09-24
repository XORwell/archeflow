---
name: archeflow-run
description: Run one task through ArcheFlow's Plan, Do, Check, Act on its own git branch (Cursor adapter for the core run skill). Usage: /archeflow-run <task> [--workflow fast|standard|thorough] [--dry-run] [--start-from plan|do|check|act]
---

# ArcheFlow Run (Cursor)

Read `<archeflow-root>/skills/run/SKILL.md` and follow it. The Maker works in the worktree
that `archeflow-git.sh worktree` creates: tell the Maker's Task to `cd` to that path for every
command. Cursor has no `isolation` parameter, and none is needed.

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
