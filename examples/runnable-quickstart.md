# Quickstart: a first run in a scratch repository

A step-by-step first run in a throwaway repository. Steps 1 and 2 are exact commands with their
real output. From step 3 on, agents do the work, so your wording, findings and timings will
differ from the output shown here.

## 1. Create a scratch project

```bash
mkdir -p /tmp/af-demo && cd /tmp/af-demo
git init && echo "# Demo" > README.md && git add . && git commit -m "init"
```

Start Claude Code in `/tmp/af-demo` with the plugin installed (see the README), or run
`claude --plugin-dir /path/to/archeflow` to use a checkout.

## 2. Set up ArcheFlow

Ask for `/archeflow:init` with the `quick-fix` bundle, or run the script yourself:

```bash
/path/to/archeflow/lib/archeflow-init.sh quick-fix
```

Output:

```
Initializing from bundle: quick-fix
  Source: /path/to/archeflow/templates/bundles/quick-fix

  Team: team.yaml -> .archeflow/teams/
  Workflow: workflow.yaml -> .archeflow/workflows/
  Domain: domain.yaml -> .archeflow/domains/
  Config: .archeflow/config.yaml

ArcheFlow initialized from bundle: quick-fix
  Variables: lint_command=, max_cycles=1

Ready to run: archeflow:run
```

The script also writes `.archeflow/.gitignore` (keeps secrets, locks and logs out of git). The
`quick-fix` bundle is a one-cycle setup: Creator plans, Maker implements, Guardian reviews.
`/archeflow:init` additionally asks for your test command and stores it as `test_command` in
`.archeflow/config.yaml`; with the plain script, add that line yourself if you want tests to run
after a merge. Commit the setup (or at least your code) before the run: a run refuses to start
while tracked files have uncommitted changes.

## 3. Run a task

```
/archeflow:run "Create a fibonacci function in Python with tests for negative input, zero and large n" --workflow fast
```

With `--dry-run` the run stops after the Plan phase, shows the proposal and a cost estimate,
and asks whether to continue.

## 4. What happens

| Phase | Role | What it does |
|-------|------|--------------|
| Plan | Creator | Writes a proposal: files to change, approach, test cases, and its confidence. The `fast` workflow has no Explorer. |
| Do | Maker | Implements the proposal in its own git worktree (`.archeflow/worktrees/<run_id>/`), tests first, and commits; its commits are then merged into the run branch. |
| Check | Guardian | Reviews the diff: correctness, error paths, security. Each finding has a severity, a location and a suggested fix. |
| Act | orchestrator | If the Guardian approves, you are asked whether to merge the run branch `archeflow/<run_id>` into the branch you started from. Otherwise the findings go back for another cycle, or, with one cycle only, the run stops, keeps the branch and reports to you. |

The session shows a short status line per phase, for example (illustrative):

```
Run ID: 2026-09-24-fibonacci | Workflow: fast | Cycle: 1/1
  Creator: proposal ready (2 files, 5 test cases)
  Maker: 2 files changed, tests passing
  Guardian: APPROVED (1 INFO)
```

## 5. Look at the run

```
/archeflow:status     # task, phase, cycle, findings
/archeflow:dag        # the run as a tree of events
/archeflow:report     # Markdown report
```

The same data is on disk:

```
/tmp/af-demo/
  fibonacci.py, test_fibonacci.py      # the change (names depend on the proposal)
  .archeflow/
    config.yaml, .gitignore            # from step 2
    teams/ workflows/ domains/         # from step 2
    events/<run_id>.jsonl              # event log: one JSON object per line
    artifacts/<run_id>/                # proposal, review and other agent output
    events/index.jsonl                 # one line per finished run
```

You can render the log yourself:

```bash
/path/to/archeflow/lib/archeflow-dag.sh .archeflow/events/<run_id>.jsonl
/path/to/archeflow/lib/archeflow-report.sh .archeflow/events/<run_id>.jsonl --output report.md
```

## Next steps

- Run the same task with `--workflow standard`: adds the Explorer, the Skeptic and the Sage.
- Review a change without implementing anything: `/archeflow:review`.
- Read how the roles and the cycle work: "Core concepts" in the README.
