# Contributing to ArcheFlow

Thanks for your interest in contributing. ArcheFlow is an experimental project, so issues that
report confusing behaviour or documentation that does not match the code are as welcome as code.

The contributor guide for the codebase (architecture, conventions, file-size guidance) is in
[CLAUDE.md](CLAUDE.md). Claude Code loads it automatically when you work in this repository.

## Getting started

```bash
git clone https://github.com/XORwell/archeflow.git
cd archeflow
claude --plugin-dir .        # load your working copy as a plugin in Claude Code
```

## Dependencies

- Runtime: Bash 4+, jq 1.6 or newer, git. Nothing else: no Python, no Node.js.
- Optional at runtime: `curl` (Ollama and Langfuse integrations), `nc` (`archeflow-a2a.sh serve`).
- Tests: [bats-core](https://github.com/bats-core/bats-core), shellcheck.

```bash
sudo apt-get install bats jq shellcheck     # Debian/Ubuntu
brew install bash bats-core jq shellcheck   # macOS (the system Bash is 3.2; install a newer one)
```

## Running the tests

```bash
./scripts/run-tests.sh                      # all bats tests
./scripts/run-tests.sh --filter memory      # tests whose name matches "memory"
./scripts/ci-local.sh                       # the suite in a clean Ubuntu 24.04 container, like CI
shellcheck --severity=error lib/*.sh scripts/*.sh
```

`ci-local.sh` needs podman or docker. Use it when your change could depend on the host: locale,
git's default branch name, or the jq version.

CI runs the same bats suite, shellcheck, a syntax check of every script, and a check that the
version in `CHANGELOG.md`, `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
agree.

## What goes where

| Directory | Contents |
|-----------|----------|
| `skills/<name>/SKILL.md` | Skills: the commands and protocols the host agent follows |
| `agents/<role>.md` | Role definitions for the spawned agents |
| `lib/` | Bash helpers called by the skills |
| `hooks/` | SessionStart hook |
| `lenses/`, `patterns/`, `templates/` | YAML building blocks and setup bundles |
| `.cursor/` | Cursor rule and adapter skills |
| `tests/` | bats tests |
| `docs/`, `examples/` | User documentation |

## Code style

- Shell: `set -euo pipefail`, portable constructs only (no GNU-only flags), JSON built with
  `jq --arg`, never by string concatenation. Untrusted input (task text, queue items, agent
  output) is never evaluated. Details in [CLAUDE.md](CLAUDE.md) and [SECURITY.md](SECURITY.md).
- Skills: imperative instructions, tables for reference data, numbered steps for protocols,
  one-line shell commands that call a lib script.
- Markdown: ATX headings.
- Commits: conventional commits (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`, `ci:`).

## Submitting changes

1. Fork the repository and create a branch (`git checkout -b fix/my-fix`).
2. Add or update tests for any change in `lib/`.
3. Run `./scripts/run-tests.sh` and shellcheck.
4. Add a line to `CHANGELOG.md` for user-visible changes.
5. Open a pull request that says what changed and how you tested it.

## Reporting issues

Security problems: see [SECURITY.md](SECURITY.md). Do not open a public issue.

For everything else, open a GitHub issue with:

- what you expected and what happened
- steps to reproduce (the command you ran, and the relevant part of `.archeflow/events/<run_id>.jsonl` if a run was involved)
- your environment: OS, Bash version (`bash --version`), jq version (`jq --version`), Claude Code or Cursor version
