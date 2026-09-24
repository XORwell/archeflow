# ArcheFlow

[![Tests](https://github.com/XORwell/archeflow/actions/workflows/test.yml/badge.svg)](https://github.com/XORwell/archeflow/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

ArcheFlow is a Claude Code plugin (also usable from Cursor) that runs a coding task through a
Plan, Do, Check, Act cycle with a fixed set of agent roles: a researcher, a designer, an
implementer working in its own git worktree, and up to four reviewers. Every step is written to
an event log in your repository, and simple rule-based checks flag agent output that looks like a
known failure mode, such as a reviewer that rejects everything or a researcher that never reaches
a recommendation.

> **Status: experimental.** ArcheFlow is a prototype that is being actively changed. Commands,
> prompts, file formats and configuration keys may change between versions without a migration
> path. The failure-mode checks are heuristics (word counts, ratios, pattern matches): the tests
> show that they apply their rules correctly, not that the rules catch real problems reliably.
> Read what the agents did before you merge it.

## Who it is for

ArcheFlow is for developers who already use Claude Code (or Cursor) on multi-file changes and want:

- a **structured review** of an existing diff, branch or commit range by several reviewers with
  different jobs (security and error paths, assumptions, edge cases, maintainability);
- a **repeatable plan, implement, review loop** for larger changes, with the implementation kept
  on a separate branch and an audit trail of what each agent did;
- optionally, a **task queue** worked through across several repositories.

It is not the right tool for one-line fixes, questions about code, or feature work where you want
to make every decision interactively; for that, work with Claude Code directly or use a guided
workflow such as Anthropic's `feature-dev` plugin. A full run spawns several agents and costs
correspondingly more tokens than a single session.

## Requirements

- Claude Code, or Cursor
- Bash 4 or newer (macOS ships 3.2: `brew install bash`)
- jq 1.6 or newer
- git

Optional: `curl` for the Ollama and Langfuse integrations, `nc` for `archeflow-a2a.sh serve`.
CI runs on Ubuntu; macOS is not tested in CI.

The orchestrating session follows long, multi-step skills. Use a strong model for it (for
example Sonnet or Opus class); small models tend to skip bookkeeping steps such as events,
scoring and memory. The role agents it spawns can use cheaper models (see
[docs/configuration.md](docs/configuration.md)).

## Install

### Claude Code

The repository is its own plugin marketplace. Inside Claude Code:

```
/plugin marketplace add XORwell/archeflow
/plugin install archeflow@archeflow
```

or from a shell:

```bash
claude plugin marketplace add XORwell/archeflow
claude plugin install archeflow@archeflow
```

Restart Claude Code (or run `/reload-plugins`). To check the install, open `/plugin` and look at
the "Installed" tab, or run `/archeflow:status`; in a project without ArcheFlow setup it answers
"ArcheFlow is not set up here." and points you to the next step.

By default the plugin is installed for your user, so its session-start hook runs in every
project. Add `--scope project` to the install command to enable it only for the current project.

To try a local checkout without installing: `claude --plugin-dir /path/to/archeflow`.

### Cursor

Cursor has no plugin marketplace, so ArcheFlow is used from a checkout:

```bash
git clone https://github.com/XORwell/archeflow.git ~/archeflow
cp -r ~/archeflow/.cursor /path/to/your/project/
```

This adds three commands, `/archeflow-review`, `/archeflow-run` and `/archeflow-sprint`
(Cursor's names for `/archeflow:review` and so on). They load the same skill files and `lib/`
scripts from the checkout and spawn agents with Cursor's `Task` tool. For the other functions,
ask Cursor to follow the corresponding skill in `skills/`. If Cursor cannot locate the checkout,
tell it the path (`~/archeflow` above). Cursor support is less tested than Claude Code.

## First steps

### 1. Review a change (no setup needed)

In any git repository with uncommitted changes, or on a branch:

```
/archeflow:review                                # uncommitted changes
/archeflow:review --branch feat/rate-limit       # a branch, compared with main (or master; --base to change)
/archeflow:review --commit HEAD~3..HEAD          # a commit range
/archeflow:review --reviewers guardian,skeptic,sage
```

The Guardian (security, error paths, data loss) reviews by default; add the other reviewers with
`--reviewers`. Each finding has a severity (CRITICAL, WARNING, INFO), a file and line, and a
suggested fix. Review mode does not change your code, and new untracked files are part of the
reviewed changes (ignored files are not). Reviewers only read the code (read-only tools) and do
not run the changed code or its tests without your explicit confirmation; review untrusted
branches in a sandbox or with a permission mode that asks before Bash.

### 2. Run a task through the full cycle

Set up the project once with one of the three bundles:

```
/archeflow:init quick-fix          # or backend-feature, security-review; no argument lists them
```

This writes `.archeflow/config.yaml` (with the bundle's workflow and budget), a team, a workflow
and a domain file, and a `.archeflow/.gitignore` that keeps run state (events, artifacts, run
metadata, worktrees, memory) out of your commits. It also asks for your test command (for example
`npm test`); if you give one, it runs after every ArcheFlow merge. The same from a shell:
`<plugin dir>/lib/archeflow-init.sh quick-fix`.

Then start a run (tracked files must be committed first):

```
/archeflow:run "Add a fibonacci function with tests for negative input and overflow" --workflow fast
/archeflow:run "..." --dry-run          # plan only, show the proposal and a cost estimate, then ask
```

What happens (the roles are explained under Core concepts): the run creates a branch
`archeflow/<run_id>`. The Creator writes a proposal, the Maker implements it in a separate git worktree, its commits are brought into the run branch, and
the Guardian reviews the diff. The Act step then either sends findings back for another cycle,
stops and reports, or, when the reviewers approve, **asks you** whether to merge the run branch
into the branch you started from (set `git.auto_merge: true` to skip the question). Until the run
is merged, your checkout stays on the run branch. Afterwards:

```
/archeflow:status     # task, phase, cycle, findings of the current or last run
/archeflow:dag        # the run as a tree of events
/archeflow:report     # a Markdown report of the run
```

## Core concepts

### Roles

Each agent is spawned with a role definition from [`agents/`](agents/). A role says what the agent
is responsible for, what output it must produce, and which **failure mode** it is prone to: the
way that same strength goes wrong when it is overdone. The role names borrow from archetype
vocabulary; they are labels for role specifications, not a psychological model.

| Role | Phase | Job | Named failure mode | Example trigger of the check |
|------|-------|-----|--------------------|------------------------------|
| Explorer | Plan | Researches the codebase and context | Rabbit Hole | More than 2000 words without a recommendation section |
| Creator | Plan | Designs the solution and the test strategy | Over-Architect | More than 2 new abstractions, or more than one new dependency |
| Maker | Do | Implements the proposal in a git worktree | Rogue | 3 or more code files changed with no test file, or 10+ changed code lines and no evidence in its report that tests ran (documentation changes do not count) |
| Guardian | Check | Security, reliability, breaking changes | Paranoid | 3 or more CRITICAL findings and more than twice as many CRITICALs as WARNINGs |
| Skeptic | Check | Challenges assumptions, proposes alternatives | Paralytic | More than 7 challenges, fewer than half with an alternative |
| Trickster | Check | Adversarial input, edge cases | False Alarm | Findings about files the change did not touch |
| Sage | Check | Maintainability and overall quality | Bureaucrat | Review longer than twice the diff |

The checks are in [`lib/archeflow-shadow.sh`](lib/archeflow-shadow.sh) (the code calls failure
modes "shadows"); the full rules are in the `shadow-detection` skill. When a check fires, the
agent first gets a correction prompt; the second time it is replaced. The same failure mode three
times in one cycle stops the run (see Wiggum Break).

### The PDCA cycle

PDCA stands for Plan, Do, Check, Act, the iterative improvement cycle from quality management:

1. **Plan**: Explorer (optional) and Creator produce a proposal.
2. **Do**: the Maker implements it on a separate branch, in a git worktree.
3. **Check**: the reviewers read the diff. The Guardian goes first; if it finds nothing, the
   remaining reviewers are skipped (except in the first cycle of a `thorough` run).
4. **Act**: findings are collected and routed. Design problems go back to the Creator,
   implementation problems to the Maker, and the cycle repeats, until the reviewers approve or
   the cycle limit is reached.

Three built-in workflows set the team and the number of cycles:

| Workflow | Plan | Check | Max cycles |
|----------|------|-------|:----------:|
| `fast` | Creator | Guardian | 1 |
| `standard` | Explorer, Creator | Guardian, Skeptic, Sage | 2 |
| `thorough` | Explorer, Creator | Guardian, Skeptic, Sage, Trickster | 3 |

The Do phase is always the Maker. If you do not pass `--workflow`, the run uses `workflow:` from
`.archeflow/config.yaml`, else picks one from the task. A `fast` run in which the Guardian reports
two or more CRITICAL findings is upgraded to `standard` for the next cycle.

The cycle limits decide which multi-cycle checks can take effect: convergence between cycles is
scored from cycle 2, and oscillating findings or a low convergence score twice in a row need three
cycles. In `fast` none of these run; in `standard` and `thorough` they can only fire at the last
cycle, where they change the reported reason for stopping rather than the outcome.

### Wiggum Break

The name is a pun on the "Ralph Wiggum" loop, Geoffrey Huntley's technique of running a coding
agent in a loop until the work is done: the Wiggum Break is what stops the loop. It is a circuit
breaker. When a run stops making progress, ArcheFlow halts, records why, and hands control back
to you instead of spending more cycles.

Hard breaks stop at once, for example three agent failures in a row, the same failure mode three
times in one cycle, two or more findings that disappear and come back (oscillation), or a failing
test suite after a merge. Soft breaks let the current step finish first, for example when two
cycles in a row produce the same findings, when the convergence score stays low, or when more
than 95% of the budget is spent. The check is `lib/archeflow-convergence.sh wiggum-check
<run_id>`, which also logs the break in the event log; the thresholds are listed in the
`shadow-detection` skill.

## Commands

| Command | What it does |
|---------|--------------|
| `/archeflow:review` | Review a diff, branch or commit range |
| `/archeflow:run` | Run a task through the PDCA cycle |
| `/archeflow:init` | Set up `.archeflow/` in a project from a bundle |
| `/archeflow:status` | Current or last run |
| `/archeflow:dag` | Event tree of a run |
| `/archeflow:report` | Markdown report of a run |
| `/archeflow:replay` | Decision timeline and weighted what-if of a recorded run |
| `/archeflow:score` | Per-role effectiveness across runs |
| `/archeflow:memory` | Lessons remembered across runs |
| `/archeflow:sprint` | Work through a task queue across several repositories |
| `/archeflow:scan` | Propose new queue items from the repositories of a workspace |

Arguments and the internal skills behind these commands are listed in
[docs/COMMANDS.md](docs/COMMANDS.md). A multi-project run (several PDCA runs with dependencies,
defined in `.archeflow/multi-run.yaml`) has no command of its own: ask for it in plain words.

## What ArcheFlow writes

In your project:

| Path | Contents |
|------|----------|
| `.archeflow/config.yaml`, `teams/`, `workflows/`, `domains/` | Configuration written by `/archeflow:init` |
| `.archeflow/events/<run_id>.jsonl` | Event log of each run, one JSON object per line |
| `.archeflow/events/index.jsonl` | One line per finished run (a merge approved later adds a line; the last one counts) |
| `.archeflow/artifacts/<run_id>/` | Proposals, reviews and other agent output |
| `.archeflow/memory/lessons.jsonl` | Lessons carried across runs |
| `.archeflow/progress.md` | Progress snapshot, written when you run `lib/archeflow-progress.sh <run_id> [--watch]` (for example from a second terminal) |
| `.archeflow/worktrees/<run_id>/` | The Maker's worktree while it works (removed afterwards) |

In git: a branch `archeflow/<run_id>` per run (prefix configurable under `git:` in
`config.yaml`) and, while the Maker works, a worktree on `archeflow/<run_id>-maker`. After a
merge you approved and passing tests, the run branch is deleted; artifacts and events stay. The
merge commit is titled `archeflow: merge run <run_id>`. A run commits nothing under
`.archeflow/` and pushes nothing (unless `git.auto_push: true`).

Commit the configuration (`config.yaml`, `hooks.yaml`, `teams/`, `workflows/`, `domains/`,
`lenses/`) if you want to share it. Run state is local by default: the `.archeflow/.gitignore`
written by `/archeflow:init` ignores `events/`, `artifacts/`, `runs/`, `worktrees/`, `memory/`,
review diffs, `progress.md`, locks and `langfuse.env`. Treat
a committed `.archeflow/` from someone else's repository as untrusted: `test_command` and hook
commands are executed, and lenses decide which files are put into prompts (see
[SECURITY.md](SECURITY.md)).

## Configuration

`.archeflow/config.yaml` controls models, budget, git behaviour and memory. The keys, with the
lenses (extra review focus such as `security` or `compliance-gdpr`), interaction patterns
(`debate`, `cascade`), domains, local models via Ollama and the optional Langfuse export, are
described in [docs/configuration.md](docs/configuration.md), including the environment variables
(for example `ARCHEFLOW_OLLAMA_ALLOW_REMOTE=1`, needed before a non-local Ollama host is
contacted). The Bash scripts in `lib/` can also be
used on their own; see [docs/scripts.md](docs/scripts.md).

## Working across several repositories

`/archeflow:sprint` reads a task queue from `docs/orchestra/queue.json` in a parent directory that
holds several repositories, starts up to four agents in parallel (one per repository, each on a
new branch `sprint/<item-id>`), updates the queue as tasks finish and picks the next batch. It
shows each batch and waits for your approval unless you ask for autonomous mode in the session.
It never merges the branches it creates. `/archeflow:scan` suggests new queue items from the
repositories' status files; they are added as `proposed` and only run after you approve them.
The queue format, the workspace layout and an example are in [docs/queue.md](docs/queue.md) and
[examples/queue.json](examples/queue.json).

## More

- [examples/](examples/): walkthroughs, a custom workflow, a local-model config, a queue
- [docs/hooks.md](docs/hooks.md): running your own commands at points of a run
- [docs/roadmap.md](docs/roadmap.md): what is planned next
- [SECURITY.md](SECURITY.md): threat model and how to report a vulnerability
- [CONTRIBUTING.md](CONTRIBUTING.md) and [CLAUDE.md](CLAUDE.md): working on ArcheFlow itself
- [CHANGELOG.md](CHANGELOG.md)

## License

MIT
