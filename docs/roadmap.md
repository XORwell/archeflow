# Roadmap

ArcheFlow is experimental; this list is a statement of intent, not a promise. Past releases are
in [CHANGELOG.md](../CHANGELOG.md).

## Next: v0.12

- **Pluggable decision backend for the failure-mode and convergence checks.** Today the checks
  in `archeflow-shadow.sh` and `archeflow-convergence.sh` are deterministic heuristics. v0.12 makes
  the decision step replaceable: the heuristics stay the default, and optional backends (a local
  Ollama model, an LLM judge, or a hosted fast decision/classifier model) can be switched on. All
  optional backends are off by default; hosted backends send run content to a third party and are
  covered in `SECURITY.md` before they ship.
- **Comparison against the heuristics** on public labelled traces of multi-agent failures (MAST,
  Who&When), to measure how often each backend flags real failures and how often it raises false
  alarms.

## Later

- Load custom workflows from `.archeflow/workflows/` in `/archeflow:run` (today only the built-in
  `fast`, `standard` and `thorough` workflows are used).
- More hook points (`phase-complete`, `agent-complete`); today `run-start`, `pre-merge`,
  `post-merge` and `run-complete` are called.
- A GitHub Action that runs `/archeflow:review` on pull requests, triggered only by a maintainer.
