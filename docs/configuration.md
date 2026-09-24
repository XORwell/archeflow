# Configuration

ArcheFlow keeps its per-project state and configuration in `.archeflow/` in your repository.
Most of it is read by the agent that follows the skills; a few keys are read by the Bash scripts
in `lib/`. The tables below say which is which, because only the script-read keys have exactly
defined behaviour.

`lib/archeflow-init.sh <bundle>` creates a minimal setup. Bundles: `quick-fix`,
`backend-feature`, `security-review` (`archeflow-init.sh --list` shows them, plus any saved in
`.archeflow/templates/` or `~/.archeflow/templates/`).

## `.archeflow/config.yaml`

A complete example:

```yaml
strategy: auto              # pdca (cyclic), pipeline (linear) or auto

costs:
  budget_usd: 10.00         # per run
  per_agent_usd: 2.00
  warn_at_percent: 80

git:
  enabled: true
  branch_prefix: "archeflow/"
  auto_merge: false         # true: merge without asking after the reviewers approve
  merge_strategy: no-ff     # no-ff | squash | rebase
  commit_style: conventional  # conventional | simple
  auto_push: false
  # signing_key: ~/.ssh/id_ed25519.pub

test_command: "npm test"    # used by archeflow-rollback.sh after a merge

memory:
  enabled: true
  inject_threshold: 2       # a lesson must have been seen this often before it is injected
  max_lessons: 10
  decay_after_runs: 10

models:
  default: sonnet
  # archetypes:
  #   explorer: haiku
  #   guardian: sonnet
  # workflows:
  #   fast:
  #     default: haiku

# lenses: [security]
# patterns:
#   check: cascade
```

| Key | Read by | Meaning |
|-----|---------|---------|
| `costs.budget_usd` | `archeflow-convergence.sh`, agent | Budget per run in USD. At more than 95% spent, `wiggum-check` reports a soft break. |
| `costs.per_agent_usd`, `costs.warn_at_percent` | agent | Per-agent cap and warning threshold (`cost-tracking` skill). |
| `git.branch_prefix`, `git.merge_strategy`, `git.commit_style`, `git.auto_push`, `git.signing_key` | `archeflow-git.sh` | Run branch prefix (default `archeflow/`), how a finished run is merged (default `no-ff`), commit message style, whether run branches are pushed (default `false`), which key signs commits. |
| `git.enabled` | agent | Whether a run works on its own branch. |
| `git.commit_artifacts` | agent | Default `false`: a run commits nothing under `.archeflow/`. `true` also commits events and artifacts to the run branch. |
| `git.auto_merge` | agent | Default `false`: after the reviewers approve, the run asks you before merging into the base branch. `true` merges without asking. |
| `test_command` (top level) | `archeflow-rollback.sh` | Command that must pass after a merge. If it fails, the merge commit of that run is reverted. Runs with `bash -c`. Unset: post-merge tests are skipped. `/archeflow:init` asks for it. |
| `models.*` | agent | Model per role and per workflow. Resolution order: per-workflow per-role, per-workflow default, per-role, global default. |
| `memory.*` | agent | How cross-run lessons are injected. |
| `strategy`, `lenses`, `patterns` | agent | See below. |

`config.yaml` is trusted configuration: `test_command` is executed and the git settings are
used as given. Review it before running ArcheFlow in a repository you did not write (see
[SECURITY.md](../SECURITY.md)).

## Workflows, teams, roles, domains

| Directory | Contents | Format reference |
|-----------|----------|------------------|
| `.archeflow/workflows/` | Workflow descriptions: which roles run in each phase, exit condition, max cycles | [examples/custom-workflow.yaml](../examples/custom-workflow.yaml), `templates/bundles/*/workflow.yaml` |
| `.archeflow/teams/` | Team presets: a named list of roles | `templates/bundles/*/team.yaml` |
| `.archeflow/archetypes/` | Your own roles, for example a database reviewer | `custom-archetypes` skill |
| `.archeflow/domains/` | Domain adapters (code, writing, research) that rename concepts and change review focus | `domains` skill |

Note: `/archeflow:run` selects one of the three built-in workflows (`fast`, `standard`,
`thorough`, or `--workflow`). It does not yet load files from `.archeflow/workflows/`; the
`workflow-design` skill uses them when you design a workflow with Claude.

A custom role is a Markdown file with frontmatter, in the same shape as the files in
[`agents/`](../agents/):

```markdown
---
name: db-specialist
description: Reviews database schemas and migration safety
model: sonnet
---

You are the **Database Specialist**. Check migrations for data loss, locking and rollback.
```

## Lenses

A lens adds review focus on top of the domain: extra finding categories, extra instructions per
role, evidence rules and model overrides. Built-in lenses are in [`lenses/`](../lenses/):
`security`, `prose-voice`, `compliance-gdpr`. Use them per run (`--lens security --lens
compliance-gdpr`) or in `config.yaml` (`lenses: [security]`).

Lenses stack left to right: list values are merged, scalar values from the later lens win.
Project lenses in `.archeflow/lenses/<name>.yaml` override built-in lenses with the same name.
The format is in [`lenses/SCHEMA.md`](../lenses/SCHEMA.md).

```bash
<archeflow-root>/lib/archeflow-lens.sh list
<archeflow-root>/lib/archeflow-lens.sh validate my-lens
<archeflow-root>/lib/archeflow-lens.sh merge security compliance-gdpr    # merged config as JSON
```

A lens can inject files into agent prompts (`context_inject`). A lens from someone else's
repository can therefore point agents at files you do not want sent to a model; review project
lenses like any other configuration.

## Patterns

A pattern sets how the agents of one phase interact, independent of which roles they are.
Definitions are in [`patterns/`](../patterns/) (format: [`patterns/SCHEMA.md`](../patterns/SCHEMA.md)).

| Pattern | Shape | Default for |
|---------|-------|-------------|
| `sequential` | A, then B, then C; each sees the previous output | Plan |
| `parallel-merge` | all at once, findings merged | Check |
| `cascade` | one after another, stop as soon as a reviewer finds nothing | |
| `debate` | two agents argue opposing briefs, a third decides | |

```yaml
patterns:
  plan: debate
  check: cascade
```

## Local models (Ollama)

To run role turns on a local model instead of the Claude API, merge
[`examples/config-local-ollama.yaml`](../examples/config-local-ollama.yaml) into `config.yaml`:
`models.provider: ollama` and a mapping from the logical models (`haiku`, `sonnet`, `opus`) to
Ollama tags. The run skill then calls `lib/archeflow-ollama.sh chat <tag> --system-file
agents/<role>.md` for each turn.

```bash
ollama serve
ollama pull qwen3:8b
<archeflow-root>/lib/archeflow-ollama.sh health
```

Only loopback addresses are contacted unless `ARCHEFLOW_OLLAMA_ALLOW_REMOTE=1` is set, because the
base URL can come from a repository's `config.yaml` and every prompt goes to that host.

## Langfuse (optional)

`lib/archeflow-langfuse.sh` forwards run events to [Langfuse](https://langfuse.com) for tracing.
It is off unless enabled, and it never blocks a run. Configuration comes from exactly one source:

1. the environment, when `LANGFUSE_ENABLED=true` is set there (`LANGFUSE_HOST`,
   `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`); otherwise
2. the first `langfuse.env` file found in `<repo>/.archeflow/langfuse.env` (only if the file is
   not tracked by git), `${XDG_CONFIG_HOME:-~/.config}/archeflow/langfuse.env`, or
   `~/.archeflow/langfuse.env`.

The host must use `https://`, or `http://` on a loopback address. A template is in
`.archeflow/langfuse.env.example`. Past runs can be sent with
`lib/archeflow-langfuse-backfill.sh <run_id>` or `--all`.

## Environment variables

| Variable | Effect |
|----------|--------|
| `ARCHEFLOW_SHADOWS=off` | Disable the failure-mode checks in `archeflow-shadow.sh` |
| `ARCHEFLOW_TASK_WORDS` | Expected proposal size for the Creator's scope check (skipped if unset) |
| `ARCHEFLOW_MODEL_PROVIDER=ollama` | Treat the run as local (cost recorded as USD 0) |
| `ARCHEFLOW_OLLAMA_BASE_URL` | Full Ollama base URL; wins over `OLLAMA_HOST` |
| `OLLAMA_HOST` | Ollama address (`host:port` or URL), as for the `ollama` CLI |
| `ARCHEFLOW_OLLAMA_ALLOW_REMOTE=1` | Allow a non-loopback Ollama host |
| `ARCHEFLOW_A2A_BIND` | Listen address for `archeflow-a2a.sh serve` (default 127.0.0.1) |
| `LANGFUSE_ENABLED`, `LANGFUSE_HOST`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` | Langfuse export, see above |

The pre-0.10 spellings `ARCHFLOW_MODEL_PROVIDER` and `ARCHFLOW_OLLAMA_BASE_URL` are still read as
a fallback.

## Interoperability

These scripts are optional and not used by a normal run.

**A2A agent card.** `lib/archeflow-a2a.sh generate` writes `.archeflow/agent-card.json`, a JSON
description of the seven roles in the format of the [A2A protocol](https://a2aproject.github.io/A2A/).
`validate` checks a card; `serve --port 8099` serves it at `/.well-known/agent-card.json` on
127.0.0.1 (needs `nc`; `--bind <addr>` or `ARCHEFLOW_A2A_BIND` changes the address). The card makes the roles discoverable; there is no endpoint that accepts
tasks.

**GNAP.** `lib/archeflow-gnap.sh` converts the sprint queue to and from
[GNAP](https://github.com/farol-team/gnap) task files in `.gnap/` (`init`, `export`, `import`,
`sync`, `status`). See [queue.md](queue.md#gnap-export).

**Merge queue.** `lib/archeflow-merge-queue.sh` merges several finished branches one by one in
priority order and marks branches that touch the same files as `blocked` (`enqueue <branch>
[--priority N]`, `check`, `merge`, `drain`, `status`, `reset`).
