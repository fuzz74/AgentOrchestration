# Agent Orchestrator: Design & Usage

A small PowerShell harness that runs a dependency graph of coding tasks with parallel
`claude -p` agents. Each agent works in its own git worktree, and only work that passes
tests and a review agent is merged. No framework: PowerShell 7, git and the Claude Code CLI.

```
spec.md ──► Plan-Tasks.ps1 ──► .orchestrator/tasks.json ──► (you review) ──► Invoke-Orchestrator.ps1 ──► orch/integration ──► (you merge)
            planner agent       task graph                                    parallel workers + gates
```

- [At a glance](#at-a-glance)
- [Quick start](#quick-start)
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

## Quick start

**Prerequisites**

- PowerShell 7.2 or later (`pwsh`), git 2.20 or later.
- Claude Code, logged in. The scripts look for `claude` in this order: `-ClaudePath`, the
  `ORCH_CLAUDE` environment variable, `claude` on `PATH`, then the binary bundled with the
  VS Code extension (`~/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/`).
- A target git repo with a clean working tree, and a test command agents can run.

**Run it**

1. Write a spec: a Markdown file that describes what to build. The `/write-spec` skill in
   this repo writes one with you by interview, shaped for the planner (see [Writing a spec](#writing-a-spec)).
2. Plan:
   ```powershell
   .\orchestrator\Plan-Tasks.ps1 -Spec .\spec.md -RepoPath C:\src\myapp -Setup 'npm ci'
   ```
   The script writes `C:\src\myapp\.orchestrator\tasks.json` and prints the waves.
   You can also plan interactively with the `/plan-tasks` skill in this repo.
3. Review and edit `tasks.json`. Check it with `-DryRun`:
   ```powershell
   .\orchestrator\Invoke-Orchestrator.ps1 -RepoPath C:\src\myapp -DryRun
   ```
4. Run:
   ```powershell
   .\orchestrator\Invoke-Orchestrator.ps1 -RepoPath C:\src\myapp -MaxParallel 3
   ```
   Progress prints live and is appended to `.orchestrator/progress.md`. In another
   terminal, `.\orchestrator\Show-Tasks.ps1 -RepoPath C:\src\myapp` shows the status table.
5. When all tasks are done, review `orch/integration` and merge it:
   ```powershell
   git -C C:\src\myapp merge --no-ff orch/integration
   ```
6. Clean up worktrees and branches:
   ```powershell
   .\orchestrator\Clear-Orchestrator.ps1 -RepoPath C:\src\myapp -All
   ```

**Try it without spending tokens**: `.\tests\Run-SmokeTest.ps1` builds a throwaway repo and
runs the whole flow with `tests/fake-claude.ps1`. The flow covers a 4-task diamond, a
forced edit outside `owns` with a retry, a run that returns no structured result, a merge
conflict and a resolver run. It then checks 9 assertions.

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
| `integrationCheck` | none | Command run in the integration worktree after each merge. A failure undoes the merge and fails the task. |
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

`Plan-Tasks.ps1` runs one planner agent (`--model opus` by default) in the target repo.
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
set, it runs after each merge. A failing check resets the integration branch to its
previous commit and fails the task.

**Statuses**: `pending` → `running` → `done` or `failed`. A pending task with a failed task
upstream is shown as `blocked`.

## Files and state on disk

| Path | What it holds |
| --- | --- |
| `<repo>/.orchestrator/tasks.json` | The plan. Yours to edit. |
| `<repo>/.orchestrator/spec.md` | Copy of the spec when it lives outside the repo. |
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
| `Plan-Tasks.ps1` | `-Spec` (required), `-RepoPath` (`.`), `-Out` (plan path), `-Model` (planner, `opus`), `-WorkerModel` (`sonnet`), `-Setup`, `-IntegrationCheck`, `-ClaudePath`, `-MaxBudgetUsd` (`5`), `-Force` (overwrite) |
| `Invoke-Orchestrator.ps1` | `-RepoPath` (`.`), `-Plan`, `-MaxParallel` (`3`), `-ClaudePath`, `-DryRun` (print waves and exit), `-RetryFailed`, `-PollSeconds` (`5`). Exit code 0 = all done, 2 = some failed or blocked, 1 = invalid plan. |
| `Show-Tasks.ps1` | `-RepoPath`, `-Plan`. Validates the plan and prints wave, status, deps, attempts, cost and detail per task. |
| `Clear-Orchestrator.ps1` | `-RepoPath`, `-All`. Without `-All`: removes task worktrees and `orch/task/*` branches, resets unfinished tasks to pending. With `-All`: also the integration worktree and branch, state, logs and progress. Supports `-WhatIf`. |
| `tests/Run-SmokeTest.ps1` | `-WorkDir`. End-to-end test with the fake claude. |

## Agent permissions and safety

| Agent | Tools | Permission mode |
| --- | --- | --- |
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
