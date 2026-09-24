# Hooks

Hooks run your own shell commands at fixed points of a run: a lint gate before a merge, a
notification when a run finishes, a timing log. They are optional.

Hooks are run by the orchestrating agent while it follows the run skill, not by a script. The
authoritative specification is the Hooks section of the `workflow-design` skill; this page
describes the same thing.

## Where hooks live

`.archeflow/hooks.yaml` in your project, one top-level key per hook:

```yaml
pre-merge:
  command: "npm run lint && npm run typecheck"
  fail_action: abort
run-complete:
  command: "echo \"run $ARCHEFLOW_RUN_ID: $ARCHEFLOW_STATUS\" >> .archeflow/hooks.log"
  fail_action: warn
```

Each hook has:

- `command`: run from the project root as
  `ARCHEFLOW_RUN_ID=<run_id> <other variables> bash -c '<command>'`.
- `fail_action`: `warn` logs the failure and continues; `abort` records a `decision` event
  (`"chosen": "hook_abort"`), stops the run and reports to you.

`archeflow-init.sh` copies a `hooks.yaml` from a bundle or from another project when one exists,
and warns you to review it.

## Hook points

| Hook | When | Variables | Default `fail_action` |
|------|------|-----------|-----------------------|
| `run-start` | after the run is set up, before Plan | `ARCHEFLOW_RUN_ID`, `ARCHEFLOW_WORKFLOW` | `warn` |
| `pre-merge` | all reviewers approved, before the merge | `ARCHEFLOW_RUN_ID`, `ARCHEFLOW_BRANCH`, `ARCHEFLOW_TARGET` | `abort` |
| `post-merge` | after the merge and passing (or skipped) post-merge tests | `ARCHEFLOW_RUN_ID`, `ARCHEFLOW_BRANCH`, `ARCHEFLOW_TARGET` | `warn` |
| `run-complete` | at the end of the run, whatever the outcome | `ARCHEFLOW_RUN_ID`, `ARCHEFLOW_STATUS`, `ARCHEFLOW_CYCLES` | `warn` |

There are no other hook points; other keys in `hooks.yaml` are ignored.

Use `abort` for `pre-merge`: a failing check should block the merge. Use `warn` for the
informational hooks.

## Trust

A `hooks.yaml` can come from the repository you are working in, so its commands are as
dangerous as any script in that repository. The agent shows each hook command and asks for a yes
before running it for the first time in a session, and never runs a hook you declined. Review
`hooks.yaml` before running ArcheFlow in a repository you did not write (see
[SECURITY.md](../SECURITY.md)).

## Examples

Lint gate before merging:

```yaml
pre-merge:
  command: "npm run lint && npm run typecheck"
  fail_action: abort
```

Run timing log:

```yaml
run-start:
  command: "echo \"$(date -u +%FT%TZ) start run=$ARCHEFLOW_RUN_ID workflow=$ARCHEFLOW_WORKFLOW\" >> .archeflow/run-timing.log"
  fail_action: warn
```

Notification when a run ends (the webhook URL comes from your environment, not from the file):

```yaml
run-complete:
  command: >
    curl -s -X POST "$SLACK_WEBHOOK_URL" -H 'Content-Type: application/json'
    -d "{\"text\":\"ArcheFlow run $ARCHEFLOW_RUN_ID: $ARCHEFLOW_STATUS ($ARCHEFLOW_CYCLES cycles)\"}"
  fail_action: warn
```
