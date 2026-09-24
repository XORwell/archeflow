# ArcheFlow: contributor guide

This file is for anyone (and any coding agent) working on the ArcheFlow repository itself. User
documentation is in [README.md](README.md); the security model is in [SECURITY.md](SECURITY.md).

ArcheFlow is a Claude Code plugin (also usable from Cursor). The product is mostly Markdown:
skills that tell the host agent what to do, and role definitions for the agents it spawns. A set
of Bash scripts does the deterministic work (event log, git branches, failure-mode checks,
reports). Runtime requirements: Bash 4+, jq 1.6+, git.

## Architecture

```
.claude-plugin/      plugin.json + marketplace.json (the repo is its own marketplace)
hooks/               SessionStart hook: injects skills/using-archeflow/ACTIVATION.md and the plugin root
skills/<name>/SKILL.md
                     One skill per directory. A user-invocable skill is the command
                     /archeflow:<name>; the others are internal (user-invocable: false).
  run/               /archeflow:run, the core PDCA flow; details in run/reference.md
  review/            /archeflow:review on an existing diff, branch or commit range
  sprint/, scan/     Queue-driven dispatch across a workspace, and queue maintenance
  init/, status/, report/, dag/, replay/, score/, memory/
                     The remaining commands
  check-phase/       Reviewer protocol: finding format, evidence rules
  act-phase/         Finding collection, routing, exit decisions
  shadow-detection/  Named failure modes, system-level checks, Wiggum Break
  ...                Other internal skills (git-integration, workflow-design, domains, ...)
agents/<role>.md     The seven role definitions (Explorer, Creator, Maker, Guardian, Skeptic,
                     Trickster, Sage): strength, named failure mode, output protocol
lib/archeflow-*.sh   Bash helpers called by the skills
lib/archeflow-common.sh
                     Shared helpers sourced by the other scripts (validation, safe temp files)
lenses/, patterns/   YAML building blocks, each with a SCHEMA.md
templates/bundles/   Setup bundles used by archeflow-init.sh (quick-fix, backend-feature, security-review)
.cursor/             Cursor rule and adapter skills (same protocols, Cursor's Task tool)
tests/               bats tests, one file per lib script plus hook and skill lint tests
scripts/             run-tests.sh, ci-local.sh
examples/, docs/     User documentation
```

How the pieces connect:

1. The SessionStart hook prints `ArcheFlow root: <abs path>` plus the activation text. Plugins
   installed from a marketplace live under `~/.claude/plugins/cache/...`, not in the user's
   project, so **skills must call scripts as `<archeflow-root>/lib/archeflow-<name>.sh`**, never
   `./lib/...`.
2. A command is a skill. The user-facing command names are listed in
   [docs/COMMANDS.md](docs/COMMANDS.md); keep README, `.cursor/` and skill text in sync with it
   (`tests/skills-lint.bats` checks every `/archeflow:<name>` in the docs and skills).
3. Skills spawn agents and pass them the role definition from `agents/`.
4. Every step is logged as a JSONL event in `.archeflow/events/<run_id>.jsonl` (in the user's
   project) via `archeflow-event.sh`. Reports, DAG, progress, replay and scores are all derived
   from that log.

## Conventions

### Skills (Markdown)

- Frontmatter: `name` (kebab-case, must match the directory) and `description` (one line, plus
  `<example>` tags for user-invocable skills). `tests/skills-lint.bats` checks this.
- Write operational instructions the agent can follow: imperative voice, numbered steps for
  protocols, tables for reference data.
- Shell in skills: one-liners that call a lib script. Multi-step logic belongs in `lib/`.
- Only reference script subcommands that exist. If you add or rename a subcommand, update every
  skill that calls it.
- One source of truth per concept: finding format in `check-phase`, failure modes in
  `shadow-detection` and `agents/`, queue format in [docs/queue.md](docs/queue.md). Link to it
  instead of copying it.
- When you change a role, update `agents/<role>.md`, the skills that reference it, and
  `lib/archeflow-shadow.sh` if its failure-mode triggers change.

### Lib scripts (Bash)

- `#!/usr/bin/env bash` and `set -euo pipefail`. Check non-standard tools with `command -v`.
- Portable: Bash 4+, jq 1.6+ (Debian 12 still ships 1.6, so avoid builtins added in 1.7 or
  later, such as `pick`), POSIX awk/sed. No GNU-only flags (`grep -P`, `sed -r` extensions,
  `\s` in sed), no `yq`, no Python. YAML is read with `lib/archeflow-yaml.sh`.
- Treat task text, queue items, event data and agent output as untrusted (see SECURITY.md):
  - never `eval` or `source` data, never interpolate it into a shell command string;
  - build JSON with `jq --arg/--argjson`, never by string concatenation;
  - validate run IDs and names with `af_valid_name` / `af_require_run_id` before using them in paths;
  - never feed values read from files into shell arithmetic; use `af_as_int`.
- Concurrent writers (events, memory, queue) take a lock via `archeflow-lock.sh`.
- Document usage in the header comment. New or changed scripts print usage on `-h`/`--help`
  (several older scripts do not yet) and exit non-zero with a message on bad input.
- Scripts must not prompt interactively: they run inside a non-TTY agent.
- Use the canonical `ARCHEFLOW_*` environment variable names. The old `ARCHFLOW_*` spellings are
  read only as a fallback.

### File size

- Skills: aim for under ~200 lines. A skill that grows past that usually contains a second
  concept (split it) or procedural logic (move it into `lib/`). The run skill keeps its
  reference material in `skills/run/reference.md`; follow that split rather than growing a
  SKILL.md.
- Role definitions in `agents/`: under ~100 lines.
- Lib scripts: under ~600 lines. Beyond that, move shared code into `archeflow-common.sh` or split
  by subcommand.
- README: what, install, first run, concepts. Reference material goes into `docs/`.

## Testing

```bash
./scripts/run-tests.sh                   # all bats tests
./scripts/run-tests.sh --filter event    # a subset
./scripts/ci-local.sh                    # same suite in a clean Ubuntu 24.04 container (podman or docker)
shellcheck --severity=error lib/*.sh scripts/*.sh
```

- Every lib change needs a bats test in `tests/archeflow-<name>.bats`. Test through the public
  command line, and prefer fixtures produced by the real scripts (for example events written by
  `archeflow-event.sh`) over hand-written files in the layout a script expects.
- Assert the outcome, not only the exit code: a script that crashes can exit with the same code
  as a negative result.
- Run `ci-local.sh` before a PR that touches locale, git defaults or jq behaviour; CI runs on
  Ubuntu 24.04 with its packaged jq (1.7) and bats.
- Skill changes: check them by hand in a scratch repository (a dry run first), and keep
  `tests/skills-lint.bats` passing.

## Versions and changelog

The first `## [x.y.z]` heading in CHANGELOG.md, `.claude-plugin/plugin.json` and
`.claude-plugin/marketplace.json` must agree; CI checks this. `lib/archeflow-version.sh` reads the
version from CHANGELOG.md. Add a CHANGELOG entry for every user-visible change, written for users.

## Git

- Work on a branch (`feat/...`, `fix/...`, `docs/...`) and open a pull request. Do not push to
  `main` and never force-push shared branches.
- Conventional commits: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`, `ci:`.
- Keep commits focused; a fix and its test belong in the same commit.

## Do not

- Add runtime dependencies beyond Bash, jq and git. Optional integrations (Ollama, Langfuse) may
  use `curl`, and must stay optional.
- Grant agents broader permissions by default. Anything like permission bypass must be an explicit
  opt-in by the user.
- Claim results in docs that the code and tests do not show.
