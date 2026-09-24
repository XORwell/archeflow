# Commands

The exact command names a user types. This file is the reference for README, CLAUDE.md,
`docs/` and the skills; `tests/skills-lint.bats` checks that every `/archeflow:<name>` used in
them is listed here and shipped as a skill.

## Claude Code

A plugin installed from a marketplace exposes its skills under the plugin's namespace, so every
command is `/archeflow:<name>`. Verified with Claude Code 2.1.281 and an isolated install
(`claude plugin marketplace add <repo>` + `claude plugin install archeflow@archeflow`): the
plugin's commands appear in the session as `archeflow:<name>`; an un-namespaced name is not a
command (the model may still guess the right skill from it, but that is not reliable). `/run` and `/init` are also Claude Code built-ins, so the namespace
is required anyway.

| Command | Arguments | What it does |
|---------|-----------|--------------|
| `/archeflow:review` | `[--branch <name> [--base <branch>]] [--commit <range>] [--reviewers guardian,skeptic,sage,trickster] [--evidence]` | Review existing changes (uncommitted by default) with Guardian, plus the named reviewers. Works in any git repository without setup. |
| `/archeflow:run` | `<task> [--workflow fast\|standard\|thorough] [--dry-run] [--start-from plan\|do\|check\|act] [--lens <name>...] [--pattern <phase>:<name>]` | Plan, Do, Check, Act for one task on its own branch (`archeflow/<run_id>`), the Maker in a separate worktree. Merges into your branch only after all reviewers approve **and** you confirm (or `git.auto_merge: true`). |
| `/archeflow:init` | `[bundle]` | Create `.archeflow/` from a bundle: `quick-fix`, `backend-feature`, `security-review`. Offers to set `test_command`. |
| `/archeflow:sprint` | `[--slots N] [--dry-run] [--priority P0,P1] [--project <name>] [--autonomous]` | Work through `docs/orchestra/queue.json` across the repositories of a workspace (see [queue.md](queue.md)). Attended by default. |
| `/archeflow:scan` | `[--dry-run]` | Propose new queue items (status `proposed`, never dispatched without your approval) and flag stale ones. |
| `/archeflow:status` | | The current or last run, its branch, memory and config. |
| `/archeflow:report` | `[run_id]` | Full Markdown process report of a run (default: the latest). |
| `/archeflow:dag` | `[run_id]` | Event DAG of a run. |
| `/archeflow:replay` | `<run_id> [--timeline\|--whatif\|--compare] [--weights role=w,...]` | Decision timeline and weighted what-if over the reviewers' verdicts. |
| `/archeflow:score` | | How useful each reviewer role has been across runs. |
| `/archeflow:memory` | `[list \| add <text> \| forget <id>]` | Show or manage cross-run lessons. |

All other skills (`act-phase`, `check-phase`, `shadow-detection`, `git-integration`,
`workflow-design`, `multi-project`, `domains`, `cost-tracking`, `custom-archetypes`,
`templates`, `autonomous-mode`, `presence`, `progress`, `using-archeflow`) are internal:
`user-invocable: false`, so they do not appear as commands. The skills above load them. A
multi-project run (`archeflow:multi-project`) has no command of its own: ask for it in plain
words ("run this multi-run.yaml"), and the agent loads that skill.

The role definitions in `agents/` are registered as agent types `archeflow:explorer`,
`archeflow:creator`, `archeflow:maker`, `archeflow:guardian`, `archeflow:skeptic`,
`archeflow:sage`, `archeflow:trickster`. The skills spawn them; users do not call them directly.

## Cursor

Cursor loads the three adapters in `.cursor/skills/` (plus the rule in `.cursor/rules/`):

| Command | Same as |
|---------|---------|
| `/archeflow-review` | `/archeflow:review` |
| `/archeflow-run <task>` | `/archeflow:run` |
| `/archeflow-sprint` | `/archeflow:sprint` |

For the other functions, ask Cursor to follow the matching core skill
(`skills/<name>/SKILL.md`, e.g. `skills/status/SKILL.md`).

## Renamed

Earlier documentation used the names `af-run`, `af-sprint`, `af-review`, `af-init`, `af-memory`,
`af-status`, `af-report`, `af-dag`, `af-replay`, `af-score` and `af-scan` (with a leading slash).
Those were never part of the plugin; use the table above.

## Behaviour a user should know (for README and docs)

- `/archeflow:run` needs a git repository and a clean tree (tracked files); it refuses rather
  than stashing your changes.
- Defaults: `git.merge_strategy: no-ff` (one revertable merge commit per run; `squash` and
  `rebase` are options), `git.auto_merge: false`, `test_command` unset. `test_command` is a
  top-level key in `.archeflow/config.yaml`; when unset, post-merge tests are skipped.
- Nothing under `.archeflow/` is committed by a run unless `git.commit_artifacts: true`.
- The Maker's worktree is `.archeflow/worktrees/<run_id>/` (branch `archeflow/<run_id>-maker`).
- Agents inherit the session's permission mode; no skill requests a bypass mode.
- Hooks: `.archeflow/hooks.yaml`, one top-level key per hook. Exactly four hook points exist,
  each called at a named step of the run skill: `run-start`, `pre-merge`, `post-merge`,
  `run-complete`; `fail_action: warn|abort`. The agent runs a hook only after you approve its
  command once per session. Canonical spec: `skills/workflow-design/SKILL.md` (Hooks).
  `docs/hooks.md` must describe this file and these four points, not a `hooks:` section in
  `config.yaml` or other hook names.
- Workflows: only `fast`, `standard`, `thorough` (`--workflow`, or `workflow:` in
  `config.yaml`). Files in `.archeflow/workflows/` and `.archeflow/teams/` that bundles copy are
  not read by the run.
- Bundles: `archeflow-init.sh` writes the bundle's `costs.budget_usd` into
  `.archeflow/config.yaml`.
- Sprint mode is `ATTENDED` unless you ask for `AUTONOMOUS` in the session; `mode` in
  `queue.json` can pause a sprint but cannot make it autonomous. Items with status `proposed`
  (from the scan or a GNAP import) need your approval before they run.
