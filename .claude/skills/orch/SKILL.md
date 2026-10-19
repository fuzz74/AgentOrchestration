---
name: orch
description: Take a feature or project from idea to merged result with the agent orchestrator, in one chat in the target repo. It writes the spec with the user, plans the tasks, runs them in their own window, reports failures, and finishes the run, each step after the user's OK. Use when the user invokes /orch, or wants the orchestrator to take an idea, a spec or an existing plan through to the result.
---

# /orch: from idea to result with the agent orchestrator

You take the user through the whole orchestrator flow in this chat: spec, plan, run, finish.
The `write-spec` and `plan-tasks` skills do the first two stages. You start the run, wait for
it, report what happens, and finish it. The user says yes to every step that changes their
repo.

## Where things are

- **The orchestrator** is the AgentOrchestration checkout. Its path is in the `ORCH_HOME`
  environment variable. Your shell may lack it when the editor started before it was set;
  then read it with `[Environment]::GetEnvironmentVariable('ORCH_HOME', 'User')`. If neither
  has it, tell the user to run `Install-Orch.ps1` in their AgentOrchestration checkout, and
  stop. Below, `<orch>` stands for that folder. Run its scripts by full path. Your shell may
  not load the profile that defines the `orch` command, so load it yourself where a step uses
  it: `Import-Module '<orch>\orchestrator\Orch.psm1'; Set-Location '<repo>'; orch <command>`.
- **The target repo** (`<repo>`) is the repo this chat is open in, unless that is the
  orchestrator checkout itself or the user names another repo. Then ask for its path.
- **The other skills.** In Claude Code, start a skill with the Skill tool. In other
  assistants, read `<orch>\.claude\skills\<name>\SKILL.md` and follow it.

## Rules

- **This repo is the project.** Starting `/orch` in an existing repo means the work builds on
  that repo: follow its stack, conventions and its own `CLAUDE.md` or `AGENTS.md`. Never read
  other projects (see `write-spec`'s blank-canvas rule).
- **Git.** Never commit, merge, switch branches or push in the target repo yourself. Only the
  orchestrator's own steps change it, each after the user's yes: planning a new project makes
  its first commit, the run works on `orch/*` branches in separate worktrees, and
  `orch finish` merges. Never push; the user does that.
- **Checkpoints.** Ask, and wait for a yes, before planning a new project, before starting a
  run, before changing `tasks.json` or rerunning failed tasks, and before `orch finish`.
- **Extra flags.** When the user asks for flags on the run, such as `-AgentPath` or
  `-MaxParallel`, add them to every run command, reruns included.
- **No involvement.** When the request says the user wants no involvement (the prime directive
  of `/auto-develop`), skip the questions and take the recommended option each time. For the
  provider, take the one in `.orchestrator\project.json`, else the user's default
  (`ORCH_PROVIDER`, from the environment or the registry), else Claude. Start the run
  yourself, and fix failed tasks and rerun them yourself, at most twice. Stop before
  `orch finish`: report the result and give the user the `orch try` and `orch finish`
  commands. Access to a repo outside this chat's folder still needs the user's approval.

## Steps

1. **Start.** Settle the target repo. If `.orchestrator\tasks.json` exists, an earlier plan is
   still there. See where it stands with
   `& '<orch>\orchestrator\Wait-Orchestrator.ps1' -RepoPath '<repo>' -Once`:
   - **5:** a run is active. Go to step 5. Anything new waits until it has ended.
   - **0:** every task is done, but the run isn't finished. Go to step 7, then on with the
     user's idea or spec, if they gave one.
   - **2:** the last run ended with failed or blocked tasks. Tell the user, and go to step 6,
     unless they want to drop that run: then `plan-tasks` handles it when it plans.
   - **4:** a plan that hasn't run, or a run that was stopped. Without a new idea or spec, ask
     whether to run it (step 4). With one, go on: `plan-tasks` asks before it replaces the plan.

   Then, with a spec from the user (a file, or its text), go to step 3. With an idea, go to
   step 2.
2. **Spec.** Start `write-spec` with the user's idea. When it reaches its hand-off, don't stop:
   go on to step 3 with the spec it wrote.
3. **Plan.** Start `plan-tasks` with the spec. It asks for the provider, agrees the task table
   with the user, then writes and validates `tasks.json`. For a new project, it first makes the
   repo and its skeleton commit: say so, and wait for a yes before it does. When it gives the
   command to start the run, don't stop: go on to step 4.
4. **Run.**
   - Say how many tasks there are, in which waves, and which provider runs them.
   - Warn the user: "While the run is going, don't commit on `<base branch>` in this repo, and
     keep its working tree clean. `orch finish` stops when the base branch got commits the
     run never saw." Then ask whether to start the run.
   - On a yes, run `Import-Module '<orch>\orchestrator\Orch.psm1'; Set-Location '<repo>'; orch run -Window`,
     plus the extra flags. It opens the run in its own PowerShell window, which stays open at
     the end. Tell the user that closing this chat doesn't stop the run, and that
     `orch watch` in a terminal in the repo shows a live dashboard.
5. **Wait.** Run `& '<orch>\orchestrator\Wait-Orchestrator.ps1' -RepoPath '<repo>'`, with
   `-StartSeconds 60` the first time after starting a run. Run it so you hear when it ends
   without blocking the chat: in Claude Code, run it in the background, and you are woken when
   it exits. If your shell can't do that, run it in the foreground with `-TimeoutMinutes 9`.
   Meanwhile, answer the user if they write. Then act on its exit code:
   - **3** (a task failed, and the run goes on): tell the user which task failed and why (see
     step 6), and that the tasks which don't depend on it go on. Offer a fix once the run has
     ended. Wait again.
   - **5** (still going, nothing new): wait again.
   - **0** (every task done): go to step 7.
   - **2** (the run ended with failed or blocked tasks): go to step 6.
   - **4** (the run ended with tasks not done): if it never started, the run window shows why;
     ask the user to read it out. If it was stopped (`orch stop`), say so, and offer to start
     it again with the same command, without `-RetryFailed`.
   - **1** or anything else: show its output and ask the user.
6. **Failures.** For each failed task, find out why. Look at the error that the wait printed,
   and the newest folder in `<repo>\.orchestrator\logs\<task>\`:
   - `attempt-<n>-acceptance.log`: the acceptance command's output.
   - `attempt-<n>-review-<try>.json`: the reviewer's verdict and issues.
   - `attempt-<n>-worker.json`: what the worker did and reported.
   - For a failed integration check: `<repo>\.orchestrator\logs\<task>-integration-check.log`.

   Explain it in a few lines: which gate failed, the likely cause, and your proposed fix. A
   fix might be a clearer prompt, a wrong acceptance command, a missing dependency, owns that
   are too narrow, or a gap in the spec. Blocked tasks need no fix: they run once the tasks
   they depend on are done. With the user's yes, edit `tasks.json`, run
   `& '<orch>\orchestrator\Show-Tasks.ps1' -RepoPath '<repo>'` to validate it, and start the
   rerun with `orch run -Window -RetryFailed`, plus the extra flags. Then go back to step 5.
   If the retry refuses, for example because a worktree has uncommitted changes, report what
   it said. Add `-FreshFailed` only when the user asks for it.
7. **Finish.**
   - Tell the user that every task is done and the result is on the integration branch. Offer
     `orch try`, which opens it in a new VS Code window, and ask them to close that window
     before finishing.
   - Then say what finishing does: merge the integration branch into the base branch, archive
     the run to `<repo>.runs\<timestamp>`, and remove its worktrees and `orch/*` branches. It
     doesn't push. Ask whether to go ahead.
   - On a yes, run `Import-Module '<orch>\orchestrator\Orch.psm1'; Set-Location '<repo>'; orch finish -Yes`.
     It still checks everything first, and refuses with a reason when something is wrong:
     report that reason and what to do. Add `-Force` only when the user asks for it.
   - Afterwards, tell the user to push the base branch themselves if the repo has a remote, and
     that the spec is kept in the archive, at `<repo>.runs\<timestamp>\.orchestrator`.
