---
name: write-spec
description: Write a spec for the agent orchestrator together with the user, by interview, so it splits cleanly into parallel agent tasks. Use when the user wants to write, draft or improve a spec, PRD or design for a feature or project that the orchestrator (or /plan-tasks, Plan-Tasks.ps1) will build, or when /plan-tasks is asked to plan from an idea that has no spec yet.
---

# Write a spec for the agent orchestrator

You help the user write one Markdown spec that `/plan-tasks` or `orchestrator/Plan-Tasks.ps1`
turns into `.orchestrator/tasks.json`. The orchestrator then builds each task with a separate
Claude or Copilot headless worker in its own git worktree, in parallel where the graph allows. Each task is
checked by an acceptance command and a review agent.

Who reads the spec decides what goes in it:

- The **planner** splits it into tasks. It needs deliverables and repo-relative ownership
  paths (they become `owns`), dependencies (they become `deps`), and runnable checks suited
  to each deliverable (they become `acceptance`). Specify shared interfaces when tasks
  actually need them; software tests belong in software tasks.
- **Every worker and every reviewer** gets the whole spec pasted into its prompt, next to
  its one task. So the spec must be concise, and each part must be findable by requirement id
  and module name. Nobody can ask the author anything during the run.

The method draws on Superpowers' brainstorming skill and cc-sdd's requirements and design
rules. The originals are in [references/](references/README.md).

## Where things are

- **The orchestrator** is the AgentOrchestration checkout. Its path is in the `ORCH_HOME`
  environment variable. Your shell may lack it when the editor started before it was set;
  then read it with `[Environment]::GetEnvironmentVariable('ORCH_HOME', 'User')`. If neither
  has it, tell the user to run `Install-Orch.ps1` in their AgentOrchestration checkout. Below,
  `<orch>` stands for that folder.
- **The target repo** is the repo this chat is open in, unless that is the orchestrator
  checkout itself or the user names another repo. Then ask for its path.

<HARD-GATE>
While writing a spec, do not write product code, scaffold, install dependencies, or write
tasks.json. Read-only exploration of the target repo is allowed. The only file you write is
the spec.
</HARD-GATE>

<HARD-GATE>
Every project is a blank canvas. The one exception is a spec that builds on an existing
project: then that project, and no other project, may be read and its stack and conventions followed.
A spec builds on one when the user explicitly says so, or when this chat is open in an
existing repo (one with commits) and that repo is the target: starting `/orch`, `/write-spec`
or `/plan-tasks` there counts as saying so. Otherwise, while writing a spec, read only the
target repo, this skill's own files, and sources the user explicitly authorizes for this
spec (in a message, or in a brief or draft they hand you), subject to directory permissions.
Do not open, search or copy from
any other project: no other repos, specs, briefs, code or run folders, and not as a style
example either. Do not carry over a stack, layout, rule or convention because an earlier
project used it, even when a memory note records it as the user's usual choice. Ask the user
instead, without presenting the earlier choice as the default. If you think another project
would help, say which one and why, and wait for a yes.
</HARD-GATE>

## Analysis mode

When the request says `mode: analysis` (or explicitly asks for an analysis run), identify
analysis mode in the spec's Summary and hand it through to planning, which sets
`settings.workerType` to `"analysis"`. Development remains coding by default. Apply the
same interview, template, review and hand-off steps below. Establish the question, scope,
success criteria, relevant sources and access limits, and the requested outputs; ask only
about gaps not resolved by the request or approved sources. Preserve a representation the
user specified. Otherwise choose a suitable representation, record that choice and its
reason in the spec, and present it in the normal section review; do not ask a separate
format-choice question (in autonomous runs, choose without asking). Identify repo-relative
destinations and acceptance for all deliverables. Distinguish source paths approved for
inspection from owned paths the tasks may change, and keep every deliverable in the target
Git repo. Do not demand software design, contracts, setup or tests just because the
template includes them; include them when a tool, prototype or other software deliverable
needs them. Specify supported conclusions, uncertainty and how to report inaccessible
sources without inventing findings. Use only dependencies and tasks that the actual work
needs; coding tasks may support an analysis run.

## Steps

1. **Target.** Settle the target repo (see above) and ask for the topic, unless already
   given. If the user has a draft spec, start from it: review it against the rules below and
   interview only for the gaps.

  **Access.** If the target repo lies outside the folder this chat is open in, ask for
  approval to access it using the active assistant's directory permissions. In Claude Code, use
  `.claude/settings.local.json` and `permissions.additionalDirectories`; in Copilot CLI,
  use `--add-dir <repo>` or the session's directory permission flow. Never change access
  settings without the user's approval. Settle access first even when the user asks for no
  involvement: in auto mode the assistant cannot grant it to itself, and every step after the
  spec writes to the repo. Until access is granted, draft the spec in the scratchpad.
2. **Explore** the target repo (read-only): its layout, relevant sources and deliverables,
   and software language, test runner and conventions where applicable. Inspect only
   sources explicitly approved under the access rules above. Don't ask what the repo or
   approved sources can tell you. Check each claim a brief or draft makes about the code
   against the repo before the interview:
   briefs are written before the code they describe, and they drift. If
   the folder doesn't exist or has no commits, it's a **new project**. Planning then uses
   `orchestrator/Initialize-Project.ps1`: coding gets a software skeleton, so settle its
   stack, setup and test commands; analysis gets a minimal neutral Git baseline without
   inventing a stack or setup commands. If the analysis needs a software tool, specify its
   applicable design, setup and checks for the tasks that build it. Don't create the folder
   or any files other than the spec yourself.
3. **Check scope.** If the request covers several independent subsystems, stop and propose a
   split into separate specs with an order. Then continue with the first one. Signs that a
   spec is too big: more than about 8 modules, or more than about 400 lines.
4. **Interview.** Ask one question per message only for unresolved gaps. Prefer multiple
   choice (AskUserQuestion) with your recommended option first. Cover purpose, users (or
   the decision the analysis informs), success criteria, scope limits and constraints;
   in analysis mode also cover sources, access limits and requested outputs as above.
   Then write back your understanding in a few lines, separating what the user said from
   what you assume, and let them correct it.
5. **Approaches.** Propose 2-3 approaches with trade-offs. Lead with your recommendation and
   say why. Apply YAGNI: cut anything the goal doesn't need.
6. **Design, section by section.** Present each part in chat and get a yes before moving
   on. Scale each part to its complexity.
   - Requirements (EARS, below), including the requested result
   - Modules or deliverables and ownership boundaries
   - Shared contracts, only where multiple tasks need them
   - Build order and dependencies, only where needed
   - Verification appropriate to each deliverable
   - Constraints
7. **Write** the spec from [spec-template.md](spec-template.md). Save it to
   `<repo>/.orchestrator/spec.md` unless the user names another path. `.orchestrator/` is
   git-excluded, so the repo stays clean for the run. If `.orchestrator/` still holds an
   earlier run (`state.json` exists), its `spec.md` belongs to that run: leave it, and save
   the new spec next to it under a new name, such as `.orchestrator/spec-<topic>.md`.
   Planning archives the earlier run and leaves the new spec in place. Delete every
   template comment. Keep `[NEEDS CLARIFICATION: ...]` markers for anything unresolved
   instead of guessing.
8. **Self-review** and fix what you find:
   - every criterion has an N.M id and an EARS form
   - every id maps to a module or deliverable in 4.2
   - every module or deliverable has owned repo paths and applicable verification
   - no shared paths between tasks meant to run in parallel
   - every existing test that the change breaks (an absolute screen row, an old path format,
     a changed signature) is named under a module that may change it
   - every existing caller of a signature the change replaces, production code included, lies
     in the paths of the module that replaces it
   - every applicable shared contract in 4.3 is written out
   - analysis output representation is recorded, all deliverables stay in the repo, and
     source inspection limits are distinct from owned paths
   - software sections and tests are present if needed, not demanded when inapplicable
   - no TBD, TODO or leftover comments
   - Open questions is empty
9. **Independent review.** Dispatch a fresh subagent with
   [reviewer-prompt.md](reviewer-prompt.md). Fix the issues it finds. Stop after two
   review-and-fix passes. Take anything still open to the user as a question rather than
   guessing.
10. **User review.** Give the path and ask the user to read the spec. Revise until they
    approve.
11. **Hand off.** Offer `/plan-tasks` with the selected mode, or give the command
    `& '<orch>\orchestrator\Plan-Tasks.ps1' -Provider <Claude|Copilot> -Spec <path> -RepoPath <repo> -WorkerType <Coding|Analysis>`,
    or `orch plan <path> -WorkerType <Coding|Analysis>` in a terminal inside the repo.
    Specify `Analysis` for an analysis spec in either command; otherwise use `Coding`.
    Ask which provider to use. For a new project, that command initializes the repo first
    (software skeleton for coding, neutral baseline for analysis) and uses applicable setup
    and check commands. For an existing repo without `.orchestrator/project.json`, add
    `-Setup '<setup command>'` and/or `-IntegrationCheck '<whole-project check>'` only
    when those commands apply; do not invent them for analysis without software. If the repo holds
    an earlier run, the command archives it to `<repo>.runs` first and keeps the spec; no
    `-Force` is needed. It stops if that run is not finished: tell the user to finish it,
    and leave the choice of `-Force` (archive it unfinished) to them.
    Don't plan or run unless asked.

## Rules for a spec that splits well

- **What and why over how.** Specify behaviour, boundaries and contracts. Leave algorithms
  and internal structure to the workers, except where two modules must agree.
- **Contracts written out, not described.** If two or more modules share types,
  function signatures, routes with request/response shapes and status codes, DB schema,
  event payloads, file formats or error types, write those shared contracts out exactly
  in 4.3.
  Workers build against it without seeing each other's code. A contract described only in
  prose leads to integration failures. Do not invent a shared format for independent
  analysis deliverables that do not need one.
- **Boundaries are paths.** Each module gets repo-relative globs. Modules meant to run in
  parallel share no files. Find hidden shared files early (route registries, DI containers,
  barrel `index` files, config, lock files). Either give them to one module, or list them
  under Shared files when every task must append to them. A change that existing tests
  assert (a new screen row, a path format, a signature) breaks tests in other modules'
  folders: grep for them and give each affected test file to the module that makes the
  change, which then builds before the module that owns the folder. The same holds for
  production callers: a module that replaces a public signature must also own every file
  that calls it, or the build fails in its own worktree.
- **Every criterion testable.** Use one EARS sentence per behaviour, with a concrete subject
  (the module or component name). Replace "fast", "secure" and "user-friendly" with a
  measure, or drop them.
- **Verification is runnable.** Specify checks appropriate to each deliverable from a
  fresh worktree with PowerShell 7; include software setup, test runner, per-module checks
  and whole-project check where software is built or changed. If tests don't exist yet,
  say which module creates them. A per-module filter that matches no test passes vacuously
  on most runners, so name the test folders and namespaces exactly. For a new coding
  project, give the exact stack in Constraints: language and runtime version, framework,
  test runner and package manager. For an analysis-only baseline, do not invent software
  setup or tests. Validate the requested result and its evidence, not a fixed file format.
- **Unattended boundaries.** Workers can't ask. Split rules into three groups:
  - **Always:** do without asking.
  - **Stop and report blocked:** things that would need a human's approval.
  - **Never:** hard stops.
- **Build order, not a task list.** Say what must exist first and what can run in parallel
  if dependencies exist. A software tool's consumers need its committed files first. Do
  not force a contract-first or synthesis-last graph when the work does not need one.
  The planner does the split: don't write task prompts in the spec.
- **Concise.** Aim for 150-400 lines. Every line costs tokens in every worker's prompt. Use
  tables and code over prose. Don't repeat content across sections.
- **Fit the repo.** Use the target repo's language, layout, test runner and conventions
  where relevant. Point to an existing file in it as the example to follow when applicable.
  A file in another project is never the example.
- **Follow-up specs.** When the code already cites an earlier spec's requirement ids (in
  comments, or test names such as `Req11_2_...`), number the new areas after the highest
  old one and say so in the Summary, so workers and reviewers keep the two apart.

## EARS quick reference

Full rules: [references/cc-sdd/ears-format.md](references/cc-sdd/ears-format.md).

| Pattern | Form | Use for |
| --- | --- | --- |
| Event | When `<event>`, the `<component>` shall `<response>`. | Reactions to input or events |
| Unwanted | If `<error or condition>`, the `<component>` shall `<response>`. | Errors, invalid input, failures |
| State | While `<state>`, the `<component>` shall `<response>`. | Behaviour that depends on a mode or state |
| Optional | Where `<feature is included>`, the `<component>` shall `<response>`. | Configurable or optional features |
| Ubiquitous | The `<component>` shall `<response>`. | Always-true properties |

Combined forms are fine: "While `<state>`, when `<event>`, the `<component>` shall
`<response>`."
