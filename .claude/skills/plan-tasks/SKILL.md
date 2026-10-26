---
name: plan-tasks
description: Turn a spec into an orchestrator task graph (.orchestrator/tasks.json) together with the user, interactively. Use when the user wants to plan work for the agent orchestrator, split a feature into parallel agent tasks, or edit/extend an existing tasks.json.
---

# Plan tasks for the agent orchestrator

You help the user write `.orchestrator/tasks.json` in a target git repo. The orchestrator
(`orchestrator/Invoke-Orchestrator.ps1` in the AgentOrchestration repo) runs each task
with a separate Claude or Copilot headless worker in its own git worktree, in parallel where the graph
allows, gates each on an acceptance command and a review agent, and merges approved work
into `orch/integration`.

This is the interactive alternative to `orchestrator/Plan-Tasks.ps1`: same output, but
you discuss the split with the user before writing it.

## Where things are

- **The orchestrator** is the AgentOrchestration checkout. Its path is in the `ORCH_HOME`
  environment variable. Your shell may lack it when the editor started before it was set;
  then read it with `[Environment]::GetEnvironmentVariable('ORCH_HOME', 'User')`. If neither
  has it, tell the user to run `Install-Orch.ps1` in their AgentOrchestration checkout, and
  stop. Below, `<orch>` stands for that folder. Run its scripts by full path, for example
  `& '<orch>\orchestrator\Show-Tasks.ps1' -RepoPath <repo>`. Don't rely on the `orch`
  command: your shell may not load the profile that defines it.
- **The target repo** is the repo this chat is open in, unless that is the orchestrator
  checkout itself or the user names another repo. Then ask for its path.

Before planning, read `<orch>\orchestrator\prompts\planning-rules.md`. It is the shared source
of truth for task size, dependencies, ownership, acceptance, prompts, ids and integration.
The headless planner receives the same rules.

## Steps

1. Settle the target repo (see above) and ask for the spec (a file, or the user's
   description). If the spec is only in the conversation, save it as `.orchestrator/spec.md`
   in the target repo; if that file belongs to an earlier run, use a new name such as
   `.orchestrator/spec-<topic>.md` instead. If there is no real spec yet (only an idea),
   suggest writing one first
   with `/write-spec` (or `/write-spec-analyze` for analysis).

   **Access.** If the target repo lies outside the folder this chat is open in, ask for
   approval to access it using the active assistant's directory permissions. In Claude Code,
   use `.claude/settings.local.json` and `permissions.additionalDirectories`; in Copilot CLI,
   use `--add-dir <repo>` or the session's directory permission flow. Never change access
   settings without the user's approval. Reading `<orch>` from another repo needs no approval
   in Claude Code once `Install-Orch.ps1` has run; in Copilot, approve it when asked.
   Ask which headless provider (Claude or Copilot) to use for the scripted stages.
2. Determine the selected run type before initializing or changing a plan. Analysis is
   selected by `mode: analysis` from the request/caller or the spec's Summary; otherwise
   new runs default to coding. A request to resume or edit a plan without a new mode
   inherits the plan's mode. An existing `.orchestrator/tasks.json` has the authoritative
   run type in `settings.workerType` (missing means coding). If the requested type conflicts
   with that plan, do not rewrite its mode or retag tasks. Tell the user and ask whether to
   keep the existing run in its original mode or finish/archive it before making a new plan.
   Under a no-involvement directive, stop and explain the conflict instead.
   If the target repo doesn't exist or has no commits yet, initialize through the shared
   script, after the required approval:
   `& '<orch>\orchestrator\Initialize-Project.ps1' -Provider <Claude|Copilot> -Spec <spec> -RepoPath <repo> -WorkerType <Coding|Analysis>`.
   Use the selected type. Coding initialization builds the software skeleton from the
   spec's stack, checks it and records its commands. Analysis initialization makes a
   minimal neutral Git baseline without choosing a stack or invoking software bootstrap;
   new `project.json` setup and integrationCheck default to null. Do not implement Git
   setup separately. Keep any pre-existing README, tracked files, staged unrelated files
   and existing project configuration intact. Use applicable project commands in the plan.
3. If `.orchestrator` in the target repo holds an earlier run (`state.json` exists) and
   the user wants a plan for a new feature, finish that run before you write the new plan.
   A new `tasks.json` must never sit next to an old `state.json`: a task that reuses an old
   id would count as done and be skipped. Run
   `& '<orch>\orchestrator\Complete-Orchestrator.ps1' -RepoPath <repo>`,
   with `-Keep <file>` for the new spec if it lies in `.orchestrator`. It moves the run
   record to `<repo>.runs/<timestamp>/.orchestrator`, removes the worktrees and `orch/*`
   branches, and leaves `project.json`. Use the `setup` and `integrationCheck` from
   `project.json` in the new plan's settings.
   - If it refuses because the run is not finished (a task is not done,
     `orch/integration` is not merged into the base branch, or a worktree has uncommitted
     changes), tell the user what it reported and ask what to do. Don't add `-Force` unless
     the user says so: it removes branches whose work is not merged and deletes the
     uncommitted changes.
   - If the user wants to edit or extend the plan of the current run, skip this step and
     change `tasks.json` in place. State is keyed by task id, so done tasks stay done.
   - If `tasks.json` exists without `state.json`, it is a plan that never ran. Ask before
     you replace it.
4. Explore the target repo (layout, deliverables, relevant sources, and software conventions
   or tests if applicable) so tasks fit it. Inspect outside sources only with the required
   access approval; task
   `owns` only names paths it may change in the target repo. All deliverables belong there.
5. Propose the task list as a short table first: id, title, deps, owns, acceptance.
   Point out which tasks run in parallel (same wave) and any owns overlaps. Adjust with
   the user. Follow the shared planning rules and the spec's deliverables: do not impose a
   fixed graph shape or add contract/synthesis tasks unless the work needs them. For
   analysis, use checks suited to each deliverable and runnable from the repo; include
   software tests where tools or prototypes are built. Substantial implementation may
   need one or more tasks with `workerType: "coding"` even when the run default is
   analysis. Make consumers depend on tasks whose committed files they need.
6. Write `.orchestrator/tasks.json` in the target repo. Format: see
   `<orch>\orchestrator\schemas\tasks.schema.json`. Set `provider` to the headless provider
   the user chose; the `orch` command and the dashboard read it. Also set `provider` in
   `.orchestrator/project.json`, keeping its other keys, so the next plan in this repo uses
   the same one. **Mode:** for a new analysis plan, set `settings.workerType` to
   `"analysis"`; for a new coding plan, leave it out. When editing an existing plan,
   preserve its effective mode. For
   analysis, choose dependencies, task roles, owned repo paths and acceptance from the spec,
   not from a prescribed artifact format. Ask before adding
   `settings.additionalDirectories` for approved sources outside the repo. Change nothing
   else in `project.json`: preserve its existing `setup`, `integrationCheck` and unrelated
   keys. Existing explicit project commands take precedence over suggested defaults.
   When this plan needs other commands, for
   example an integration check that also runs tests this run adds, put them only in the
   plan's `settings`. A check in `project.json` that names files the base branch lacks would
   fail every later plan in the repo if this run is dropped. Minimal example:

   ```json
   {
     "version": 1,
     "spec": ".orchestrator/spec.md",
     "baseBranch": "main",
     "integrationBranch": "orch/integration",
     "provider": "Claude",
     "settings": { "model": "sonnet", "reviewModel": "sonnet", "maxAttempts": 3, "setup": "npm ci" },
     "tasks": [
       { "id": "api-types", "title": "Shared API types", "deps": [], "owns": ["src/types/**"],
         "acceptance": "npx tsc --noEmit", "prompt": "..." }
     ]
   }
   ```
7. Validate by running `& '<orch>\orchestrator\Show-Tasks.ps1' -RepoPath <repo>` (it reports
   bad ids, unknown deps and cycles) and
   `& '<orch>\orchestrator\Invoke-Orchestrator.ps1' -Provider <Claude|Copilot> -RepoPath <repo> -DryRun`
   (it prints the waves and same-wave owns overlaps). Fix anything reported.
8. Tell the user the command to start the run:
   `& '<orch>\orchestrator\Invoke-Orchestrator.ps1' -Provider <Claude|Copilot> -RepoPath <repo>`,
   or `orch run` in a terminal inside the repo. Do not start it yourself unless asked.
Apply the shared planning rules while discussing the split, not just when validating the final plan.
