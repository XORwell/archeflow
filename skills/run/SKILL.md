---
name: run
description: |
  Run one task through Plan -> Do -> Check -> Act with ArcheFlow's roles, on its own git branch. Usage: /archeflow:run <task> [--workflow fast|standard|thorough] [--dry-run] [--start-from plan|do|check|act] [--lens <name>...] [--pattern <phase>:<name>]
  <example>User: "/archeflow:run add rate limiting to the login endpoint"</example>
  <example>User: "/archeflow:run --workflow thorough --dry-run migrate sessions to JWT"</example>
---

# ArcheFlow Run

Plan (Explorer, Creator) -> Do (Maker, in its own git worktree) -> Check (Guardian first, then the other reviewers) -> Act (route findings: merge, cycle back, or stop).

## Conventions

- `<archeflow-root>` is the "ArcheFlow root" path from session start. Run every command from the project root, substitute every `<placeholder>` literally, and quote paths that contain spaces.
- `<run_id>` = `<YYYY-MM-DD>-<task-slug>` (letters, digits, `.`, `_`, `-` only). `<N>` = current cycle (starts at 1). All artifacts go to `.archeflow/artifacts/<run_id>/`.
- **Untrusted text never goes into a shell command.** Task text, agent output and summaries are written to files with your file-writing tool; commands only read those files.
- **Roles:** spawn each agent with `subagent_type: "archeflow:<role>"` (explorer, creator, maker, guardian, skeptic, sage, trickster). Those agent types are the role definitions in `<archeflow-root>/agents/<role>.md`. If the type is not available (Cursor, skills used outside the plugin), use a general-purpose agent and put the full text of `<archeflow-root>/agents/<role>.md` at the top of its prompt.
- **Permissions:** agents inherit the session's permission mode. Never request a bypass mode.
- **Git only through the scripts:** during a run, change branches, merge and delete only with `archeflow-git.sh`. Never run `git reset`, `git checkout <branch>`, `git merge` or `git revert` yourself, never edit `.archeflow/config.yaml`, and never retry a step that failed to get a different result: stop and report instead.
- **Status token:** every agent ends with `STATUS: DONE | DONE_WITH_CONCERNS | NEEDS_CONTEXT | BLOCKED`. DONE_WITH_CONCERNS: log and continue. NEEDS_CONTEXT: ask the user. BLOCKED: stop and report. No token = DONE.
- **Hooks:** if `.archeflow/hooks.yaml` exists, run its `run-start`, `pre-merge`, `post-merge` and `run-complete` hooks at the steps below, as described in `archeflow:workflow-design` (Hooks): each command only after the user approved it once in this session.
- **Memory:** if Start step 5 printed lessons, append them to every agent prompt under `## Known issues`.
- **Events:** write the event's `data` object as JSON to `.archeflow/artifacts/<run_id>/event.json` (file tool), then run `<archeflow-root>/lib/archeflow-event.sh <run_id> <type> <phase> <agent> "$(cat .archeflow/artifacts/<run_id>/event.json)"`. Event types and fields: `reference.md` in this skill's directory. Logging must never block the run: on failure, warn and continue.

## 0. Start

1. Read `.archeflow/config.yaml` if it exists. Defaults: `git.enabled: true`, `git.auto_merge: false`, `git.merge_strategy: no-ff`, `test_command` unset, provider = the host's models. Lenses, patterns, local Ollama models and the pipeline strategy: `reference.md`. With `git.enabled: false`, skip every `archeflow-git.sh` step: the Maker edits the project directly and `git diff > .archeflow/artifacts/<run_id>/do-maker.diff` (if it is a git repository) replaces integrate; nothing is merged.
2. Choose the workflow: `--workflow`, else `workflow:` in the config, else by signal. Only these three exist:

   | Signal | Workflow | Max cycles | Plan | Check (after Guardian) |
   |--------|----------|------------|------|------------------------|
   | small fix, low risk, one concern | `fast` | 1 | Creator | none |
   | feature, several files, moderate risk | `standard` | 2 | Explorer + Creator | Skeptic + Sage |
   | security, breaking change, public API | `thorough` | 3 | Explorer + Creator | Skeptic + Sage + Trickster |

3. Create the run branch: `<archeflow-root>/lib/archeflow-git.sh init <run_id>`. It refuses if tracked files have uncommitted changes: ask the user to commit or stash them (do not do it yourself), then retry.
4. Write the task text verbatim to `.archeflow/artifacts/<run_id>/task.md` with your file tool.
5. Load memory: `<archeflow-root>/lib/archeflow-memory.sh inject <domain> "" --audit <run_id>` (`<domain>`: `code`, `writing` or `research`, see `archeflow:domains`).
6. Emit `run.start` (phase `plan`, agent `""`): write `{"task": <task text>, "workflow": ..., "max_cycles": ...}` to `event.json` first, then run the event command from Conventions. Never put the JSON on the command line.
7. `run-start` hook, if defined.
8. `--dry-run`: run Plan only, show workflow, agent count, Creator confidence and estimated cost, then ask whether to continue (`--start-from do`). `--start-from <phase>`: the artifacts of all earlier phases must exist (plan-creator.md for do; plus do-maker.md and do-maker.diff for check; plus check-*.md for act); stop with an error if one is missing.

Show one status line per step (format: `archeflow:presence`).

## 1. Plan

1. **Explorer** (standard, thorough): prompt = task.md + "Research the affected files and functions, dependencies, test coverage and codebase patterns. End with a recommendation." Save to `plan-explorer.md`.
2. **Creator**: prompt = task.md + plan-explorer.md (fast workflow instead: "Restate the task in one sentence, list 3 assumptions, name the highest-damage risk") + in cycle 2+ the `## Creator-Routed Issues` section of `act-feedback.md`. Ask for: architecture decisions with rationale; exact files and changes; 2+ rejected alternatives; test strategy; a `### Confidence` table (task understanding, solution completeness, risk coverage, each 0.0-1.0); risks and mitigations; in cycle 2+ how each routed issue was handled. Save to `plan-creator.md`.
3. **Confidence gate** (unparseable = 0.0): task understanding < 0.5: ask the user, do not start the Maker. Solution completeness < 0.5: upgrade fast to standard, run the Explorer, re-run the Creator. Risk coverage < 0.5: a short Explorer run on the named risks only, saved to `plan-mini-explorer.md`.

In cycle 2+ with an empty Creator-routed section, keep the current `plan-creator.md` and go straight to Do.

## 2. Do

1. Create the Maker's worktree: `<archeflow-root>/lib/archeflow-git.sh worktree <run_id>`. It prints an absolute path: the Maker's working directory, on branch `<run-branch>-maker`, starting from the current run branch.
2. **Maker**: do not pass `isolation: "worktree"`; the worktree above already isolates it (if the host's agent tool accepts a working directory, set it to that path). Prompt = "Work only in `<path>`: cd there before every command, edit only files under it, and commit there. Uncommitted changes are not integrated." + plan-creator.md + in cycle 2+ the `## Maker-Routed Issues` section of `act-feedback.md` + "Follow the proposal; write tests for every behaviour change; run the existing tests; commit in small steps. Before you finish, `git status` must be clean: commit your work and delete files your tests generated (caches, build output); do not add ignore rules the proposal does not ask for." Save its report to `do-maker.md`.
3. Bring the work into the run branch: `<archeflow-root>/lib/archeflow-git.sh integrate <run_id>`. This merges the Maker's commits, writes the run's diff against the base branch to `do-maker.diff` and the changed paths to `do-maker-files.txt`, and removes the worktree. If it reports uncommitted changes, resume the Maker to commit them, then retry. If it reports no commits, treat the Maker as BLOCKED.
4. **Test-first gate** (not for writing): no test file in `do-maker-files.txt` and the Creator named a test strategy -> repeat steps 1-3 once, telling the Maker to add those tests. No test strategy -> log a WARNING and continue.
5. Check the Maker for its failure mode (see Failure-mode checks).

## 3. Check

Finding format, evidence rules and what each reviewer receives: `archeflow:check-phase`.

1. **Guardian** first: prompt = `do-maker.diff` + the risks section of plan-creator.md. Save to `check-guardian.md`.
2. **Fast path (A2):** Guardian has 0 CRITICAL and 0 WARNING, the workflow is not escalated, and this is not the first cycle of `thorough` -> skip the other reviewers.
3. Otherwise spawn the other reviewers of the workflow in parallel (one message). Skeptic gets plan-creator.md; Sage gets plan-creator.md + do-maker.diff + do-maker.md; Trickster gets do-maker.diff only. Save to `check-<role>.md`.
4. Evidence gate for each review: `<archeflow-root>/lib/archeflow-evidence.sh validate .archeflow/artifacts/<run_id>/check-<role>.md`. Exit 0: findings without evidence (or hedged without evidence) were rewritten to INFO in the file, so Act reads them as INFO. Exit 1: nothing to downgrade.

## Failure-mode checks

After every agent: `<archeflow-root>/lib/archeflow-shadow.sh detect <role> .archeflow/artifacts/<run_id>/<artifact>.md --run-id <run_id> --cycle <N>`. Add `--proposal .archeflow/artifacts/<run_id>/plan-creator.md` for the Maker and `--diff .archeflow/artifacts/<run_id>/do-maker.diff` for Sage and Trickster. Exit 0 = failure mode found (it is logged as `shadow.detected`): first time, send the agent the corrective prompt from `archeflow:shadow-detection`; second time, replace the agent. Exit 1 = clean. Exit 2 = error: warn and continue.

## 4. Act

Follow `archeflow:act-phase` (read `<archeflow-root>/skills/act-phase/SKILL.md`): it defines consolidation, routing, the exit decision and `act-feedback.md`. Act never edits code; all fixes go through the next cycle and are reviewed again. The commands, in order:

1. Write the consolidated findings of this cycle to `.archeflow/artifacts/<run_id>/findings-cycle-<N>.json` (format in act-phase).
2. System check: `<archeflow-root>/lib/archeflow-shadow.sh check-system <run_id>`. Exit 0: apply the corrective action from `archeflow:shadow-detection`.
3. Cycle 2+: `<archeflow-root>/lib/archeflow-convergence.sh score .archeflow/artifacts/<run_id>/findings-cycle-<N>.json .archeflow/artifacts/<run_id>/findings-cycle-<N-1>.json > .archeflow/artifacts/<run_id>/convergence-cycle-<N>.json`
4. Cycle 3+: `<archeflow-root>/lib/archeflow-convergence.sh oscillation .archeflow/artifacts/<run_id>/findings-cycle-<N>.json .archeflow/artifacts/<run_id>/findings-cycle-<N-1>.json .archeflow/artifacts/<run_id>/findings-cycle-<N-2>.json`
5. Wiggum Break check: `<archeflow-root>/lib/archeflow-convergence.sh wiggum-check <run_id>`. Exit 0 = break: emit `wiggum.break` with its JSON, then hard: stop now; soft: finish this step, then stop. Keep the branch, report to the user, go to Completion.
6. Decide (act-phase Step 3): all approved -> **Merge** below. Issues and cycles left -> write `act-feedback.md`, move this cycle's `plan-*`, `do-*`, `check-*`, `act-*` files to `cycle-<N>/` (findings and convergence files stay), emit `cycle.boundary`, N+1, back to Plan. No cycles left or escalation -> report the open findings, keep the branch, go to Completion.

### Merge

1. `pre-merge` hook, if defined (`fail_action: abort` stops here).
2. **Confirm:** unless `git.auto_merge: true` is set in the config, ask the user: "Merge `<run-branch>` into `<base>`?" and, if `test_command` is set, "and run `<test_command>` there?". Without a yes (or with nobody to ask), do not merge: report the branch name and go to Completion with status `awaiting_merge`.
3. `<archeflow-root>/lib/archeflow-git.sh merge <run_id>`. It merges from the run branch into the base branch it recorded (strategy `git.merge_strategy`, default `no-ff`) and leaves you on the base branch. A conflict aborts the merge and returns you to the run branch: report it, never force-resolve.
4. Post-merge tests, only if `test_command` is set: `<archeflow-root>/lib/archeflow-rollback.sh <run_id>`. Exit 0: tests pass. Exit 1: tests failed and the merge was reverted, which is a hard Wiggum Break: stop and report. Exit 3: tests failed and nothing was reverted: stop and report. Not set: say "post-merge tests skipped (no test_command)".
5. After a merge with passing or skipped tests: `post-merge` hook, if defined, then `<archeflow-root>/lib/archeflow-git.sh cleanup <run_id>`. It deletes the run branch and `.archeflow/runs/<run_id>/`; artifacts and events stay.

## 5. Completion

1. Emit `run.complete` with `{"status": ..., "cycles": ..., "agents_total": ..., "fixes_total": ...}`.
2. `<archeflow-root>/lib/archeflow-memory.sh regression-check .archeflow/events/<run_id>.jsonl`
3. `<archeflow-root>/lib/archeflow-memory.sh extract .archeflow/events/<run_id>.jsonl`
4. `<archeflow-root>/lib/archeflow-memory.sh decay`
5. `<archeflow-root>/lib/archeflow-score.sh extract .archeflow/events/<run_id>.jsonl`
6. Append the run to the index: `jq -cn --arg run_id <run_id> --arg status <status> --rawfile task .archeflow/artifacts/<run_id>/task.md '{run_id: $run_id, status: $status, task: $task, ts: (now | todate)}' >> .archeflow/events/index.jsonl`
7. Report: `<archeflow-root>/lib/archeflow-report.sh .archeflow/events/<run_id>.jsonl --summary`, then a short summary: branch or merge commit, findings left, where the artifacts are.
8. `run-complete` hook, if defined.

## Errors

- An agent does not return (host timeout): emit `agent.failed`, retry once, then stop and report. Three failures in a row are a hard Wiggum Break.
- An artifact cannot be written: stop and report (phases hand over through artifacts).
- Merge conflict, failed integration, failed post-merge tests: never force anything; the run branch stays for the user.

## Before you report

Check that you ran, for this run: `init`, `run.start`, per cycle `worktree` + `integrate` + the
failure-mode check of every agent + evidence gate + `findings-cycle-<N>.json` + `check-system` +
`wiggum-check`, then either Merge (or `awaiting_merge`) and all of Completion. If you skipped a
step, say which one and why in the report.
