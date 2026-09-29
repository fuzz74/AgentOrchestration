---
name: write-spec
description: Write a spec for the agent orchestrator together with the user, by interview, so it splits cleanly into parallel agent tasks. Use when the user wants to write, draft or improve a spec, PRD or design for a feature or project that the orchestrator (or /plan-tasks, Plan-Tasks.ps1) will build, or when /plan-tasks is asked to plan from an idea that has no spec yet.
---

# Write a spec for the agent orchestrator

You help the user write one Markdown spec that `/plan-tasks` or `orchestrator/Plan-Tasks.ps1`
turns into `.orchestrator/tasks.json`. The orchestrator then builds each task with a separate
`claude -p` worker in its own git worktree, in parallel where the graph allows. Each task is
checked by an acceptance command and a review agent.

Who reads the spec decides what goes in it:

- The **planner** splits it into tasks. It needs module boundaries as file paths (they become
  `owns`), shared interfaces written out (they become the contracts-first task), the build
  order (it becomes `deps`) and test commands (they become `acceptance`).
- **Every worker and every reviewer** gets the whole spec pasted into its prompt, next to
  its one task. So the spec must be concise, and each part must be findable by requirement id
  and module name. Nobody can ask the author anything during the run.

The method draws on Superpowers' brainstorming skill and cc-sdd's requirements and design
rules. The originals are in [references/](references/README.md).

<HARD-GATE>
While writing a spec, do not write product code, scaffold, install dependencies, or write
tasks.json. Read-only exploration of the target repo is allowed. The only file you write is
the spec.
</HARD-GATE>

## Steps

1. **Target.** Ask for the target repo path and the topic, unless already given. If the user
   has a draft spec, start from it: review it against the rules below and interview only
   for the gaps.
2. **Explore** the target repo (read-only): language, layout, test runner, conventions, and
   what already exists. Don't ask what the code can tell you. If the folder doesn't exist
   or has no commits, it's a **new project**. Planning then creates its skeleton from the
   spec automatically (`orchestrator/Initialize-Project.ps1`): git repo, manifest, test
   runner, and one smoke test. So the interview must settle the stack and the setup and
   test commands. Don't create the folder or any files other than the spec yourself.
3. **Check scope.** If the request covers several independent subsystems, stop and propose a
   split into separate specs with an order. Then continue with the first one. Signs that a
   spec is too big: more than about 8 modules, or more than about 400 lines.
4. **Interview.** Ask one question per message. Prefer multiple choice (AskUserQuestion)
   with your recommended option first. Cover purpose, users, success criteria, scope limits
   and constraints. Then write back your understanding in a few lines, separating what the
   user said from what you assume, and let them correct it.
5. **Approaches.** Propose 2-3 approaches with trade-offs. Lead with your recommendation and
   say why. Apply YAGNI: cut anything the goal doesn't need.
6. **Design, section by section.** Present each part in chat and get a yes before moving
   on. Scale each part to its complexity.
   - Requirements (EARS, below)
   - Modules and boundaries
   - Shared contracts
   - Build order
   - Verification
   - Constraints
7. **Write** the spec from [spec-template.md](spec-template.md). Save it to
   `<repo>/.orchestrator/spec.md` unless the user names another path. `.orchestrator/` is
   git-excluded, so the repo stays clean for the run. Delete every template comment. Keep
   `[NEEDS CLARIFICATION: ...]` markers for anything unresolved instead of guessing.
8. **Self-review** and fix what you find:
   - every criterion has an N.M id and an EARS form
   - every id maps to a module in 4.2
   - no module without paths
   - no shared paths between modules meant to run in parallel
   - every contract in 4.3 is written out
   - no TBD, TODO or leftover comments
   - Open questions is empty
9. **Independent review.** Dispatch a fresh subagent with
   [reviewer-prompt.md](reviewer-prompt.md). Fix the issues it finds. Stop after two
   review-and-fix passes. Take anything still open to the user as a question rather than
   guessing.
10. **User review.** Give the path and ask the user to read the spec. Revise until they
    approve.
11. **Hand off.** Offer `/plan-tasks`, or give the command
    `.\orchestrator\Plan-Tasks.ps1 -Spec <path> -RepoPath <repo>`. For a new project, that
    command creates the skeleton first and takes the setup and check commands from it. For
    an existing repo, add `-Setup '<setup command>' -IntegrationCheck '<whole-project check>'`.
    Don't plan or run unless asked.

## Rules for a spec that splits well

- **What and why over how.** Specify behaviour, boundaries and contracts. Leave algorithms
  and internal structure to the workers, except where two modules must agree.
- **Contracts written out, not described.** Two or more modules share something: types,
  function signatures, routes with request/response shapes and status codes, DB schema,
  event payloads, file formats, error types. Write that thing out exactly as code in 4.3.
  Workers build against it without seeing each other's code. A contract described only in
  prose leads to integration failures.
- **Boundaries are paths.** Each module gets repo-relative globs. Modules meant to run in
  parallel share no files. Find hidden shared files early (route registries, DI containers,
  barrel `index` files, config, lock files). Either give them to one module, or list them
  under Shared files when every task must append to them.
- **Every criterion testable.** Use one EARS sentence per behaviour, with a concrete subject
  (the module or component name). Replace "fast", "secure" and "user-friendly" with a
  measure, or drop them.
- **Verification is runnable.** Name the setup command, the test runner, a per-module test
  command and a whole-project check. Each must work from a fresh worktree with PowerShell 7.
  If tests don't exist yet, say which module creates them. For a new project, also give
  the exact stack in Constraints: language and runtime version, framework, test runner and
  package manager. The skeleton is built from these, before any task runs.
- **Unattended boundaries.** Workers can't ask. Split rules into three groups:
  - **Always:** do without asking.
  - **Stop and report blocked:** things that would need a human's approval.
  - **Never:** hard stops.
- **Build order, not a task list.** Say what must exist first, what can go in parallel and
  what glue comes last. The planner does the split: don't write task prompts in the spec.
- **Concise.** Aim for 150-400 lines. Every line costs tokens in every worker's prompt. Use
  tables and code over prose. Don't repeat content across sections.
- **Fit the repo.** Use its language, layout, test runner and conventions. Point to an
  existing file as the example to follow.

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
