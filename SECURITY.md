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
write through symlinks inside `.archeflow/`. `tests/archeflow-fuzz.bats` feeds injection payloads
through every script that reads these files. Reports of code execution or file access through
any of them are in scope.

**What they do not guarantee.** ArcheFlow does not sandbox the agents it spawns. Isolation comes
from the host agent's permission mode (which you choose when you start the session) and from git
worktrees; a worktree is not a sandbox. Text that ends up in an agent prompt (task text, lessons,
lens context, reviewed diffs) can contain prompt injection. Scripts treat it as data, but the
model reading it may still follow it; keep a human in the loop for merges and for anything that
runs commands.

### Files a repository can supply

Everything below can arrive with a `git clone` or `git pull`. Review the "trusted" ones before
running ArcheFlow in a repository you did not write.

| File | Used by | Treatment |
|------|---------|-----------|
| `.archeflow/config.yaml` | skills, `archeflow-git.sh`, `archeflow-rollback.sh`, `archeflow-convergence.sh` | **Trusted configuration.** `test_command` is executed (post-merge tests, verification), git settings such as `signing_key`, `branch_prefix` and `auto_push` come from it, and `models.ollama.base_url` decides where prompts go. Review it like a Makefile. |
| `.archeflow/hooks.yaml` | the run skill (the agent executes the hooks) | **Trusted configuration**: its commands are run by the agent. `archeflow-init.sh` warns when it installs one. Review it before a run. |
| `.archeflow/lenses/*.yaml` | `archeflow-lens.sh`, run skill | Project lenses take precedence over built-in lenses with the same name. `context_inject` entries must be relative paths without `..` that resolve inside the project root (symlinks included); `merge` refuses anything else, so a lens cannot pull `~/.ssh/...` into a prompt. Lens text still reaches prompts (prompt-injection surface). |
| `.archeflow/memory/lessons.jsonl` | `archeflow-memory.sh`, run skill | Data only: numeric fields are read as JSON numbers, ids must match `m-<digits>`. Lessons are injected into agent prompts, so a committed lessons file is a prompt-injection surface. Delete it in a repository you do not trust. |
| `.archeflow/memory/effectiveness.jsonl`, `audit.jsonl` | `archeflow-score.sh`, `archeflow-memory.sh` | Data only; comparisons happen in jq. |
| `.archeflow/events/*.jsonl`, `events/index.jsonl` | report, dag, progress, replay, score, memory, convergence, shadow, Langfuse bridge | Data only. Event logs are committed with each run, so they are treated like any other repository content: no arithmetic on their fields, run IDs from `index.jsonl` are validated before they become paths, appends refuse symlinks. |
| `.archeflow/templates/bundles/*` | `archeflow-init.sh` | A project-local bundle shadows your global and the built-in bundle of the same name; init prints a warning when it uses one. Bundle names and `includes.*` file names are restricted to plain names. Anything the bundle installs (config, hooks) is then trusted configuration, see above. |
| `.archeflow/langfuse.env` | `archeflow-langfuse.sh` | **Refused if tracked by git.** An untracked file in the repository root is accepted (you created it). Parent directories are never searched. Inherited `LANGFUSE_*` variables are cleared first and all four values come from one source (environment with `LANGFUSE_ENABLED=true`, or one file), so a file cannot pair your exported keys with its own host. The host must be `https://` or loopback `http://`. The file is parsed as data, never sourced. |
| `.archeflow/agent-card.json` | `archeflow-a2a.sh validate` | Data only. |
| `.archeflow/merge-queue/queue.jsonl` | `archeflow-merge-queue.sh` | Branch names are validated (`git check-ref-format`, no leading `-`) before any git call; priorities must be integers; only `squash` and `no-ff` strategies exist. |
| `docs/orchestra/queue.json` | sprint and queue skills, `archeflow-gnap.sh` | Item text becomes an agent's task. Format and dispatch rules: [docs/queue.md](docs/queue.md). |
| `.gnap/tasks/*.json` | `archeflow-gnap.sh import` | Written by any agent that can push. Import never modifies existing queue items and adds new ones only with `status: "proposed"` and `source: "gnap"`; proposed items must not be dispatched without your approval. Symlinked and malformed task files are skipped. |

Environment and endpoints:

- **Langfuse** keys belong in `~/.config/archeflow/langfuse.env` (or an untracked
  `.archeflow/langfuse.env`, which `archeflow-init.sh` adds to `.archeflow/.gitignore`) or in
  environment variables. Never commit them.
- **Ollama**: `archeflow-ollama.sh` only contacts loopback hosts (`localhost`, `127.x`, `[::1]`,
  `0.0.0.0`) unless you set `ARCHEFLOW_OLLAMA_ALLOW_REMOTE=1` in your own shell, because the base
  URL usually comes from the repository's `config.yaml` and every prompt, including code, is sent
  there.
- **A2A `serve`** binds to `127.0.0.1` by default and serves only a static agent card.
- **Rollback** (`archeflow-rollback.sh`) only reverts HEAD when it is this run's ArcheFlow merge
  commit (`feat: archeflow run <run_id> complete`). Otherwise it reports the failing tests and
  exits 3 without reverting.

Out of scope: vulnerabilities in Claude Code, Cursor, or the LLM providers themselves.
