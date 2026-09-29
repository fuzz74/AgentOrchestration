# Agent Orchestrator: Design & Usage

A small PowerShell harness that runs a dependency graph of coding tasks with parallel
`claude -p` agents. Each agent works in its own git worktree, and only work that passes
tests and a review agent is merged. No framework: PowerShell 7, git and the Claude Code CLI.

```
/write-spec ──► spec.md ──► Plan-Tasks.ps1 ─────────────────────► .orchestrator/tasks.json ──► (you review) ──► Invoke-Orchestrator.ps1 ──► orch/integration ──► (you merge)
 interview                  skeleton (new repo) + planner agent    task graph                                    parallel workers + gates
```

- [At a glance](#at-a-glance)
- [From idea to finished application](#from-idea-to-finished-application)
- [The task file](#the-task-file)
- [Writing a spec](#writing-a-spec)
- [Planning](#planning)
- [Scheduling](#scheduling)
- [Gates and merging](#gates-and-merging)
- [Files and state on disk](#files-and-state-on-disk)
- [Command reference](#command-reference)
- [Agent permissions and safety](#agent-permissions-and-safety)
- [Limits and known gaps](#limits-and-known-gaps)
- [Where the design comes from](#where-the-design-comes-from)

## At a glance

A planner agent turns a spec into tasks with dependencies. The scheduler runs every task
whose dependencies are merged, several at once, each in a fresh worktree. A task is merged
only after it passes its own checks, and each merge unblocks the tasks that depend on it.

```
                    ┌──────────────────────────── scheduler loop (Invoke-Orchestrator.ps1) ───────────────────────────┐
                    │  ready = pending + all deps done + owns don't overlap a running task, up to -MaxParallel         │
                    │  order: re-sync tasks first, then tasks with the most dependents (critical path)                │
                    └───────────────┬──────────────────────────────────────────────┬───────────────────────────────────┘
                                    │ one thread job per task                      │
                                    ▼                                              ▼
 ../<repo>.worktrees/<id>   branch orch/task/<id>, cut from orch/integration   (same for every other running task)
    1 worker agent  ──►  2 commit  ──►  3 owns check  ──►  4 merge orch/integration in  ──►  5 acceptance  ──►  6 review agent
         ▲                                                   (resolver agent on conflict)     command          (2 verdicts)
         │                                                                                                          │
         └──────────── any gate fails: feedback goes back to the same worker session (--resume), up to maxAttempts ─┘
                                                                                                                    │ pass
                                                                                                                    ▼
 orch/integration  ◄── merge --no-ff (single writer)  ──►  optional integrationCheck (merge undone if it fails)  ──►  dependents unblock
```

## From idea to finished application

This walkthrough builds an application in a new repo, `C:\src\myapp`, with this repo
checked out at `C:\Data\AgentOrchestration`. Replace both paths with your own.

You do three things by hand: answer the spec interview, look over the plan and merge the
result. Creating the repo, the project skeleton, the plan and the code is automated.

**Where the work happens.** Every step says which of these three places to use:

| Place | What it is | How to open it |
| --- | --- | --- |
| **Terminal** | PowerShell 7 (`pwsh`), not Windows PowerShell 5.1 | Windows Terminal with the *PowerShell* profile, or in VS Code **Terminal → New Terminal**. Check with `$PSVersionTable.PSVersion` (7.2 or later). |
| **Claude chat** | Claude Code, interactive, started in the `AgentOrchestration` folder. The `/write-spec` and `/plan-tasks` skills live in this repo, so they are only available there. | VS Code: **File → Open Folder…** → `C:\Data\AgentOrchestration`, then open the Claude Code panel (Spark icon, or **Ctrl+Esc**). Or in a terminal: `cd C:\Data\AgentOrchestration; claude`. |
| **Editor** | VS Code, for reading and editing files | **File → Open File…** or **File → Open Folder…** |

Orchestrator commands in the terminal steps assume the current folder is
`C:\Data\AgentOrchestration`.

### Step 0: One-time setup

1. **Install** (any way you like): PowerShell 7.2+, git 2.20+, VS Code, and Claude Code (the
   VS Code extension, the CLI, or both).
2. **Log in to Claude Code.** In VS Code, open the Claude Code panel and sign in. For the CLI,
   run `claude` in a terminal and follow the login prompt. The scripts look for `claude` in
   this order: `-ClaudePath`, the `ORCH_CLAUDE` environment variable, `claude` on `PATH`,
   then the binary bundled with the VS Code extension. So the extension alone is enough.
3. **Get this repo** (terminal):
   ```powershell
   git clone https://github.com/fuzz74/AgentOrchestration C:\Data\AgentOrchestration
   cd C:\Data\AgentOrchestration
   ```
4. **Check that it works, without spending tokens** (terminal):
   ```powershell
   .\tests\Run-SmokeTest.ps1
   ```
   This runs the whole flow with a fake `claude`, from a folder that doesn't exist yet to
   merged work. It covers:
   - creating the project skeleton, with one failed attempt that gets fixed
   - a 4-task diamond
   - a forced edit outside `owns`, with a retry
   - a run with no structured result
   - a merge conflict and a resolver run

   It ends with 12 passing checks.
5. **Access to your projects: nothing to do now.** The target repo is outside this folder,
   and Claude Code asks before reading or writing there. The first time you give
   `/write-spec` or `/plan-tasks` a repo path, Claude offers to allow that repo or its
   parent folder, such as `C:\src`. The parent folder covers all future projects. Say yes,
   then approve the edit Claude Code shows. It adds the folder to
   `.claude\settings.local.json`, which applies at once and is excluded by this repo's
   `.gitignore`. After that you aren't asked again.

   Claude can't grant itself access without that approval. The approval is Claude Code's
   safety boundary, not a missing feature. To set access up yourself instead, add
   `{ "permissions": { "additionalDirectories": ["C:\\src"] } }` to that file. In the CLI,
   you can also use `/add-dir C:\src\myapp` or start with `claude --add-dir C:\src`.

### Step 1: Turn the idea into a spec

Where: **Claude chat** in `C:\Data\AgentOrchestration`.

1. Type:
   ```
   /write-spec
   ```
   Then describe the idea in a few sentences and give the repo path `C:\src\myapp`. Or all
   at once: `/write-spec a habit tracker web app in C:\src\myapp`. The folder doesn't need
   to exist yet.
2. Answer its questions. It asks one at a time, mostly as multiple choice. It proposes 2-3
   approaches, then walks through the design section by section and waits for your "yes"
   after each one:
   - requirements
   - modules and their file paths
   - shared contracts (types, APIs, schema)
   - build order
   - verification commands
   - constraints

   For a new project, the stack and verification sections decide the project skeleton, so
   Claude pins them down: language, framework, test runner, and the setup and test
   commands.
3. It writes the spec to `C:\src\myapp\.orchestrator\spec.md`. A reviewer subagent then
   checks it, and Claude fixes what the reviewer finds.
4. **Read the spec** (editor): open `C:\src\myapp\.orchestrator\spec.md`. Pay most attention
   to three sections:
   - **4.2 Modules**: the paths become the task boundaries.
   - **4.3 Shared contracts**: everything parallel agents must agree on.
   - **6 Verification**: the setup and test commands, which every task relies on.

   Ask for changes in the chat, or edit the file yourself. Tell the chat when you approve it.

The spec is pasted into every agent's prompt, so shorter and more precise is better. See
[Writing a spec](#writing-a-spec).

### Step 2: Plan the tasks

For a new project, planning first creates the project skeleton automatically:

- `git init`
- a bootstrap agent that sets up the manifest, dependencies, test runner and one smoke test
  for the spec's stack
- a commit
- a check, in a clean checkout, that the setup command and the whole-project check pass. If
  they fail, the agent gets the output and fixes the skeleton, up to 3 attempts.

The two commands are saved in `.orchestrator/project.json` and become the plan's `setup` and
`integrationCheck`. A repo that already has commits is left as it is.

Pick one:

- **Interactive** (**Claude chat**, same conversation): accept the hand-off, or type
  `/plan-tasks`. For a new project, Claude first runs `Initialize-Project.ps1` for you. Then
  it proposes the task table and lets you adjust it. Finally it writes
  `C:\src\myapp\.orchestrator\tasks.json` and validates it.
- **Scripted** (**terminal**): one planner agent (Opus by default) plans without questions.
  ```powershell
  .\orchestrator\Plan-Tasks.ps1 -Spec C:\src\myapp\.orchestrator\spec.md -RepoPath C:\src\myapp
  ```
  While it works, it prints one line per tool call of the skeleton and planner agents (for
  example `[planner] Read src/app.csproj`), so you can see it is making progress. Planning a
  large spec takes several minutes. At the end it prints the planner's notes (assumptions,
  open questions) and the waves of parallel tasks.
  For an existing repo without `project.json`, add `-Setup 'npm ci'` and
  `-IntegrationCheck 'npm run build && npm test'` (your own commands).

### Step 3: Review the plan

Where: **editor**, then **terminal**.

1. Open `C:\src\myapp\.orchestrator\tasks.json`. Check each task:
   - `owns` is tight, and tasks meant to run in parallel don't overlap.
   - `acceptance` is a real command that proves the task works.
   - `prompt` makes sense on its own.
   - `settings.setup` installs dependencies in a fresh checkout, and
     `settings.integrationCheck` builds and runs all tests. After each merge the
     orchestrator runs both, in that order.

   See [The task file](#the-task-file) for every field.
2. Validate and preview the run:
   ```powershell
   .\orchestrator\Show-Tasks.ps1 -RepoPath C:\src\myapp
   .\orchestrator\Invoke-Orchestrator.ps1 -RepoPath C:\src\myapp -DryRun
   ```
   `-DryRun` prints the waves and warns about `owns` overlaps within a wave. Fix anything it
   reports, then run it again.

### Step 4: Run the build

Where: **terminal**. Leave it open until the run ends.

```powershell
.\orchestrator\Invoke-Orchestrator.ps1 -RepoPath C:\src\myapp -MaxParallel 3
```

- Progress prints live. For a live dashboard, open a **second terminal** in
  `C:\Data\AgentOrchestration` and run:
  ```powershell
  .\orchestrator\Watch-Orchestrator.ps1 -RepoPath C:\src\myapp
  ```
  It redraws every 2 seconds and shows:
  - a progress bar, task counts and cost so far
  - how many agents are working, and on which tasks
  - each running agent's phase and its latest tool calls
  - every task's status
  - the last lines of the log

  Press Ctrl+C to close it; the run keeps going. It also works during `Plan-Tasks.ps1`, where
  it shows the skeleton or planner agent. For a one-off status table instead, run
  `.\orchestrator\Show-Tasks.ps1 -RepoPath C:\src\myapp`.
  You can also open `C:\src\myapp\.orchestrator\progress.md` in the **editor**. While an
  agent works, a heartbeat line at most once a minute shows how many tool calls it has made
  and the latest one, for example `[s2] worker: 14 tool calls, last: Edit src/Game.cs`.
- Agents work in `C:\src\myapp.worktrees\<task-id>`. Don't edit files in `C:\src\myapp` or in
  those folders during the run.
- The exit code is 0 when every task is done and 2 when some failed or were blocked.
- To stop, press Ctrl+C. Running `claude` processes can keep going for a while; check Task
  Manager. Rerun the same command later to resume: finished tasks stay finished.

### Step 5: Fix failed tasks

Skip this step if every task is done.

1. **Find out why** (terminal):
   ```powershell
   .\orchestrator\Show-Tasks.ps1 -RepoPath C:\src\myapp
   ```
   The detail column shows the error. For the full story, open the task's latest log
   folder, `C:\src\myapp\.orchestrator\logs\<task-id>\<timestamp>\`, in the **editor**. It
   holds the prompts, the Claude results and the command output. Each `*.events.jsonl` file
   is the agent's full event stream, one JSON event per line: every message and tool call.
2. **Fix the cause** (editor):
   - Usually edit the task in `tasks.json`: a clearer `prompt`, wider `owns`, or a correct
     `acceptance` command.
   - If the spec itself was wrong, fix `spec.md` as well.
   - If the work is too big for one task, add a task. Adding tasks between runs is fine.
3. **Retry** (terminal):
   ```powershell
   .\orchestrator\Invoke-Orchestrator.ps1 -RepoPath C:\src\myapp -RetryFailed
   ```

### Step 6: Try the finished application

Where: **editor** and **terminal**.

The result is on the `orch/integration` branch, which is checked out in
`C:\src\myapp.worktrees\_integration`.

1. **Read the changes.** In VS Code, **File → Open Folder…** →
   `C:\src\myapp.worktrees\_integration`. Or list them in a terminal:
   ```powershell
   git -C C:\src\myapp diff --stat main...orch/integration
   ```
2. **Run the app and its tests** in a terminal in that folder:
   ```powershell
   cd C:\src\myapp.worktrees\_integration
   npm ci
   npm test
   npm start
   ```
3. **Small fixes**: make them yourself, or with Claude chat opened in that folder, and commit
   them on `orch/integration`. **Bigger gaps**: add tasks to `tasks.json` and go back to
   step 4.

### Step 7: Merge and clean up

Where: **terminal**.

1. Merge into your base branch. The main checkout must be on `main` with no uncommitted
   changes.
   ```powershell
   git -C C:\src\myapp switch main
   git -C C:\src\myapp merge --no-ff orch/integration
   ```
2. Push if the repo has a remote: `git -C C:\src\myapp push`. The orchestrator never pushes.
3. Remove the worktrees, the `orch/*` branches, the run state and the logs (run from
   `C:\Data\AgentOrchestration`):
   ```powershell
   .\orchestrator\Clear-Orchestrator.ps1 -RepoPath C:\src\myapp -All
   ```
   `-All` keeps `tasks.json` and `spec.md`. Add `-WhatIf` first if you want to see what it
   removes. First close any VS Code window or terminal that is open in a worktree folder:
   Windows can't delete a folder that is in use.

### Step 8: The next feature

Go back to step 1 with the next idea. `/write-spec` now sees the code that exists and
specifies only the change. Then:

- Plan with `-Force`, which overwrites `tasks.json`, or let `/plan-tasks` replace it. The
  repo now has commits, so no new skeleton is made, and `project.json` still supplies the
  commands.
- `.orchestrator/` is never committed. To keep old specs, copy them to a folder such as
  `C:\src\myapp\docs\specs\` and commit them.

## The task file

`.orchestrator/tasks.json` is the whole plan. You own it: edit it freely between runs.
Run state lives in a separate file (`state.json`), keyed by task id, so editing the plan
never loses progress. The JSON Schema is
[orchestrator/schemas/tasks.schema.json](orchestrator/schemas/tasks.schema.json).

```json
{
  "version": 1,
  "spec": ".orchestrator/spec.md",
  "baseBranch": "main",
  "integrationBranch": "orch/integration",
  "settings": { "model": "sonnet", "reviewModel": "sonnet", "maxAttempts": 3, "setup": "npm ci",
                "shared": ["package-lock.json"] },
  "tasks": [
    { "id": "api-types", "title": "Shared API types", "deps": [], "owns": ["src/types/**"],
      "acceptance": "npx tsc --noEmit", "prompt": "Define the request and response types for ..." },
    { "id": "users-api", "title": "Users endpoints", "deps": ["api-types"], "owns": ["src/users/**"],
      "acceptance": "npm test -- src/users", "prompt": "Implement GET/POST /users using the types in src/types ..." },
    { "id": "orders-api", "title": "Orders endpoints", "deps": ["api-types"], "owns": ["src/orders/**"],
      "acceptance": "npm test -- src/orders", "prompt": "..." }
  ]
}
```

**Task fields**

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Unique, `^[a-z0-9][a-z0-9._-]{0,48}$`. Becomes branch `orch/task/<id>` and folder names. |
| `title` | yes | One line, used in logs and commit messages. |
| `prompt` | yes | Self-contained instructions for the worker. |
| `deps` | no | Ids that must be merged before this task starts. |
| `owns` | no | Repo-relative globs the task may edit (`**`, `*`, `?`; a plain path covers a file or a folder). Tasks with overlapping `owns` never run together. Empty = whole repo, so the task runs alone. |
| `acceptance` | no | Command run with `pwsh` in the worktree root. Exit code 0 = pass. |
| `model` | no | Worker model for this task only. |

**Settings** (all optional; the defaults are in `Orchestrator.psm1`)

| Setting | Default | Meaning |
| --- | --- | --- |
| `model` | `sonnet` | Worker model (alias or full id). |
| `reviewModel` | `sonnet` | Model for the reviewer and the conflict resolver. |
| `effort` | none | `--effort` for workers: `low` … `max`. |
| `permissionMode` | `acceptEdits` | Worker permission mode: `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`. |
| `allowedTools` | `Read, Edit, Write, Glob, Grep, Bash, PowerShell` | Tools the worker may use without a prompt, in permission-rule syntax (e.g. `Bash(npm *)`). |
| `maxAttempts` | `3` | Worker runs per task before it fails. |
| `maxBudgetUsd` | `10` | `--max-budget-usd` for each claude call. |
| `review` | `true` | Run the review agent after acceptance passes. |
| `setup` | none | Command run once in each fresh worktree (e.g. `npm ci`, `uv sync`). |
| `integrationCheck` | none | Command run in the integration worktree after each merge, after `setup`. A failure undoes the merge and fails the task. |
| `commandTimeoutSec` | `1800` | Timeout for setup, acceptance and integration commands. |
| `enforceOwns` | `true` | Reject a task that edits files outside `owns` + `shared`. |
| `shared` | `[]` | Globs any task may edit (lock files, registries). Not used for scheduling, so edits to them can conflict. The resolver handles those conflicts. |
| `ignore` | `__pycache__`, `*.pyc`, `.pytest_cache`, `.mypy_cache`, `.venv`, `node_modules`, `.DS_Store` | Globs never committed from a worktree, even when the repo's `.gitignore` misses them. Setting this replaces the whole default list. |

## Writing a spec

The planner, every worker and every reviewer get the whole spec in their prompt, and none of
them can ask questions. A spec that splits well is short, and it names things precisely.
It gives:

- module boundaries as file paths (they become `owns`)
- shared interfaces written out as code (they become the contracts-first task)
- a build order (it becomes `deps`)
- runnable test commands (they become `acceptance`)
- testable requirements with ids that task prompts and reviewers can cite

The `/write-spec` skill ([.claude/skills/write-spec](.claude/skills/write-spec/SKILL.md))
writes such a spec with you:

- It interviews you one question at a time, proposes approaches and gets each design section
  approved.
- It writes the spec from a [template](.claude/skills/write-spec/spec-template.md), with EARS
  acceptance criteria.
- It has the spec checked by a fresh [reviewer subagent](.claude/skills/write-spec/reviewer-prompt.md).
- It saves the result to `.orchestrator/spec.md` and hands off to `/plan-tasks`.

The method adapts [Superpowers' brainstorming skill](https://github.com/obra/superpowers/blob/main/skills/brainstorming/SKILL.md)
and [cc-sdd](https://github.com/gotalab/cc-sdd)'s requirements and design rules. Copies of
the originals and their MIT licenses are in [references](.claude/skills/write-spec/references/README.md).

## Planning

If the target repo is new (no folder, no git repo, or no commits), `Plan-Tasks.ps1` first
calls `Initialize-Project.ps1`:

1. `git init -b main`, then a bootstrap agent ([prompts/bootstrap.md](orchestrator/prompts/bootstrap.md),
   the worker model and tools) creates the skeleton for the stack in the spec: manifest, lock
   file, test runner, `.gitignore`, one smoke test and a README. It writes no feature code
   and nothing inside module paths.
2. The script commits the skeleton, then runs the agent's setup command and whole-project
   check in a clean detached worktree. A failure goes back to the same session, and the fix
   is amended into the one commit, up to 3 attempts.
3. The two commands go to `.orchestrator/project.json`. They become the default `-Setup`
   and `-IntegrationCheck`.

Then `Plan-Tasks.ps1` runs one planner agent (`--model opus` by default) in the target repo.
The planner has only `Read`, `Glob` and `Grep`, so it can explore the code but not change
it. Its prompt is [prompts/planner.md](orchestrator/prompts/planner.md). The output must
match [plan-output.schema.json](orchestrator/schemas/plan-output.schema.json)
(`--json-schema`).

The script then:

1. Copies the spec to `.orchestrator/spec.md` if the spec lives outside the repo.
2. Writes `tasks.json` with the planner's tasks and your settings (`-WorkerModel`, `-Setup`, `-IntegrationCheck`).
3. Validates the graph: schema, ids, unknown deps, self-deps, cycles. If the graph is
   invalid, the planner session is resumed once with the list of problems.
4. Prints the planner's notes (assumptions and open questions) and the waves (`-DryRun`).

The planner prompt asks for right-sized tasks (15–60 minutes of agent work), few
dependencies, a contracts task first when parts must share an interface, tight
non-overlapping `owns`, a targeted acceptance command per task, and self-contained
prompts. The `/plan-tasks` skill ([.claude/skills/plan-tasks](.claude/skills/plan-tasks/SKILL.md))
applies the same rules interactively, so you can discuss the split before the file is written.

## Scheduling

The scheduler is a single loop in `Invoke-Orchestrator.ps1`. It is the only writer of
`state.json` and of the integration branch.

- **Ready**: status `pending` and every dependency `done` (merged).
- **Isolation**: a ready task waits if its `owns` overlaps a running task's `owns`. The
  overlap test is conservative: two globs overlap when the literal prefix of one (the
  part before the first wildcard) starts with the other's prefix.
- **Order**: tasks re-queued for a sync go first. After them, tasks with the most
  transitive dependents go first, so the critical path starts early.
- **Parallelism**: up to `-MaxParallel` (default 3) tasks run as PowerShell thread jobs.
  Each job runs the whole per-task pipeline and returns a verdict.
- **Worktrees**: `../<repo>.worktrees/<id>` on branch `orch/task/<id>`, cut from the
  current tip of `orch/integration`. So a task always starts from its merged
  dependencies. Worktrees sit outside the repo folder so agents never see or edit the
  main checkout.
- **Context between tasks**: when a task finishes, the worker returns a `summary` and
  `notes_for_dependents`. Both are pasted into the prompts of the tasks that depend on
  it, and the code itself is on the branch those tasks start from.

## Gates and merging

Each task runs this pipeline in its worktree (see `Invoke-TaskPipeline` in
[Orchestrator.psm1](orchestrator/Orchestrator.psm1)):

1. **Setup** (fresh worktrees only): the `setup` command, if set.
2. **Worker**: `claude -p` with [prompts/worker.md](orchestrator/prompts/worker.md) and
   [worker-result.schema.json](orchestrator/schemas/worker-result.schema.json). The worker
   returns `done` or `blocked`, a summary, and notes for dependents. `blocked` fails the task
   at once. Models sometimes finish the work but skip the structured result, or only claim
   they returned it. In that case the session is resumed once with "report your result now".
   If there is still no result, the worker's plain-text answer is used as the summary, and
   the gates below decide.
3. **Commit**: the orchestrator commits everything in the worktree except the `ignore`
   globs (build artifacts such as `__pycache__`). Workers are told not to commit.
4. **Ownership**: files changed against `orch/integration` (merge-base diff) must match
   `owns` + `shared`, and there must be at least one change.
5. **Sync**: `orch/integration` is merged into the task branch. If that conflicts, a
   resolver agent ([prompts/resolver.md](orchestrator/prompts/resolver.md)) resolves the
   conflicts and stages the result. Leftover conflict markers abort the merge and count as
   a failure.
6. **Acceptance**: the task's command, with a timeout. The last 80 lines of output
   become feedback on failure.
7. **Review**: a read-only reviewer ([prompts/reviewer.md](orchestrator/prompts/reviewer.md))
   gets the task, the spec and the diff. It returns a spec-compliance verdict and a
   code-quality verdict. Either `fail` rejects the change, and the reviewer's issues
   become feedback.

When a gate fails, the same worker session is resumed (`--resume`) with the feedback
([prompts/retry.md](orchestrator/prompts/retry.md)), up to `maxAttempts` worker runs.
When all gates pass, the scheduler merges `orch/task/<id>` into `orch/integration` with
`--no-ff`. If that merge conflicts (another task merged in the meantime), the task is
re-queued in sync mode. A sync run repeats steps 5–7 in the same worktree without calling
the worker. After more than 3 conflicting merges, the task fails. If `integrationCheck` is
set, it runs after each merge, after `setup` in the integration worktree, so that
dependencies are installed. A failing setup or check resets the integration branch to its
previous commit and fails the task.

**Statuses**: `pending` → `running` → `done` or `failed`. A pending task with a failed task
upstream is shown as `blocked`.

## Files and state on disk

| Path | What it holds |
| --- | --- |
| `<repo>/.orchestrator/tasks.json` | The plan. Yours to edit. |
| `<repo>/.orchestrator/spec.md` | The spec: written there by `/write-spec`, or copied there when it lives outside the repo. |
| `<repo>/.orchestrator/project.json` | Setup and integration-check commands from the skeleton bootstrap. |
| `<repo>/.orchestrator/state.json` | Per-task status, attempts, cost, session id, summary, notes, error, merged commit. |
| `<repo>/.orchestrator/progress.md` | Timestamped log of the whole run. |
| `<repo>/.orchestrator/logs/<id>/<timestamp>/` | Per-run logs: each prompt sent (`*.prompt.md`), each claude JSON result, and command output. |
| `../<repo>.worktrees/<id>` | Task worktree on `orch/task/<id>`. |
| `../<repo>.worktrees/_integration` | Worktree holding `orch/integration`. |

`.orchestrator/` is added to `.git/info/exclude`, so it is never committed and never
appears in the worktrees.

**Restarting**: rerun `Invoke-Orchestrator.ps1`. Done tasks stay done. Tasks left
`running` by an interrupted run start again from scratch. Failed tasks stay failed until
you pass `-RetryFailed`, usually after you edit their prompt or `owns`. You can add tasks
to the plan between runs.

## Command reference

| Script | Parameters |
| --- | --- |
| `Initialize-Project.ps1` | `-Spec` and `-RepoPath` (required), `-Model` (`sonnet`), `-ClaudePath`, `-MaxBudgetUsd` (`5`), `-MaxAttempts` (`3`). Creates and checks the skeleton of a new repo; does nothing if the repo has commits. `Plan-Tasks.ps1` calls it. |
| `Plan-Tasks.ps1` | `-Spec` (required), `-RepoPath` (`.`), `-Out` (plan path), `-Model` (planner, `opus`), `-WorkerModel` (`sonnet`), `-Setup`, `-IntegrationCheck` (both default to `project.json`), `-ClaudePath`, `-MaxBudgetUsd` (`5`), `-Force` (overwrite) |
| `Invoke-Orchestrator.ps1` | `-RepoPath` (`.`), `-Plan`, `-MaxParallel` (`3`), `-ClaudePath`, `-DryRun` (print waves and exit), `-RetryFailed`, `-PollSeconds` (`5`). Exit code 0 = all done, 2 = some failed or blocked, 1 = invalid plan. |
| `Show-Tasks.ps1` | `-RepoPath`, `-Plan`. Validates the plan and prints wave, status, deps, attempts, cost and detail per task. |
| `Clear-Orchestrator.ps1` | `-RepoPath`, `-All`. Without `-All`: removes task worktrees and `orch/task/*` branches, resets unfinished tasks to pending. With `-All`: also the integration worktree and branch, state, logs and progress. Supports `-WhatIf`. |
| `tests/Run-SmokeTest.ps1` | `-WorkDir`. End-to-end test with the fake claude, from an empty folder to merged work. |

## Agent permissions and safety

| Agent | Tools | Permission mode |
| --- | --- | --- |
| Bootstrap | worker defaults | `acceptEdits` |
| Planner | `Read`, `Glob`, `Grep` only (`--tools`) | `dontAsk` |
| Worker | `allowedTools` setting | `permissionMode` setting (default `acceptEdits`) |
| Resolver | worker tools + `git add/status/diff` | `acceptEdits` |
| Reviewer | `Read`, `Glob`, `Grep` only | `dontAsk` |

Every call runs with `--permission-prompts none`, so a tool that is not allowed is denied
and never waits for a person, and with `--max-budget-usd`.

- Workers run with `Bash`/`PowerShell` allowed by default, so they can run any command as
  you. Run the orchestrator only on repos you trust, or narrow `allowedTools` (for example
  `Bash(npm *)`) or use `permissionMode: auto`.
- `claude -p` loads the project's `CLAUDE.md`, hooks, skills and `.mcp.json` in every
  worktree and shows no trust prompt. That is useful for conventions, and a reason to
  run only trusted repos.
- Nothing is pushed. All merges are local, and merging `orch/integration` into your base
  branch is left to you.

## Limits and known gaps

- **Interrupting**: Ctrl+C stops the thread jobs, but `claude` processes already running
  can keep going until they finish. Check Task Manager. Their tasks restart from scratch
  on the next run.
- **Shared machine resources**: parallel tasks share ports, databases and caches. Tests
  that bind fixed ports can collide. Lower `-MaxParallel` or make tests use random ports.
- **Acceptance exit codes**: the command runs as `pwsh -Command`. Chain steps with `&&` so
  an early failure is not hidden by a later success.
- **Ownership is path-based**: `owns` prevents two agents from editing the same files at
  once. It does not stop semantic conflicts, for example two tasks that each change
  behaviour the other relies on. `integrationCheck` and good contracts tasks are the defence.
- **One integration branch** that is never rebased onto a moving base branch. Merge or
  rebase it yourself if `main` moves during a long run.
- **No agent-to-agent messaging**: context flows only through code, summaries and notes.
  That is deliberate, because it keeps every worker's context small.
- **Cost**: each task costs at least one worker call and one review call. Set
  `review: false` for trivial tasks or use a cheaper `reviewModel`. `state.json` records
  the cost per task (the CLI's client-side estimate).
- **Model choice**: Haiku workers do fine on small, well-specified tasks. They are more
  likely to skip the structured result, and the nudge covers that. Use Sonnet or better for
  real work and for the reviewer.
- **Tested**: on Windows 11 with PowerShell 7.6, git 2.49 and Claude Code 2.1.283. Tests:
  the smoke test, plus a real run. In the real run, a Sonnet planner split a 3-part Python
  spec into a chain of 3 tasks, and Haiku workers and reviewers built it. All 3 passed on
  the first attempt: 24 tests, 0.50 USD for the build, 0.27 USD for planning. The paths are
  cross-platform, but macOS and Linux are untested.

## Where the design comes from

| Choice here | Borrowed from |
| --- | --- |
| Stateless workers in a script loop; state kept in files and git, not in agent context | [Building a C compiler with a team of parallel Claudes](https://www.anthropic.com/engineering/building-c-compiler), [Ralph](https://ghuntley.com/ralph/) |
| A planner writes a structured task list up front; one task per session; progress log | [Effective harnesses for long-running agents](https://anthropic.com/engineering/effective-harnesses-for-long-running-agents) |
| Fresh worker per task and two review verdicts (spec, quality) before accepting | [Superpowers: subagent-driven-development](https://github.com/obra/superpowers/blob/main/skills/subagent-driven-development/SKILL.md) |
| Explicit dependency graph; only "ready" tasks can be claimed | [Beads](https://github.com/steveyegge/beads), [Claude Code agent teams task list](https://code.claude.com/docs/en/agent-teams) |
| One worktree per agent; merge back after validation | [Claude Code: run agents in parallel](https://code.claude.com/docs/en/agents), [The Code Agent Orchestra](https://addyosmani.com/blog/code-agent-orchestra/) |
| Orchestrator-workers split: one lead plans, workers get isolated context | [Orchestrator-workers cookbook](https://platform.claude.com/cookbook/patterns-agents-orchestrator-workers), [How we built our multi-agent research system](https://www.engineering.fyi/article/how-we-built-our-multi-agent-research-system) |
| Spec by interview; EARS criteria; file-structure plan and contracts drive the task split | [Superpowers: brainstorming](https://github.com/obra/superpowers/blob/main/skills/brainstorming/SKILL.md), [cc-sdd](https://github.com/gotalab/cc-sdd), [Kiro specs](https://kiro.dev/docs/specs/) |
| `claude -p` with `--json-schema`, `--resume`, `--permission-prompts none` | [Run Claude Code programmatically](https://code.claude.com/docs/en/headless) |

Short, grep-friendly test output and deterministic gates matter more than clever
prompts. That is the main lesson of the C-compiler write-up, and it is why
acceptance feedback is trimmed to the last 80 lines.
