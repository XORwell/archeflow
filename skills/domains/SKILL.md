---
name: domains
description: |
  Domain adapter system that maps ArcheFlow concepts (code-oriented by default) to domain-specific
  equivalents. Enables writing, research, and other non-code workflows to use the same PDCA pipeline
  with domain-appropriate terminology, metrics, review focus, and context injection.
  <example>User: "Use ArcheFlow for my short story"</example>
  <example>Automatically loaded when writing-domain config is detected</example>
user-invocable: false
---

# Domain Adapter System

Adapts the PDCA pipeline and archetype system to specific domains (writing, code, research) so events, metrics, reviews, and context use domain-appropriate terminology.

## Domain Registry

Domain definitions live in `.archeflow/domains/<name>.yaml`. Each maps generic concepts to domain-specific equivalents.

### Concept Mapping

| Generic Concept | Code | Writing | Research |
|----------------|------|---------|----------|
| implementation | code changes | draft/prose | draft/analysis |
| tests | automated tests | consistency checks | citation verification |
| files_changed | files changed | word count delta | section count |
| test_coverage | test coverage % | voice drift score | source coverage |
| code_review | code review | prose review | peer review |
| build | build/compile | compile/export | compile (LaTeX/PDF) |
| deploy | deploy | publish | submit/publish |
| bug | bug | continuity error | unsupported claim |
| feature | feature | scene/chapter | section |

### Metrics by Domain

| Code | Writing | Research |
|------|---------|----------|
| files_changed | word_count | word_count |
| lines_added/removed | voice_drift_score | citation_count |
| tests_added | dialect_density | source_diversity |
| tests_passing | scene_count | claim_count |
| coverage_delta | dialogue_ratio | unsupported_claims |

### Review Focus by Domain

| Reviewer | Code | Writing | Research |
|----------|------|---------|----------|
| Guardian | security, breaking changes, deps, error handling | plot coherence, character consistency, timeline, continuity | factual accuracy, citation validity, logic, methodology |
| Sage | code quality, coverage, docs, patterns | voice consistency, prose quality, dialect authenticity | argument structure, clarity, tone, completeness |
| Skeptic | design assumptions, scalability, edge cases | premise strength, motivation, ending satisfaction | (default) |
| Trickster | malformed input, races, error paths, dep failures | reader confusion, pacing dead spots, disbelief breaks | (default) |

### Model Overrides

Domains can override default model assignments:

| Domain | Override | Rationale |
|--------|----------|-----------|
| Writing | maker: sonnet | Prose quality is the product |
| Writing | custom reviewer: sonnet | Voice evaluation needs taste |
| Research | maker: sonnet | Analysis quality matters |
| Code | (none) | Defaults are calibrated for code |

### Context Injection by Domain

Domains declare which extra files agents should read per phase. Context injection is additive (on top of standard ArcheFlow context).

| Phase | Code | Writing |
|-------|------|---------|
| always | README.md, config.yaml | voice profile, persona, characters |
| plan | relevant source files, existing tests | series config, previous stories, brief |
| do | Creator's proposal, test fixtures | scene outline, voice profile |
| check | git diff, risk section | voice profile (Sage), outline (Guardian), characters |

## Domain Detection

Auto-detects at `run.start`. Result stored in event stream.

| Priority | Signal | Domain |
|----------|--------|--------|
| 1 | CLI `--domain <name>` | as specified |
| 2 | Team preset `domain:` field | as specified |
| 3 | Writing-domain config exists | writing |
| 4 | `*.bib` or `references/` exists | research |
| 5 | `package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, `Makefile` | code |
| 6 | No markers | code (default) |

## Adding a New Domain

1. Create `.archeflow/domains/<name>.yaml` with `name`, `concepts`, `metrics` (minimum required)
2. Optionally add `review_focus`, `context`, `model_overrides`
3. Missing sections fall back to `code` domain defaults
4. Test with `--domain <name> --dry-run`

## How Domains Affect Orchestration

- **Reports** use domain-translated terms (e.g., "word count delta" instead of "files changed")
- **Events** include domain-relevant metrics in `agent.complete` and `run.complete` payloads
- **Reviewers** receive domain-specific focus checklists (archetype personality stays the same)
- **Context injection** adds domain-declared files to each agent's prompt
- **Model overrides** change which model an archetype uses (interacts with cost-tracking)
- **One domain per run.** Multi-domain projects use separate runs.
