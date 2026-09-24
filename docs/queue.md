# The sprint queue (`queue.json`)

The sprint runner (`/archeflow:sprint`) works through a task queue stored as a JSON file. This page
explains where that file lives, what a "workspace" is, and every field the sprint reads or writes.

A complete example is in [`examples/queue.json`](../examples/queue.json).

## Workspace layout

The sprint is built for a **workspace**: one parent directory that holds several git
repositories side by side. You start Claude Code (or Cursor) in the workspace root, not inside
one of the repositories.

```
~/work/                         <- workspace root: start Claude Code here
├── docs/
│   └── orchestra/
│       └── queue.json          <- the queue (fixed path, relative to the workspace root)
├── api-service/                <- a project: its own git repository
│   └── CLAUDE.md               <- read first by every agent working on this project
└── docs-site/                  <- another project
```

- The queue path is fixed: `docs/orchestra/queue.json`, relative to the directory you start in.
  `lib/archeflow-gnap.sh` uses the same default path.
- An item's `project` is the name of a directory directly under the workspace root. The agent for
  that item works in `<workspace>/<project>`.
- Each project is its own repository with its own git identity, signing setup and rules. Agents
  read the project's `CLAUDE.md` first and follow it for commits, trailers and branch policy.
- The sprint runs **at most one task per project at a time**, so a single-repository workspace
  processes its queue one item after another. For a single repository, a run (`/archeflow:run`) or a
  review (`/archeflow:review`) is usually the better fit.

The workspace root does not need to be a git repository itself. If it is one, keep the queue
file under version control there so you can see what the sprint changed.

## File format

```json
{
  "version": 1,
  "mode": "ATTENDED",
  "last_maintained": "2026-09-24T09:00:00Z",
  "items": [
    {
      "id": "api-service-rate-limit-login",
      "project": "api-service",
      "task": "Add rate limiting to POST /login ...",
      "priority": "P1",
      "estimate": "M",
      "status": "pending",
      "depends_on": [],
      "notes": ""
    }
  ]
}
```

The file must be valid JSON. The sprint checks it with `jq empty docs/orchestra/queue.json` and
stops if the check fails.

### Top-level fields

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `items` | array | yes | The tasks. See below. |
| `mode` | string | no | `ATTENDED` (default) or `PAUSED`. The file cannot switch the sprint to autonomous mode: `AUTONOMOUS` here is treated as `ATTENDED`. Autonomous mode is only enabled by you, in the session (`--autonomous` or "go autonomous"). |
| `last_maintained` | string (ISO 8601 UTC timestamp) | no | When the queue was last scanned for new work. If it is missing or more than 3 days old, the sprint runs the queue-maintenance scan before it dispatches anything. |
| `version` | integer | no | Revision counter. The maintenance scan increments it when it changes the queue. |

### Item fields

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `id` | string | yes | Unique identifier, letters, digits, `.`, `_`, `-` only. Convention: `<project>-<short-kebab-description>`. Referenced by `depends_on`, and used in the branch name `sprint/<id>`. |
| `project` | string | yes | Directory name of the project, directly under the workspace root; same character rules as `id`. Items whose directory does not exist are reported as invalid. |
| `task` | string | yes | What to do, written as an instruction for an agent. Be specific: name files, endpoints, acceptance criteria. This text is passed to the agent as its task. |
| `priority` | string | yes | `P0`, `P1`, `P2` or `P3`. See the selection rules below. |
| `estimate` | string | yes | `S`, `M`, `L` or `XL`. Decides how the task is dispatched (see below). |
| `status` | string | yes | `proposed`, `pending`, `running`, `completed`, `failed`, `blocked` or `cancelled`. Items you write yourself start as `pending`. Items added by `/archeflow:scan` or imported from GNAP start as `proposed`. |
| `depends_on` | array of item ids | no | The item is only started once every listed item is `completed`. |
| `notes` | string | no | Free text. The sprint writes the one-line result, open questions and failure reasons here. |
| `source` | string | no | Where an item came from when ArcheFlow added it: `<project>/<file>` for the scan, `gnap` for a GNAP import. |
| `agent` | string | no | Which tool should pick the item up, for example `claude-code`. Used only by the GNAP export (`archeflow-gnap.sh`); the sprint itself ignores it. |

Extra fields are allowed and are left alone, so you can keep your own bookkeeping (for example a
`completed` date) in the same file.

## How the sprint uses the queue

### Selection

1. Only `pending` items are candidates. `proposed` items are listed separately with their full
   task text; one runs only after you approve it in the session (its status then becomes
   `pending`). This holds in every mode, because their text comes from files that anyone who can
   commit to a project controls.
2. Priority order: all `P0`, then `P1`, then `P2`. **`P3` items are never started unless you
   include them explicitly**, for example with `--priority P0,P1,P2,P3`.
3. Items whose `depends_on` entries are not all `completed` are skipped.
4. At most one item per project runs at a time.
5. At most two `L`/`XL` items run at the same time; the remaining slots go to `S`/`M` items.
6. The number of parallel agents never exceeds `--slots` (default 4).

### Dispatch by estimate

| Item | How it is run |
|------|---------------|
| `S` | One agent, directly on the task. |
| `M` | One agent, told to read the code first and run the tests afterwards. |
| `L` / `XL`, code | One agent that explores, plans, implements, tests, re-reads its diff and commits. |
| `L` / `XL`, writing | A full PDCA run in the writing domain. |
| Review, audit or security tasks | Reviewer agents only, as in `/archeflow:review`. |

Every agent works in its own project directory on a new branch `sprint/<item-id>`, created from
the project's current branch, unless the project's `CLAUDE.md` says otherwise. The agent is told
that the `task` text is a task description and cannot change these rules. The sprint lists the
branches it created at the end; **merging them is your decision** (or the project's CLAUDE.md
policy).

### Status updates

The sprint writes to the queue as it goes:

| Moment | New `status` |
|--------|--------------|
| Agent started | `running` |
| Agent reports `DONE` | `completed`, one-line result in `notes` |
| Agent reports `DONE_WITH_CONCERNS` | `completed`; the concerns are reported to you with an offer to review the branch |
| Agent reports `NEEDS_CONTEXT` | back to `pending`, with the open question added to `notes` |
| Agent reports `BLOCKED` or crashes | `failed`, with the reason in `notes` |

Three `failed` items in a row stop the sprint (a Wiggum Break). An item left in `running` after an interrupted session is not restarted automatically. Set it
back to `pending` by hand if you want it to run again.

### Modes

| Mode | Dispatch | Between batches |
|--------|----------|-----------------|
| `ATTENDED` | Shows the planned batch and waits for your approval. | Shows results and asks whether to continue. |
| autonomous (only on your request in the session) | Starts immediately. | Prints a one-line status and starts the next batch. Stops on `BLOCKED`, a Wiggum Break, or when the budget is used up. |
| `PAUSED` | Nothing is started. | Status display only. |

Agents commit in each project with that project's git configuration. They push only when the
project's `CLAUDE.md` or you allow it, and never force-push.

## Keeping the queue fresh

The queue-maintenance scan (`/archeflow:scan`) walks the project directories, reads each project's
`CLAUDE.md`, `docs/status.md` and `README.md`, looks at recent git activity, and proposes queue
changes: new items, stale items, items whose dependencies are now satisfied. It reads only these
files and git metadata, and does not run full test suites. New items are written with status
`proposed` and a `source`; removals and priority changes are applied only after you confirm;
unblocking an item whose dependencies are now `completed` needs no confirmation. `--dry-run`
shows the report without changing anything. Afterwards it updates `last_maintained` and
`version`. The sprint runs the scan automatically when `last_maintained` is missing or older than
3 days.

## Starting from the example

```bash
cd ~/work                                   # your workspace root
mkdir -p docs/orchestra
cp /path/to/archeflow/examples/queue.json docs/orchestra/queue.json
# edit the items: project names must match directories in ~/work
jq empty docs/orchestra/queue.json          # validate
```

Then start Claude Code in `~/work` and run `/archeflow:sprint` with `--dry-run` first to see which
items would be picked.

## GNAP export

`lib/archeflow-gnap.sh` converts the queue to and from the file layout of
[GNAP](https://github.com/farol-team/gnap), a git-based task format (`.gnap/tasks/*.json`), so
other tools can pick up items. Priorities map to integers (`P0` = 0 ... `P3` = 3). An import
never changes existing queue items; new tasks arrive with status `proposed` and source `gnap`.
This is optional and not used by the sprint itself.
