---
name: init
description: |
  Set up ArcheFlow in the current project from a bundle (quick-fix, backend-feature, security-review). Usage: /archeflow:init [bundle]
  <example>User: "/archeflow:init"</example>
  <example>User: "/archeflow:init backend-feature"</example>
---

# ArcheFlow Init

Creates `.archeflow/` in the project root: `config.yaml`, a team, a workflow and a domain file.

| Bundle | Workflow | Team | Budget |
|--------|----------|------|--------|
| `quick-fix` | fast, 1 cycle | Creator, Maker, Guardian | $2 |
| `backend-feature` | standard, 2 cycles | Explorer, Creator, Maker, Guardian, Sage | $5 |
| `security-review` | thorough, 3 cycles | all seven roles | $15 |

1. Run from the project root (a git repository). No bundle given: `<archeflow-root>/lib/archeflow-init.sh --list`, show the list and ask which one.
2. `<archeflow-root>/lib/archeflow-init.sh <bundle>` (add `--set key=value` for variables the user names). If `.archeflow/` already exists the script asks before overwriting; relay that question, never answer it yourself.
3. Show what was created (`.archeflow/config.yaml` and the files listed by the script).
4. Ask the user for the project's test command (for example `npm test`, `pytest -q`, `cargo test`). If they give one, add it as a **top-level** line `test_command: "<cmd>"` to `.archeflow/config.yaml`. It runs after every ArcheFlow merge; without it post-merge tests are skipped.
5. Say that merges into their branch are confirmed interactively by default (`git.auto_merge: false`), that the bundle's workflow is now the default for `/archeflow:run` (`workflow:` in the config; `--workflow` overrides it), and that the script wrote `.archeflow/.gitignore`: run state (events, artifacts, run metadata, worktrees, memory) stays local, while the configuration files can be committed.
6. Next step: `/archeflow:run <task>`, or `/archeflow:review` for existing changes.
