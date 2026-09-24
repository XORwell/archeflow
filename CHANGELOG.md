# Changelog

All notable changes to ArcheFlow are documented in this file.

## [0.11.0] -- 2026-09-24

A hardening release: the plugin now installs and works from a clean machine, the documented
commands exist, runs ask before merging, and a number of security problems are fixed. If you use ArcheFlow on repositories you
did not write, update.

### Commands
- All commands ship with the plugin and use the plugin namespace: `/archeflow:review`,
  `/archeflow:run`, `/archeflow:init`, `/archeflow:status`, `/archeflow:dag`,
  `/archeflow:report`, `/archeflow:replay`, `/archeflow:score`, `/archeflow:memory`,
  `/archeflow:sprint`, `/archeflow:scan`. The `/af-*` names used in earlier documentation only
  worked with a private setup and are gone. In Cursor: `/archeflow-review`, `/archeflow-run`,
  `/archeflow-sprint`.
- `/archeflow:init` is new (it was documented before but did not exist). It asks for your test
  command and writes `.archeflow/.gitignore`.
- `/archeflow:scan` replaces the queue-maintain skill.

### Changed behaviour
- A run now merges into your branch only after you confirm (`git.auto_merge: false` is the
  default). The default merge strategy is `no-ff` (was `squash`).
- The run's git flow works end to end: run branch `archeflow/<run_id>`, the Maker in its own
  worktree, its commits integrated into the run branch, then merge, post-merge tests and cleanup.
  A run refuses to start on uncommitted tracked changes instead of stashing them.
- Agents inherit your session's permission mode. The Maker no longer asks for
  `bypassPermissions`.
- The sprint is attended unless you ask for autonomous mode in the session; `mode: AUTONOMOUS`
  in `queue.json` no longer enables it. Items found by `/archeflow:scan` or imported from GNAP
  are `proposed` and run only after you approve them. Sprint agents work on a branch
  `sprint/<item-id>` per project and never merge.
- Spawned agents use the role definitions in `agents/` (`archeflow:<role>` agent types).

### Security
- Numbers read from event logs, lesson files and other `.archeflow/` data can no longer execute
  shell code. Previously a crafted value in a committed `.archeflow/events/*.jsonl` or
  `.archeflow/memory/lessons.jsonl` ran commands when you opened a report, a DAG or after a run.
- Langfuse export: settings come only from the environment or your user-level
  `~/.config/archeflow/langfuse.env` (or `~/.archeflow/langfuse.env`), never from the project,
  whether committed, symlinked or a case variant. Only `https://` hosts (or `http://` on
  loopback) are accepted. Before, a repository could redirect your Langfuse keys and run data to a
  host of its choice. Move a project-local file to `~/.config/archeflow/langfuse.env`.
- Ollama: only loopback hosts are contacted unless you set `ARCHEFLOW_OLLAMA_ALLOW_REMOTE=1`, so a
  repository's `config.yaml` cannot send your prompts elsewhere.
- GNAP import no longer changes existing queue items; imported tasks arrive as `proposed`.
- `archeflow-rollback.sh` reverts only the merge commit of the run it was given, never one of
  your own commits.
- Writes refuse to follow symlinks planted in `.archeflow/`.
- Lens `context_inject` entries must be relative paths inside the project, so a lens cannot put
  files such as `~/.ssh/...` into agent prompts.
- `git.branch_prefix` is validated (a prefix like `+x/` could force-push), data-derived git refs
  are passed after `--end-of-options`, and the merge queue rejects unknown merge strategies instead
  of marking unmerged branches as merged.
- Hook commands from `.archeflow/hooks.yaml` are shown and confirmed before their first run in a
  session.
- A run can no longer change ArcheFlow's own configuration: Maker commits touching
  `.archeflow/` are refused at integrate; merge refuses `.archeflow/` changes other than the run's
  own artifacts and events, and refuses if config, hooks, lenses or lessons changed during the run.
- Post-merge tests run the `test_command` recorded at run start; if `config.yaml` changed, nothing
  runs. A test command that is missing or not executable is a configuration error, not a failed
  test, and never reverts a merge.
- Scripts refuse to run when `.archeflow/` or a state directory is a symlink or resolves outside
  the repository; writes check every path component.
- Guardian, Skeptic, Sage, Trickster, Explorer and Creator have read-only tools; code under review
  is not executed without your explicit confirmation of the exact command.
- `git.auto_merge`, `multi-run.yaml`, `queue.md` and hook commands need your confirmation in the
  session; `SECURITY.md` lists every repository file that can remove the merge gate or start
  unattended work.
- The Ollama base URL, model names and configured lenses are read and validated by the scripts
  (`archeflow-ollama.sh chat --tier`, `archeflow-lens.sh merge --from-config`), never pasted into
  a shell line. Lens `context_inject` accepts plain relative paths only.
- `/archeflow:scan` never runs project code.
- The evidence gate keeps `<file>.orig` before rewriting a review and logs each downgrade as an
  `evidence.downgrade` event.
- `SECURITY.md` describes the attacker model (repository content is untrusted) and what the
  scripts do and do not guarantee. A fuzz test feeds injection payloads through every script
  that reads `.archeflow/` data.
- Git signing key from config is passed as a single argument; run IDs and bundle names are
  validated before they are used in paths (no `rm -rf` or copies outside `.archeflow/`);
  `archeflow-review.sh` rejects option-like `--commit` values; `archeflow-a2a.sh serve` listens
  on 127.0.0.1 by default.
- `langfuse.env` is parsed as data instead of being sourced, and the secret key no longer
  appears in process arguments.

### Fixed
- The plugin installs from its own marketplace (`/plugin marketplace add XORwell/archeflow`) and
  finds its scripts after installation: skills call `<archeflow-root>/lib/...`, and the
  session-start hook tells the agent where the plugin lives.
- The failure-mode checks match their documented rules: "e.g."/"i.e." no longer count as file
  references, repeated Skeptic concerns are counted correctly, the Guardian "Paranoid" and
  Wiggum Break thresholds are applied as documented, and the budget break reads
  `costs.budget_usd`.
- The Maker failure-mode check reads the run diff (`detect maker --diff`, now required) and counts
  code files only; before, it could never fire in a real run, and on a diff it fired on any change.
- Tunnel Vision no longer fires on clean or single-reviewer runs; Echo Chamber counts only the
  current cycle.
- Reports and DAGs are complete after real runs: `archeflow-event.sh` links parents
  automatically, the DAG draws every event, the report reads the documented fields and derives
  team and duration; `wiggum-check` and `check-system` log their own events.
- `wiggum-check` includes the oscillation check; the default cycle limits per workflow and which
  checks they allow are documented.
- Cycle 2+ keeps the plan and the Act feedback available to the next cycle.
- `/archeflow:review` includes new untracked files and detects the base branch.
- A quoted `test_command` (`'npm test'`) is parsed correctly.
- `archeflow-git.sh init` resumes an existing run with the same id, so `--dry-run` followed by
  `--start-from do` works.
- Merges approved later are recorded (`run.merged`, index status `merged`); the merge commit is
  titled `archeflow: merge run <id>`.
- The run skill waits for every agent (foreground), so `claude -p` no longer returns early.
- The shipped `.archeflow/config.yaml` and the bundles match the documented defaults.
- `merge_strategy: rebase` works. Event, memory and queue writes are locked against concurrent
  writers.

### Changed
- The generated `.archeflow/.gitignore` keeps run state local (events, artifacts, runs,
  worktrees, memory, review diffs, progress, agent card).
- Removed `git.commit_artifacts` (it was never read) and `archeflow-rollback.sh --to`
  (use `archeflow-git.sh rollback`).
- The session-start hook is Bash and jq instead of Node.js.
- Portability: runs the same on any locale and with the jq of current Debian and Ubuntu
  releases (1.6 and 1.7), without `yq`, PyYAML or `bc`. The default branch is detected instead of assuming `main`; a detached HEAD is refused.
- Canonical environment variable names are `ARCHEFLOW_MODEL_PROVIDER` and
  `ARCHEFLOW_OLLAMA_BASE_URL`; the old `ARCHFLOW_*` spellings still work.
- Documentation rewritten: README (what it is, status, first steps, concepts), a queue format
  reference (`docs/queue.md`, `examples/queue.json`), configuration and script references,
  a contributor guide (`CLAUDE.md`), `SECURITY.md`.

### Removed
- `examples/gitea-ci.yml`: unrelated to ArcheFlow and unsafe to copy (it interpolated issue
  text into a shell script and ran with write tokens).
- Research material (evaluation data, experiments, paper drafts) is no longer part of the plugin
  repository.

## [0.10.0] -- 2026-04-09

### Added
- **Local models (Ollama):** `lib/archeflow-ollama.sh` (`health`, `tags`, `chat`) for scripted archetype turns with zero API cost; `examples/config-local-ollama.yaml` for `models.provider` + `models.mapping`; run / cost-tracking / using-archeflow skills and README updated.
- **Lenses**: stackable attention modifiers that layer onto domains. Lenses add finding categories, context injection, attention weights, evidence rules, and model overrides per archetype. Multiple lenses compose left-to-right (`--lens security --lens compliance-gdpr`). Schema in `lenses/SCHEMA.md`.
- Built-in lenses: `security` (OWASP focus, CVE evidence rules), `prose-voice` (voice drift, dialect breaks), `compliance-gdpr` (PII, consent, retention).
- `archeflow-lens.sh` lib script: `list`, `show`, `validate`, `merge`, `resolve`. Merge produces combined JSON config from N lens YAML files with union arrays, last-wins scalars, concatenated focus strings.
- **Patterns**: configurable agent interaction shapes per phase. Patterns define HOW agents interact (debate, cascade, sequential, parallel-merge) independently of WHICH archetypes participate.
- `debate` pattern: two agents argue opposing positions in parallel, a third synthesizes. Directly counters Over-Architect shadow by forcing a minimalist perspective.
- `cascade` pattern: agents run in sequence, stopping early when clean. Formalizes the Guardian A2 fast-path as a general-purpose, user-configurable pattern.
- `sequential` and `parallel-merge` patterns documented as explicit defaults (Plan and Check phases respectively).
- `archeflow-version.sh` lib script: extracts latest version from CHANGELOG.md (no more hardcoded version strings).
- Run skill updated: `--lens` and `--pattern` flags, lens application protocol (context injection, attention modifiers, evidence rules, model/shadow overrides), pattern application protocol (debate spawn template, cascade stop conditions).

## [0.9.0] -- 2026-04-06

### Added
- Run replay: `decision.point` events via `archeflow-decision.sh`; `archeflow-replay.sh` with `timeline`, `whatif` (weighted archetype weights + threshold), and `compare`; skill `af-replay`; DAG labels for `decision.point`.

## [0.7.0] -- 2026-04-04

### Added
- Context isolation protocol in attention-filters skill and all 7 agent personas — agents receive only orchestrator-constructed context, no session bleed or cross-agent contamination
- Structured status tokens (`STATUS: DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, `BLOCKED`) for all agents with orchestrator parsing protocol in run skill
- Evidence-gated verification in check-phase — CRITICAL/WARNING findings require concrete evidence (command output, code citations, reproduction steps); banned speculative phrases auto-downgrade to INFO
- Plan granularity constraint in plan-phase and Creator — each change item must be a 2-5 minute task with exact file path, code block, and verify command
- Strategy abstraction with `pdca` (cyclic) and `pipeline` (linear) execution strategies, auto-selection by task type, and pipeline execution flow in run skill
- Experimental status note in README

## [0.6.0] -- 2026-04-04

### Added
- Expanded attention-filters skill with prompt templates, token budgets, cycle-back filtering, and verification checklist
- Explorer skip heuristic in plan-phase with decision table for when to skip/require research
- Runnable quickstart example (`examples/runnable-quickstart.md`)

### Fixed
- Normalized agent persona frontmatter: added examples, moved isolation note to Rules, documented model choices

## [0.5.0] -- 2026-04-04

### Added
- Lib script validation at run initialization — fail fast if required scripts or `jq` are missing
- Hook points documentation with 6 lifecycle events (run-start, phase-complete, agent-complete, pre-merge, post-merge, run-complete) and config template
- Phase rollback support in `archeflow-rollback.sh` via `--to <phase>` flag
- Per-workflow model assignment configuration with fallback chain (per-workflow per-archetype > per-workflow default > per-archetype > global default)
- Cross-run finding regression detection in `archeflow-memory.sh` — compares current findings against previously resolved fixes
- Check-phase parallel reviewer spawning protocol with Guardian-first sequence, A2 fast-path evaluation, timeout handling, and re-check protocol

## [0.4.0] -- 2026-04-04

### Added
- Confidence gate parsing with bash snippets for extracting scores from `plan-creator.md`
- Mini-Explorer spawning when risk coverage < 0.5
- Worktree merge flow with explicit pre-merge hooks and post-merge test validation
- `archeflow-rollback.sh` for post-merge test failure auto-revert
- Test-first validation gate in Do phase
- Memory injection audit trail with `--audit` flag and `audit-check` command

### Fixed
- Unified feedback routing tables across orchestration, act-phase, artifact-routing

## [0.3.0] -- 2026-04-03

### Added
- Automated PDCA execution loop (`archeflow:run`) with `--start-from` and `--dry-run` support
- Event-sourced process logging (`archeflow:process-log`) with DAG parent relationships
- ASCII DAG renderer (`archeflow-dag.sh`) with color output
- Markdown process report generator (`archeflow-report.sh`) with summary and DAG modes
- Live progress file (`archeflow:progress`) watchable from a second terminal
- Domain adapter system (`archeflow:domains`) for writing, research, and custom domains
- Cost tracking skill (`archeflow:cost-tracking`) with budget enforcement and model tier recommendations
- Cross-run memory system (`archeflow:memory`) that learns recurring findings and injects lessons
- Convergence detection (`archeflow:convergence`) to prevent wasted cycles from stalling or oscillation
- Bridge skill for an external writing tool (removed in a later release)
- Template gallery (`archeflow:templates`) with init, save, clone, and list operations
- Archetype effectiveness scoring (`archeflow:effectiveness`) across signal-to-noise, fix rate, cost efficiency
- Git-per-phase commit strategy (`archeflow:git-integration`) with branch-per-run and rollback
- Multi-project orchestration (`archeflow:multi-project`) with dependency DAG and shared budget
- Act phase skill (`archeflow:act-phase`) for post-Check decision logic and fix routing
- Artifact routing skill (`archeflow:artifact-routing`) for inter-phase artifact management
- `archeflow-event.sh` -- structured JSONL event appender
- `archeflow-git.sh` -- per-phase commits, branch creation, merge, and rollback
- `archeflow-init.sh` -- template gallery script (init, save, clone, list)
- `archeflow-memory.sh` -- cross-run memory management (add, list, decay, forget)
- `archeflow-progress.sh` -- live progress file generator
- `archeflow-score.sh` -- archetype effectiveness scoring from completed runs
- Short fiction workflow example with custom story roles (removed in a later release)

## [0.2.0] -- 2026-04-03

### Added
- Plugin consolidation into single shareable `archeflow/` directory
- Workflow intelligence with conditional escalation, fast-path, and confidence triggers
- Quality loop with self-review, convergence detection, dedup, and completion promises
- Parallel teams with auto-resume and budget scheduling
- Extensibility: archetype composition, team presets, hook points, workflow templates
- Mini-reflect fallback for small single-file changes that do not need a full run
- Comprehensive README with install, usage, debugging, and examples
- DX improvements: structured confidence, alternatives surfacing

### Fixed
- Redesigned adaptation rules per Guardian review to resolve race conditions
- Synced Creator agent definition with orchestration skill expectations
- Wired hooks correctly and added cost table documentation

## [0.1.0] -- 2026-04-02

### Added
- Initial release: 7 roles (Explorer, Creator, Maker, Guardian, Skeptic, Trickster, Sage)
- PDCA orchestration engine with fast, standard, and thorough workflows
- Shadow detection with quantitative heuristics per archetype
- Cross-cycle structured feedback with routing and resolution tracking
- Attention filters for per-archetype context optimization
- Autonomous mode for unattended overnight sessions
- Custom archetypes and workflow design skills
- SessionStart hook for automatic activation
- `archeflow-dag.sh` and `archeflow-report.sh` process visualization scripts

### Changed
- Removed ArcheHelix branding, adopted plain PDCA language
- Trimmed phase skills to reduce token waste
- Simplified to one shadow per archetype for clearer detection

### Fixed
- Rewrote SessionStart hook in pure Node for portability (no bash/awk/sed dependencies)
- Made hook robust with graceful fallbacks (no `set -e`)
- Corrected repository URLs
