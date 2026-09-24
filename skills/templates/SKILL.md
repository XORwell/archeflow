---
name: templates
description: |
  Template gallery for sharing workflows, team presets, archetypes, domain configs, and complete
  setup bundles across ArcheFlow projects. Supports init-from-template, save-as-template, and
  clone-from-project operations.
  <example>User: "save this ArcheFlow setup as a template"</example>
  <example>User: "which ArcheFlow templates do I have?"</example>
user-invocable: false
---

# Template Gallery -- Shareable ArcheFlow Configurations

Makes ArcheFlow setups portable and reusable across projects.

## Template Storage

| Location | Scope | Precedence |
|----------|-------|------------|
| `.archeflow/templates/` | Project-local | Higher (checked first) |
| `~/.archeflow/templates/` | Global (user-wide) | Lower (fallback) |

Subdirectories: `workflows/`, `teams/`, `archetypes/`, `domains/`, `bundles/`.

## Bundles

A bundle is a complete setup (team + workflow + archetypes + domain) in one directory.
`/archeflow:run` reads `.archeflow/config.yaml` (budget, models, git, `test_command`, `workflow:`
= fast|standard|thorough) and custom roles; the team and workflow files are documentation of the
setup and are not read by the run.

**Manifest (`manifest.yaml`):**

```yaml
name: my-backend-setup
description: "Backend feature work with a security lens"
domain: code
includes:
  team: story-development.yaml
  workflow: custom-workflow.yaml
  archetypes: [custom-archetype.md]
  domain: writing.yaml
requires: []
variables:
  max_cycles: 2
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Bundle identifier for `archeflow-init.sh <name>` |
| `description` | Yes | Human-readable description |
| `includes` | Yes | File types to filenames within bundle |
| `requires` | No | Files that must exist in target project |
| `variables` | No | Key-value defaults, overridable at init |

## Operations

**`<archeflow-root>/lib/archeflow-init.sh <bundle-name>`** (what `/archeflow:init` runs)
1. Find bundle (project-local, then global)
2. Check `requires` files exist
3. Warn before overwriting existing `.archeflow/` config
4. Copy files to `.archeflow/` (teams/, workflows/, archetypes/, domains/)
5. Generate `.archeflow/config.yaml` with variables

**`<archeflow-root>/lib/archeflow-init.sh --from <project-path>`**
- Copy teams/, workflows/, archetypes/, domains/, config.yaml, hooks.yaml
- Skip run-specific data: events/, artifacts/, context/, templates/

**`<archeflow-root>/lib/archeflow-init.sh --save <name>`**
- Package current `.archeflow/` into `~/.archeflow/templates/bundles/<name>/`
- Auto-generate manifest.yaml

**`<archeflow-root>/lib/archeflow-init.sh --list`**
- Show all bundles and individual templates (global + project-local)

## Variable Substitution

Variables in manifests are stored in `.archeflow/config.yaml` after init. Substitution happens at run time, not template time.

Override at init: `<archeflow-root>/lib/archeflow-init.sh backend-feature --set max_cycles=3`

## Individual Templates

Single files can be copied directly without a bundle:
- `~/.archeflow/templates/workflows/<name>.yaml`
- `~/.archeflow/templates/archetypes/<name>.md`
- `~/.archeflow/templates/teams/<name>.yaml`
