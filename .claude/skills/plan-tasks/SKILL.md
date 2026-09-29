---
name: plan-tasks
description: Turn a spec into an orchestrator task graph (.orchestrator/tasks.json) together with the user, interactively. Use when the user wants to plan work for the agent orchestrator, split a feature into parallel agent tasks, or edit/extend an existing tasks.json.
---

# Plan tasks for the agent orchestrator

You help the user write `.orchestrator/tasks.json` in a target git repo. The orchestrator
(`orchestrator/Invoke-Orchestrator.ps1` in the AgentOrchestration repo) runs each task
with a separate `claude -p` worker in its own git worktree, in parallel where the graph
allows, gates each on an acceptance command and a review agent, and merges approved work
into `orch/integration`.

This is the interactive alternative to `orchestrator/Plan-Tasks.ps1`: same output, but
you discuss the split with the user before writing it.

## Steps

1. Ask for the target repo path and the spec (a file, or the user's description). If the
   spec is only in the conversation, save it as `.orchestrator/spec.md` in the target repo.
   If there is no real spec yet (only an idea), suggest writing one first with `/write-spec`.

   **Access.** The target repo is usually outside this workspace. Claude Code then asks
   before each read or write there. Check `.claude/settings.local.json` in this workspace.
   If `permissions.additionalDirectories` doesn't list the repo or a folder above it, offer
   to add one. Suggest the repo's parent folder (for example `C:\src`), which covers every
   future project there, or the repo itself. Edit the file only after the user agrees,
   and keep its other settings. Claude Code shows the edit for approval, and the running
   session picks up the change at once.
2. If the target repo doesn't exist or has no commits yet, create its skeleton first:
   run `orchestrator/Initialize-Project.ps1 -Spec <spec> -RepoPath <repo>` from the
   AgentOrchestration repo. It needs a spec that names the stack. It runs `git init`, lets
   a bootstrap agent create the manifest, test runner and one smoke test, commits them, and
   checks them in a clean checkout. It writes `setup` and `integrationCheck` to
   `.orchestrator/project.json`. Use those two commands in the plan's settings.
3. Explore the target repo (layout, language, test runner, conventions) so tasks fit it.
4. Propose the task list as a short table first: id, title, deps, owns, acceptance.
   Point out which tasks run in parallel (same wave) and any owns overlaps. Adjust with
   the user.
5. Write `.orchestrator/tasks.json` in the target repo. Format: see
   `orchestrator/schemas/tasks.schema.json`. Minimal example:

   ```json
   {
     "version": 1,
     "spec": ".orchestrator/spec.md",
     "baseBranch": "main",
     "integrationBranch": "orch/integration",
     "settings": { "model": "sonnet", "reviewModel": "sonnet", "maxAttempts": 3, "setup": "npm ci" },
     "tasks": [
       { "id": "api-types", "title": "Shared API types", "deps": [], "owns": ["src/types/**"],
         "acceptance": "npx tsc --noEmit", "prompt": "..." }
     ]
   }
   ```
6. Validate by running `orchestrator/Show-Tasks.ps1 -RepoPath <repo>` (it reports bad ids,
   unknown deps and cycles) and `orchestrator/Invoke-Orchestrator.ps1 -RepoPath <repo> -DryRun`
   (it prints the waves and same-wave owns overlaps). Fix anything reported.
7. Tell the user the command to start the run; do not start it yourself unless asked.

## Rules for a good plan

- **Size**: one task = one agent session of roughly 15-60 minutes, ending in a testable change.
- **Dependencies** only when a task needs code or interfaces another creates. Fewer deps = more parallelism. No cycles.
- **Contracts first**: when tasks must agree on an interface, add a small early task that defines it and make the others depend on it.
- **owns**: repo-relative globs (forward slashes, `**` allowed) the task may edit. Overlapping owns never run at the same time, and edits outside owns are rejected. An empty list means the whole repo (the task runs alone). Files every task may touch (lock files, registries) go in `settings.shared`.
- **acceptance**: one command run with `pwsh` from the worktree root; exit code 0 = pass. Prefer a targeted test the task writes itself. Chain steps with `&&`.
- **prompt**: self-contained. The worker sees only the spec, its prompt, and summaries from its dependencies. Say what to build, where, which interfaces to use or expose, and which tests to write.
- **ids**: short kebab-case, unique (`^[a-z0-9][a-z0-9._-]{0,48}$`); they become branch names `orch/task/<id>`.
