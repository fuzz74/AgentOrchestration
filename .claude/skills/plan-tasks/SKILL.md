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

Before planning, read `orchestrator/prompts/planning-rules.md` in the AgentOrchestration
repo. It is the shared source of truth for task size, dependencies, ownership,
acceptance, prompts, ids and integration. The headless planner receives the same rules.

## Steps

1. Ask for the target repo path and the spec (a file, or the user's description). If the
   spec is only in the conversation, save it as `.orchestrator/spec.md` in the target repo.
   If there is no real spec yet (only an idea), suggest writing one first with `/write-spec`.

   **Access.** The target repo is usually outside this workspace. Ask for approval to access
   it using the active assistant's directory permissions. In Claude Code, use
   `.claude/settings.local.json` and `permissions.additionalDirectories`; in Copilot CLI,
   use `--add-dir <repo>` or the session's directory permission flow. Never change access
   settings without the user's approval.
   Ask which headless provider (Claude or Copilot) to use for the scripted stages.
2. If the target repo doesn't exist or has no commits yet, create its skeleton first:
   run `orchestrator/Initialize-Project.ps1 -Provider <Claude|Copilot> -Spec <spec> -RepoPath <repo>` from the
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
6. Validate by running `orchestrator/Show-Tasks.ps1 -Provider <Claude|Copilot> -RepoPath <repo>` (it reports bad ids,
   unknown deps and cycles) and `orchestrator/Invoke-Orchestrator.ps1 -Provider <Claude|Copilot> -RepoPath <repo> -DryRun`
   (it prints the waves and same-wave owns overlaps). Fix anything reported.
7. Tell the user the command to start the run; do not start it yourself unless asked.
Apply the shared planning rules while discussing the split, not just when validating the final plan.
