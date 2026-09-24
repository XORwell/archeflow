# ArcheFlow Run: reference

Reference material for `SKILL.md` in this directory. The main flow is in `SKILL.md`; this
file covers optional features, the event schema and the artifact list.

## Events

Emit with `<archeflow-root>/lib/archeflow-event.sh <run_id> <type> <phase> <agent> "$(cat .archeflow/artifacts/<run_id>/event.json)" [parent_seqs]`,
after writing the `data` object to `event.json` with your file tool. `<agent>` is the role name or `""`.
The script prints nothing on success; the event's `seq` is the line count of
`.archeflow/events/<run_id>.jsonl`.

| When | Type | Data |
|------|------|------|
| Run starts | `run.start` | task, workflow, max_cycles, lenses, patterns, model_provider |
| Before an agent | `agent.start` | archetype, model, prompt_summary |
| After an agent | `agent.complete` | archetype, duration_ms, artifacts, summary, estimated_cost_usd |
| Agent did not return | `agent.failed` / `agent.timeout` | archetype, reason |
| Phase boundary | `phase.transition` | from, to |
| Choice between alternatives | `decision` | what, chosen, alternatives, rationale |
| Orchestrator decision (for replay) | `decision.point` | archetype, input, decision, confidence |
| Reviewer verdict | `review.verdict` | archetype, verdict, findings[] (location, severity, category, description) |
| Fix verified in a later cycle | `fix.applied` | source, finding, file, line |
| End of a cycle | `cycle.boundary` | cycle, max_cycles, exit_condition, convergence |
| Failure mode found | `shadow.detected` | written by `archeflow-shadow.sh detect --run-id` |
| Circuit breaker | `wiggum.break` | the JSON printed by `wiggum-check` |
| Run ends | `run.complete` | status, cycles, agents_total, fixes_total |

Parents: `run.start` has none. An agent's events point to the event that started it; a phase
transition points to all events that completed the phase; parallel agents share a parent.
`archeflow-dag.sh` renders events without parents at the root.

## Artifacts (`.archeflow/artifacts/<run_id>/`)

| File | Written by | Content |
|------|-----------|---------|
| `task.md` | orchestrator | the task text, verbatim |
| `event.json` | orchestrator | scratch file for the next event's data |
| `plan-explorer.md` | Explorer | research (not in `fast`) |
| `plan-creator.md` | Creator | proposal with `### Confidence` table |
| `plan-mini-explorer.md` | Explorer | risk research (confidence gate only) |
| `do-maker.md` | Maker | implementation report |
| `do-maker.diff`, `do-maker-files.txt` | `archeflow-git.sh integrate` | run diff against the base branch, changed paths |
| `check-<role>.md` | reviewers | verdict and findings |
| `findings-cycle-<N>.json` | orchestrator (Act) | consolidated findings of cycle N |
| `convergence-cycle-<N>.json` | `archeflow-convergence.sh score` | convergence of cycle N vs N-1 |
| `act-feedback.md` | orchestrator (Act) | routed issues for the next cycle |
| `lens-config.json` | `archeflow-lens.sh merge` | merged lenses (only with lenses) |
| `cycle-<N>/` | orchestrator | archived plan/do/check/act files of cycle N |

Run metadata (base branch) is in `.archeflow/runs/<run_id>/`, the Maker's worktree in
`.archeflow/worktrees/<run_id>/` (ignored by git), events in `.archeflow/events/<run_id>.jsonl`.
None of these are committed unless you set `git.commit_artifacts` (see `archeflow:git-integration`).

## Lenses

With `--lens <name>` flags or `lenses:` in the config, before Plan:
`<archeflow-root>/lib/archeflow-lens.sh merge <lens1> [<lens2>...] > .archeflow/artifacts/<run_id>/lens-config.json`

Apply the merged config to every agent spawn (schema: `<archeflow-root>/lenses/SCHEMA.md`):

1. `context_inject.always` and `context_inject.<phase>`: read those files and append them to the
   prompt. Only paths inside the project; skip missing files with a warning.
2. `attention.<role>`: `weight` scales the token budget, `extra_focus` is appended to the review
   focus, `extra_categories` adds finding categories.
3. Lens evidence rules apply in addition to the standard ones.
4. Lens model overrides beat config models; a CLI `--model` beats both.

The lens config does not change during the run.

## Patterns

With `--pattern <phase>:<name>` or `patterns:` in the config (definitions in
`<archeflow-root>/patterns/` or `.archeflow/patterns/`, schema in `patterns/SCHEMA.md`):

- **debate**: spawn advocate and critic in parallel with opposing briefs, then a judge with both
  outputs. Save `<phase>-debate-advocate.md`, `-critic.md`, `-judge.md`; the judge's is canonical.
- **cascade** (usually Check): run reviewers one after another; stop when CRITICAL and WARNING
  counts are at or below `stop_when`. Never skip in the cases listed in `never_skip`.
- **sequential** (default for Plan) and **parallel-merge** (default for Check after Guardian):
  the default behaviour in `SKILL.md`.

## Local models (Ollama)

If `models.provider: ollama` or `ARCHEFLOW_MODEL_PROVIDER=ollama`: map haiku/sonnet/opus through
`models.mapping` (defaults `qwen3:8b`, `qwen3:14b`, `qwen3:14b`), export
`ARCHEFLOW_OLLAMA_BASE_URL` from `models.ollama.base_url` if set, and check
`<archeflow-root>/lib/archeflow-ollama.sh health` before the run. For each role, write the user
content to a file and run
`<archeflow-root>/lib/archeflow-ollama.sh chat <ollama-tag> --system-file <archeflow-root>/agents/<role>.md < <input-file> > .archeflow/artifacts/<run_id>/<artifact>.md`.
Append `STATUS: DONE` if the output is complete but has no status line. Local runs cannot spawn
the Maker as an agent with tools: use the host's own agent for the Maker.

## Pipeline strategy

For bug fixes and single-concern tasks (`--strategy pipeline`, `strategy: pipeline`, or a task
that says fix/bug/patch/hotfix): no cycles.

1. Creator with the fast-workflow reflection (no Explorer).
2. Maker, worktree and integrate exactly as in `SKILL.md` Do.
3. Guardian; Skeptic only if Guardian has findings.
4. Sage.
5. 0 CRITICAL: Merge as in `SKILL.md`. CRITICAL: one targeted Maker round, review again; still
   CRITICAL: stop and report the branch. WARNINGs are logged, they do not block.

## Progress display

```
━━━ ArcheFlow Run: <task> ━━━━━━━━━━━━━━━━━━━
Run ID: <run_id> | Workflow: standard | Cycle: 1/2
[Plan]  Explorer researching...        -> done (35s)
[Plan]  Creator designing proposal...  -> done (confidence 0.8)
[Do]    Maker implementing...          -> done (4 files, 8 tests)
[Check] Guardian reviewing...          -> APPROVED
[Act]   All approved, merging...       -> merged into main
━━━ Complete: 1 cycle ━━━━━━━━━━━━━━━━━━━━━━━
```

## Effectiveness scores and replay

`archeflow-score.sh extract` (Completion) scores each reviewer on signal-to-noise (0.30), fix
rate (0.25), cost efficiency (0.20), accuracy (0.15) and cycle impact (0.10) and appends to
`.archeflow/memory/effectiveness.jsonl`; see `/archeflow:score`. Emit `decision.point` events
after routing, fast-path and escalation choices so `/archeflow:replay` can show the decision
timeline and weighted what-if.
