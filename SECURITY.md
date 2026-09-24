# Security Policy

## Supported versions

ArcheFlow is an experimental research prototype. Only the latest release on `main`
receives security fixes.

## Reporting a vulnerability

Please do **not** open a public issue for security problems.

Report vulnerabilities privately via GitHub's
[private vulnerability reporting](https://github.com/XORwell/archeflow/security/advisories/new).
Include the affected file or command, a minimal reproduction, and the impact you expect.

You can expect an acknowledgement within 7 days. Fixes are released on `main` and noted in
[CHANGELOG.md](CHANGELOG.md).

## Threat model and scope

ArcheFlow runs inside an AI coding agent (Claude Code, Cursor) with that agent's permissions.
Its Bash helpers read and write files under `.archeflow/`, create git branches and worktrees,
and can merge branches.

**Attacker model.** The attacker controls the content of the repository you run ArcheFlow in: a
repository you cloned, a contributor's pull request, or a run branch that was merged. That
includes every committed file under `.archeflow/`, `.gnap/` and `docs/`, plus task text. The
attacker does not control your shell environment, your home directory, or the plugin install
directory.

**What the scripts guarantee.** Task text, queue items, event data, memory and agent output are
untrusted input. The `lib/` scripts never `eval` or `source` it, never use it in shell arithmetic
(bash evaluates `a[$(cmd)]` there), build JSON only with `jq --arg`, validate run IDs and names
before using them in paths, pass `--end-of-options` before data-derived git refs, and refuse to
write through symlinks inside `.archeflow/`: the scripts that write state refuse to run when
`.archeflow/` itself or one of its state directories (`events/`, `artifacts/`, `runs/`,
`worktrees/`, `memory/`, ...) is a symlink or resolves outside the repository, and every write
checks each directory component of its path, not only the file. Config values that reach a
command (Ollama base URL and model names, lens names) are read from `config.yaml` by the script
that uses them and validated there; the skills never paste them into a shell line. `tests/archeflow-fuzz.bats` feeds injection payloads
through every script that reads these files. Reports of code execution or file access through
any of them are in scope.

**What they do not guarantee.** ArcheFlow does not sandbox the agents it spawns. Isolation comes
from the host agent's permission mode (which you choose when you start the session) and from git
worktrees; a worktree is not a sandbox. Text that ends up in an agent prompt (task text, lessons,
lens context, reviewed diffs) can contain prompt injection. Scripts treat it as data, but the
model reading it may still follow it; keep a human in the loop for merges and for anything that
runs commands. To limit what an injected instruction can do, the reviewer and planner roles
(Guardian, Skeptic, Sage, Trickster, Explorer, Creator) get read-only tools (Read, Grep, Glob),
and code under review is never executed without your explicit confirmation. Only the Maker can
edit files and run commands, inside its own worktree.

**What a run guarantees about ArcheFlow's own files.** The Maker's commits may not touch
`.archeflow/` (`archeflow-git.sh integrate` refuses them and names the paths), because reviewers
see a diff without `.archeflow/`. `archeflow-git.sh merge` refuses a run branch that changes
anything under `.archeflow/` except this run's own artifacts and event log, and refuses when the
trusted configuration in your working tree (`config.yaml`, `hooks.yaml`, `lenses/`,
`memory/lessons.jsonl`, `archetypes/`, `domains/`, `teams/`, `patterns/`, `workflows/`,
`multi-run.yaml`, `queue.md`) changed since `init` fingerprinted it. The post-merge tests run the
`test_command` recorded at `init`; if `config.yaml` says something else by then, nothing runs.

### Files that can remove the merge gate or start unattended work

A repository can ship these. None of them takes effect from the file alone:

| File / setting | Effect | Gate |
|----------------|--------|------|
| `git.auto_merge: true` in `.archeflow/config.yaml` | a run merges without asking | honoured only after you confirm it once per session; a change during a run blocks the merge |
| `.archeflow/multi-run.yaml` | starts runs in several projects, including paths outside the repository | the full plan (resolved paths, task text) is shown and needs your yes; paths must be existing git repositories inside the workspace |
| `mode` in `docs/orchestra/queue.json` | would make the sprint autonomous | `AUTONOMOUS` in the file is ignored (treated as `ATTENDED`); only you can switch modes in the session. Scanned and imported items are `proposed` |
| `.archeflow/queue.md` (autonomous mode) | a task list, with `done:` conditions that can name commands | every task line needs your yes; a `done:` command runs only if you approved that exact command |
| `.archeflow/hooks.yaml` | commands run at run start, before and after the merge | each command needs your yes for its exact text, once per session and again when it changes |

### Files a repository can supply

Everything below can arrive with a `git clone` or `git pull`. Review the "trusted" ones before
running ArcheFlow in a repository you did not write.

| File | Used by | Treatment |
|------|---------|-----------|
| `.archeflow/config.yaml` | skills, `archeflow-git.sh`, `archeflow-rollback.sh`, `archeflow-convergence.sh`, `archeflow-ollama.sh`, `archeflow-lens.sh` | **Trusted configuration.** `test_command` is executed (post-merge tests, verification; the value recorded at run start), git settings such as `signing_key`, `branch_prefix` and `auto_push` come from it, `git.auto_merge` removes the merge confirmation (only after you confirm it once per session, see above), and `models.ollama.base_url` decides where prompts go (loopback only unless you opt in). Review it like a Makefile. |
| `.archeflow/hooks.yaml` | the run skill (the agent executes the hooks) | **Trusted configuration**: its commands are run by the agent, each only after your yes for its exact text. `archeflow-init.sh` warns when it installs one. Review it before a run. |
| `.archeflow/lenses/*.yaml` | `archeflow-lens.sh`, run skill | Project lenses take precedence over built-in lenses with the same name. `context_inject` entries must be plain relative paths (letters, digits, `.`, `_`, `-`, `/`; no `..`, `~`, `$`, backticks, globs or spaces) that resolve inside the project root (symlinks included); `merge` refuses anything else, so a lens cannot pull `~/.ssh/...` into a prompt. Lens text still reaches prompts (prompt-injection surface). |
| `.archeflow/domains/*.yaml` | the agent (`domains` skill) | Context files follow the same plain-relative-path rule as lenses; other entries are skipped. Domain text reaches prompts (prompt-injection surface). |
| `.archeflow/archetypes/*.md`, `.archeflow/teams/*`, `.archeflow/patterns/*`, `.archeflow/workflows/*` | the agent | Custom role definitions become agent system prompts; teams, patterns and workflows decide which roles run. Prompt-injection surface: review them like code before a run in a repository you did not write. |
| `.archeflow/multi-run.yaml` | `multi-project` skill | Starts runs in several projects; needs your yes for the full plan (see above). |
| `.archeflow/queue.md` | `autonomous-mode` skill | Tasks and `done:` commands; each needs your yes (see above). |
| `.archeflow/memory/lessons.jsonl` | `archeflow-memory.sh`, run skill | Data only: numeric fields are read as JSON numbers, ids must match `m-<digits>`. Lessons are injected into agent prompts, so a committed lessons file is a prompt-injection surface. Delete it in a repository you do not trust. |
| `.archeflow/memory/effectiveness.jsonl`, `audit.jsonl` | `archeflow-score.sh`, `archeflow-memory.sh` | Data only; comparisons happen in jq. |
| `.archeflow/events/*.jsonl`, `events/index.jsonl` | report, dag, progress, replay, score, memory, convergence, shadow, Langfuse bridge | Data only. Event logs are local by default (the generated `.archeflow/.gitignore` ignores them), but a repository can still ship some or a user can commit them, so they are treated like any other repository content: no arithmetic on their fields, run IDs from `index.jsonl` are validated before they become paths, appends refuse symlinks. |
| `.archeflow/templates/bundles/*` | `archeflow-init.sh` | A project-local bundle shadows your global and the built-in bundle of the same name; init prints a warning when it uses one. Bundle names and `includes.*` file names are restricted to plain names. Anything the bundle installs (config, hooks) is then trusted configuration, see above. |
| `.archeflow/langfuse.env` (any case, any symlink) | nothing | **Never read.** Langfuse settings come only from the environment or from `${XDG_CONFIG_HOME:-~/.config}/archeflow/langfuse.env` / `~/.archeflow/langfuse.env`, so a repository cannot send your run data to its own host. Inherited `LANGFUSE_*` variables are cleared first and all four values come from one source (environment with `LANGFUSE_ENABLED=true`, or one user-level file). The host must be `https://` or loopback `http://`. The file is parsed as data, never sourced. |
| `.archeflow/agent-card.json` | `archeflow-a2a.sh validate` | Data only. |
| `.archeflow/merge-queue/queue.jsonl` | `archeflow-merge-queue.sh` | Branch names are validated (`git check-ref-format`, no leading `-`) before any git call; priorities must be integers; only `squash` and `no-ff` strategies exist. |
| `docs/orchestra/queue.json` | sprint and queue skills, `archeflow-gnap.sh` | Item text becomes an agent's task; the sprint shows each item's full text before dispatch. `mode: AUTONOMOUS` in the file is ignored. Format and dispatch rules: [docs/queue.md](docs/queue.md). |
| `.gnap/tasks/*.json` | `archeflow-gnap.sh import` | Written by any agent that can push. Import never modifies existing queue items and adds new ones only with `status: "proposed"` and `source: "gnap"`; proposed items must not be dispatched without your approval. Symlinked and malformed task files are skipped. |

Environment and endpoints:

- **Langfuse** keys belong in `~/.config/archeflow/langfuse.env` (or `~/.archeflow/langfuse.env`)
  or in environment variables. A `langfuse.env` inside a project is ignored. Never commit keys.
- **Ollama**: `archeflow-ollama.sh` only contacts loopback hosts (`localhost`, `127.x`, `[::1]`,
  `0.0.0.0`) unless you set `ARCHEFLOW_OLLAMA_ALLOW_REMOTE=1` in your own shell, because the base
  URL usually comes from the repository's `config.yaml` and every prompt, including code, is sent
  there. It reads `models.ollama.base_url` and `models.mapping` itself and validates them, so the
  values never pass through a shell command line.
- **Scan and sprint**: `/archeflow:scan` never runs project code (no test suites, builds or
  scripts) and runs its read-only git queries with `core.fsmonitor` and `core.pager` disabled. A
  project's own `CLAUDE.md` is trusted by sprint agents (it can set the branch rule and allow
  pushes); keep untrusted projects out of a sprint workspace.
- **A2A `serve`** binds to `127.0.0.1` by default and serves only a static agent card.
- **Rollback** (`archeflow-rollback.sh`) only reverts HEAD when it is this run's ArcheFlow merge
  commit (`archeflow: merge run <run_id>`; the older subject `feat: archeflow run <run_id> complete` is also accepted). Otherwise it reports the failing tests and
  exits 3 without reverting. It runs the `test_command` recorded when the run started and exits 2
  without running anything if `config.yaml` now says something else.
- **Evidence gate**: `archeflow-evidence.sh validate` keeps the reviewer's original as
  `<file>.orig` and logs each downgrade as an `evidence.downgrade` event, so a real finding that
  lacked evidence stays visible.

Out of scope: vulnerabilities in Claude Code, Cursor, or the LLM providers themselves.
