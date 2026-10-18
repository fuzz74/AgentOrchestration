# Using the orchestrator from inside a target repo

Design notes from a discussion in October 2026. These notes are about how to make the
orchestrator easier to use, starting from this case: an existing project repo (called Example
Project N here) is open in VS Code, and you want to build a new feature in it with the
orchestrator. Progress on building it is tracked in
[orchestrator-from-any-repo-progress.md](orchestrator-from-any-repo-progress.md).

## What gets in the way now

1. **Switching to another workspace.** `/write-spec` and `/plan-tasks` live in this repo's
   `.claude/skills`, so the chat has to start in `AgentOrchestration`. You then pass the
   target repo as a path and approve directory access.
2. **Typing long commands.** Every script needs `.\orchestrator\X.ps1 -Provider … -RepoPath …`,
   run from this repo's folder.
3. **Juggling three or four terminals** for the run, the dashboard, the conversation watcher
   and the status table.
4. **Opening another window to try the result**, because `orch/integration` is checked out in
   `<repo>.worktrees\_integration`.
5. **Doing the repo's own chores by hand.** A repo may keep its specs in a folder such as
   `docs/specs/` with numbered versions, and continue requirement ids from the last spec. The
   orchestrator doesn't know that.

## What it could look like

You stay in the target repo's VS Code window and type in its chat:

```
/orch <one-line feature idea>
```

The chat runs the spec interview in that repo, so it already sees the repo's `AGENTS.md` or
`CLAUDE.md` and its code. Then it plans, shows the task table and waits for your OK. It starts
the run in a background terminal, keeps an eye on it, and tells you when tasks fail or the
run finishes. At the end it offers to open the result, merge it, archive the run and save the
spec where the repo keeps its specs.

In the terminal you'd type `orch run`, `orch watch` or `orch status`, with no paths and no
`-Provider`.

## What's needed, cheapest first

**1. A short `orch` command with defaults.**
- A small module or shim on `PSModulePath` or `PATH` that runs the existing scripts:
  `orch spec | plan | run | watch | talk | timeline | status | stop | try | finish`.
- `-RepoPath` defaults to the git root of the current folder.
- `-Provider` and `-MaxParallel` come from `.orchestrator/project.json` (per repo), then a
  per-user config, then the flag.
- `orch try` opens the `_integration` worktree in a new VS Code window (`code -n …`).
- `orch finish` runs the merge and `Complete-Orchestrator.ps1` together, after a confirmation.
- It needs no change to the engine and helps both Claude and Copilot.

**2. Skills you can use from any repo.** The skills live in this repo. There are two ways to
make them visible elsewhere:
- **A Claude Code plugin.** This repo becomes a marketplace plus plugin, installed once per
  PC. The skills find the scripts and prompts relative to the plugin, so there's no
  directory-permission prompt for the orchestrator's own files.
  - Open question: a plugin from a local path may be copied into a cache. Then a `git pull`
    wouldn't update it, which matters because this repo is developed on several PCs. Test that
    first.
- **User-level skill folders** (`~/.claude/skills`, and the Copilot equivalent) that point at
  the checkout through an `ORCH_HOME` variable. Simpler, and always matches the checkout, but
  the setup is per machine. Check where VS Code's Copilot chat and Copilot CLI look for
  personal skills.

Either way, each skill finds the orchestrator through one variable instead of assuming the chat
started in this repo.

**3. A guiding skill (`/orch`).** It runs write-spec, then plan-tasks, then the run, then the
finish in one chat. The steps already hand off to each other, so most of the work is in the
last two:
- Start `orch run` in the background and wait on `state.json` or the exit code, instead of you
  watching terminals.
- Summarise failures from `Show-Tasks.ps1` and the review logs, and offer to edit `tasks.json`
  and rerun with `-RetryFailed`.
- `/auto-develop` becomes the same flow with no checkpoints.

**4. Per-repo conventions.** An optional block in `project.json`, roughly
`specArchive: "docs/specs/<name>-v{n}.md"` and `nextRequirementId: <n>`, used by write-spec
and by the finish step. Alternatively, write-spec could read the repo's `AGENTS.md` and ask.
The config is more reliable.

**5. VS Code integration, later if at all.** `orch` could write a `.vscode/tasks.json` snippet
with Run, Watch and Status tasks, kept out of git through `.git/info/exclude`, because other
repos are committed to only when asked. A real extension could add a task tree from
`state.json` and a status bar item. That's a lot of work for what the chat skill and
`orch watch` already cover.

## Rule changes this needs

- **Blank canvas.** Starting `/orch` inside a repo should count as saying "this builds on this
  project". It should still never read other projects. Change the wording in `CLAUDE.md` and
  in the write-spec skill.
- **Hands off the main checkout while a run is active.** With the repo open in VS Code, it's
  easy to keep editing `main`. Commits on `main` during a run mean merging by hand at the end.
  Either the skill warns about this, or `orch finish` merges `main` into `orch/integration`
  first and reruns the integration check.
- **Git rules.** Inside the target repo, its own `CLAUDE.md` applies, so the guiding skill must
  never commit or push there without asking. The final merge is a confirmation step, not
  automatic.

## Suggested order

1. The `orch` command (biggest gain, no risk).
2. Make the skills usable from any repo; pick plugin or `ORCH_HOME` after a quick test.
3. The `/orch` guiding skill.
4. Per-repo conventions in `project.json`.

## Open choices

- Should runs stay hands-off on `main`, or should the orchestrator expect work to continue
  there during a run?
- Plugin or `ORCH_HOME`?
