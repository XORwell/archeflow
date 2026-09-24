# Library scripts

The skills call these Bash scripts for everything that should be deterministic. They can also
be used on their own. Run them from your project root: they read and write `.archeflow/` in the
current directory. In the commands below, `lib/` means the `lib/` directory of the ArcheFlow
plugin (inside Claude Code, the session context names it as "ArcheFlow root").

Each script documents its usage in its header comment. Requirements: Bash 4+, jq, git; `curl`
for the Ollama and Langfuse scripts.

## Run log and reports

| Script | Purpose | Example |
|--------|---------|---------|
| `archeflow-event.sh` | Append an event to `.archeflow/events/<run_id>.jsonl` | `archeflow-event.sh <run_id> agent.complete plan creator '{"duration_ms":1200}' 1` |
| `archeflow-decision.sh` | Log a decision point (phase, role, input, decision, confidence) | `archeflow-decision.sh <run_id> check guardian 'diff' 'needs_changes' 0.85` |
| `archeflow-dag.sh` | Render the run as a tree | `archeflow-dag.sh .archeflow/events/<run_id>.jsonl --color` |
| `archeflow-report.sh` | Markdown report of a run | `archeflow-report.sh .archeflow/events/<run_id>.jsonl --output report.md` |
| `archeflow-progress.sh` | Write `.archeflow/progress.md`; `--watch` refreshes every 2 s | `archeflow-progress.sh <run_id> --watch` |
| `archeflow-replay.sh` | Decision timeline, and a what-if with weighted reviewers | `archeflow-replay.sh compare <run_id> --weights sage=2,guardian=1` |
| `archeflow-score.sh` | Per-role effectiveness across runs | `archeflow-score.sh extract .archeflow/events/<run_id>.jsonl`, then `archeflow-score.sh report` |

`archeflow-event.sh` takes the run ID, event type, phase, agent, a JSON object, and optionally
the comma-separated numbers of parent events. Parents define the tree that `archeflow-dag.sh` draws;
events without parents appear at the top level.

## Checks

| Script | Purpose | Example |
|--------|---------|---------|
| `archeflow-shadow.sh` | Failure-mode checks on one agent's output | `archeflow-shadow.sh detect guardian review.md` |
| `archeflow-evidence.sh` | Check that CRITICAL/WARNING findings carry evidence | `archeflow-evidence.sh validate review.md` |
| `archeflow-convergence.sh` | Convergence between cycles, oscillating findings, Wiggum Break | `archeflow-convergence.sh wiggum-check <run_id>` |

## Git

| Script | Purpose | Example |
|--------|---------|---------|
| `archeflow-git.sh` | Run branch, Maker worktree (`worktree`, `integrate`), merge, rollback, cleanup | `archeflow-git.sh init <run_id>` |
| `archeflow-rollback.sh` | Run `test_command` after a merge and revert this run's merge if it fails; or roll back to a phase | `archeflow-rollback.sh <run_id> --to check` |
| `archeflow-review.sh` | Diff and stats for a review | `archeflow-review.sh --branch feat/rate-limit` |
| `archeflow-merge-queue.sh` | Merge several finished branches in priority order | `archeflow-merge-queue.sh status` |

## Setup and memory

| Script | Purpose | Example |
|--------|---------|---------|
| `archeflow-init.sh` | Set up `.archeflow/` from a bundle, copy from another project, save or list templates | `archeflow-init.sh quick-fix`, `archeflow-init.sh --list` |
| `archeflow-memory.sh` | Lessons across runs: `add`, `list`, `inject`, `extract`, `decay`, `forget` | `archeflow-memory.sh add pattern "Check for null before using optional config values"` |
| `archeflow-lens.sh` | List, show, validate and merge lenses | `archeflow-lens.sh merge security compliance-gdpr` |
| `archeflow-version.sh` | Print the plugin version | `archeflow-version.sh` |

Lesson types for `archeflow-memory.sh add`: `pattern`, `preference`, `archetype_hint`,
`anti_pattern`.

## Integrations

| Script | Purpose | Example |
|--------|---------|---------|
| `archeflow-ollama.sh` | Call a local Ollama model for one role turn | `archeflow-ollama.sh health` |
| `archeflow-langfuse.sh` | Forward one event (stdin) to Langfuse; off unless configured | `echo "$EVENT" \| archeflow-langfuse.sh` |
| `archeflow-langfuse-backfill.sh` | Send the events of past runs to Langfuse | `archeflow-langfuse-backfill.sh --all` |
| `archeflow-a2a.sh` | Generate, validate or serve an A2A agent card | `archeflow-a2a.sh generate` |
| `archeflow-gnap.sh` | Convert the sprint queue to and from GNAP task files | `archeflow-gnap.sh status` |

See [configuration.md](configuration.md) for the settings these scripts read.

## Helpers sourced by other scripts

`archeflow-common.sh` (validation and safe file helpers), `archeflow-lock.sh` (advisory locks)
and `archeflow-yaml.sh` (a small YAML-to-JSON converter, so no `yq` is needed) are not meant to be
called directly.
