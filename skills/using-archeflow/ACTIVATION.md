# ArcheFlow is installed

Role-based Plan -> Do -> Check -> Act workflows. Do not announce ArcheFlow or run any command at
session start; use it only when the user asks for it or invokes one of its commands.

`<archeflow-root>` in ArcheFlow skills means the "ArcheFlow root" path given above. Substitute
the absolute path when running `<archeflow-root>/lib/...` scripts (quote it), and run them from
the project root so `.archeflow/` state lands in the project.

| Need | Command |
|------|---------|
| Review existing changes | `/archeflow:review` |
| One task, full Plan/Do/Check/Act on its own branch | `/archeflow:run <task>` |
| Set up a project | `/archeflow:init` |
| Work a task queue across several repositories | `/archeflow:sprint` |
| State of the current or last run | `/archeflow:status` |

More: `/archeflow:report`, `/archeflow:dag`, `/archeflow:replay`, `/archeflow:score`,
`/archeflow:memory`, `/archeflow:scan`. Skip ArcheFlow for single-line fixes, questions, reading
code, config tweaks and plain git operations.
