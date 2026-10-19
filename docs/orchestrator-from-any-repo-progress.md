# Progress: the orchestrator from any repo

This file tracks building what [orchestrator-from-any-repo.md](orchestrator-from-any-repo.md)
describes, one step at a time. A step starts only when every check of the step before it has
passed. The file lives in the repo, so it works from any PC and with Claude or Copilot.

## Status

| Step | What you get | Status |
|---|---|---|
| [0](#step-0-starting-point-and-practice-repo) | A known-good starting point and a practice repo | Done |
| [1a](#step-1a-orch-status) | `orch status` from anywhere inside a repo | Done (other PC still to check) |
| [1b](#step-1b-watch-views-without-a-provider-flag) | `orch watch`, `timeline`, `talk` and `stop` with no `-Provider` | Done |
| [1c](#step-1c-orch-plan-and-orch-run) | `orch plan` and `orch run` | Done |
| [1d](#step-1d-orch-try-and-orch-finish) | `orch try` and `orch finish` | Done |
| [2](#step-2-skills-from-any-repo) | `/write-spec` and `/plan-tasks` from any repo | Done (other PC still to check) |
| [3](#step-3-the-orch-guiding-skill) | The `/orch` guiding skill | Later |
| [4](#step-4-per-repo-conventions) | Per-repo conventions in `project.json` | Later |

The statuses are *Not started*, *Building*, *Ready to check*, *Done*, and *Later* (no checks
written yet).

## How a step goes

1. **Say up front.** Before building a step, the assistant says what it will build and which
   checks it will run, and waits for the user's go-ahead. The user can adjust the checks, or
   take over any part and do it by hand.
2. **Build.** The assistant builds the step, runs the smoke test, updates the README, and
   commits and pushes.
3. **Check.** The assistant runs the checks and shows each one's real output next to what the
   check says you should see. Checks marked **(you)** happen on the user's screen or machine,
   where the assistant can't see, such as a VS Code window opening or a new terminal. The
   assistant gives exact instructions for those, and the user reports what happened.
4. **Done or fix.** When every check has passed, the step is set to *Done* and its *Done* line
   is filled in. If something looks wrong, it goes under the step's *Notes* and gets fixed
   before the next step starts.

A ticked check ends with who ran it: *(you)* or *(assistant)*. The assistant ticks its own
checks only when the output matches, and the user's only after the user says they passed.

Commands that start with `.\` run in your AgentOrchestration folder.

## The practice repo

Every check runs in a throwaway repo, never in a real project. Step 0 adds
`tests\New-PracticeRepo.ps1`, which builds one with the fake agent the smoke test uses, so it
spends no tokens. It always uses `$env:TEMP\orch-practice` and replaces whatever was there.

| Command | What you get in `$env:TEMP\orch-practice\demo` |
|---|---|
| `.\tests\New-PracticeRepo.ps1` | A finished run: four tasks done, the result on `orch/integration`, not merged yet |
| `.\tests\New-PracticeRepo.ps1 -Stage Planned` | A plan with four tasks, none started |
| `.\tests\New-PracticeRepo.ps1 -Stage Empty` | A repo with one commit and no plan. A spec is ready in `$env:TEMP\orch-practice\spec.md` |

The four tasks are `contracts`, then `feature-a` and `feature-b` side by side, then `wire-up`.

Each call takes a few seconds and ends with a green `Practice repo ready: ...` line. With the
default stage, you also see the run's progress lines. Everything else goes to
`$env:TEMP\orch-practice\setup.log`.

Close any VS Code window or terminal that is open in the practice folder before you make a new
one, because Windows can't delete a folder that is in use.

## The orch commands

Step 1 builds these, a few at a time:

| You type | It runs |
|---|---|
| `orch status` | `Show-Tasks.ps1` |
| `orch watch` | `Watch-Orchestrator.ps1` |
| `orch timeline` | `Watch-AgentTimeline.ps1` |
| `orch talk` | `Watch-Conversations.ps1` |
| `orch stop` | `Request-OrchestratorStop.ps1` |
| `orch plan <spec>` | `Plan-Tasks.ps1` |
| `orch run` | `Invoke-Orchestrator.ps1` |
| `orch try` | Opens the `_integration` worktree in a new VS Code window |
| `orch finish` | Merges `orch/integration` and runs `Complete-Orchestrator.ps1`, after you confirm |

- **Repo:** the one you're in, from any folder inside it, including its worktrees.
- **Provider:** taken from `-Provider`, then the plan, then the repo's `project.json`, then
  your own default (see steps 1b and 1c).
- **Other flags** go to the script unchanged.
- **First line:** every `orch` command starts with one line that names the repo and the
  provider, and where the provider came from. That way you can see what it picked.

The design notes also list `orch spec`. The spec interview is a chat skill, not a script, so
it waits for step 2.

---

## Step 0: Starting point and practice repo

**Why:** to prove that everything works before we change anything, so a later failure points
at our change. It also gives every later check a safe repo to run in.

**What changes**
- The design notes link to this file.
- New `tests\New-PracticeRepo.ps1` (see [The practice repo](#the-practice-repo)).

**Checks**
- [x] The smoke test passes for both providers: *(you)*
  ```powershell
  .\tests\Run-SmokeTest.ps1 -Provider Claude
  .\tests\Run-SmokeTest.ps1 -Provider Copilot
  ```
  You should see green `PASS` lines, and each run ends with `Smoke test passed.` It takes about
  a minute per provider. Lines such as `[spec-only] FAILED: Gave up after 5 attempts` are
  expected, because the test makes them on purpose. Only a red `FAIL` at the end of a check line
  is a problem.
- [x] A practice repo with a finished run: *(you)*
  ```powershell
  .\tests\New-PracticeRepo.ps1
  .\orchestrator\Show-Tasks.ps1 -RepoPath $env:TEMP\orch-practice\demo
  ```
  You should see a table of the four tasks, each with status `done`. Step 1a compares
  `orch status` with this table.
- [x] A practice repo with a plan that hasn't run: *(you)*
  ```powershell
  .\tests\New-PracticeRepo.ps1 -Stage Planned
  .\orchestrator\Show-Tasks.ps1 -RepoPath $env:TEMP\orch-practice\demo
  ```
  You should see the four tasks, each with status `pending`.
- [x] An empty practice repo: *(you)*
  ```powershell
  .\tests\New-PracticeRepo.ps1 -Stage Empty
  git -C $env:TEMP\orch-practice\demo log --oneline
  ```
  You should see one commit and no `.orchestrator\tasks.json`.

**Done:** 2026-10-18, MSI

**Notes:**
- 2026-10-18: the first smoke test failed for both providers, on `legacy coding and unknown role
  rejected`. PowerShell 7.6.7, installed by an automatic update on 2026-10-14, returns `$false`
  from `Test-Json` without an error when the problem is inside a task or the settings.
  `Read-Plan` only looked for the error, so plans with a wrong `workerType`, an unknown task
  field or a bad settings value passed validation. Fixed in `Orchestrator.psm1`: a `$false`
  result now counts as a schema error too. The Copilot structured-result check now gives a
  reason in that case. After the fix, both smoke tests passed when the assistant ran them.

---

## Step 1a: orch status

**Why:** it's the smallest useful piece. It only reads, so it can't harm a run. It also proves
the two things every later command needs: `orch` is installed, and it finds the right repo.

**Decided** (2026-10-18)
- Your PowerShell profile is in OneDrive (`Dokumenter\PowerShell`). If OneDrive syncs it to
  your other PCs, a line in it with this PC's checkout path breaks on any PC where the checkout
  is somewhere else. So the profile line holds no path: it loads `orch` from `ORCH_HOME`, a
  user environment variable that the install script sets on each PC. That also settles the
  `ORCH_HOME` half of step 2.
- The line goes in the all-hosts profile (`profile.ps1`), so it also works in the VS Code
  PowerShell extension's terminal, which reads a different profile file.
- When a terminal's environment lacks `ORCH_HOME`, the line reads it from the registry. A
  VS Code window started before the install keeps its old environment, and its new terminals
  would otherwise not find `orch` until VS Code restarts.

**What changes**
- `orchestrator\Orch.psm1` with one command, `orch status`.
- `Install-Orch.ps1` at the repo root. Run it once per PC. `-WhatIf` shows what it would do.
- The README gets setup item 6 and rows in the command reference.
- The smoke test gets a check: `orch status` from the integration worktree, with a relative
  `-Plan`.

**Checks**
- [x] Install: *(assistant)*
  ```powershell
  .\Install-Orch.ps1
  ```
  You should see a message saying which folder `orch` was installed from.
- [x] **(you)** Open a **new** terminal in VS Code, then run
  `cd $env:TEMP\orch-practice\demo; orch status`. You should see the table from step 0. This
  shows that your own terminals load `orch`. *(you, in Windows Terminal)*
- [x] **(you)** The same in a **new VS Code terminal**: `orch` alone lists its commands. VS Code
  is where the design notes expect you to work, and its terminal may be set to Windows
  PowerShell 5.1, which reads another profile file and would not load `orch`. *(you)*
- [x] Running the install a second time changes nothing. It says `orch` is already installed.
  *(assistant)*
- [x] `orch` with nothing after it lists its commands. Only `status` exists so far.
  *(assistant)*
- [x] It works from the repo, from a folder inside it, and from the integration worktree:
  *(assistant)*
  ```powershell
  .\tests\New-PracticeRepo.ps1
  cd $env:TEMP\orch-practice\demo; orch status
  cd $env:TEMP\orch-practice\demo\.orchestrator; orch status
  cd $env:TEMP\orch-practice\demo.worktrees\_integration; orch status
  ```
  You should see the same table as in step 0, three times. Each starts with a line that names
  `...\orch-practice\demo` as the repo.
- [x] Outside any repo: *(assistant)*
  ```powershell
  cd $env:TEMP; orch status
  ```
  You should see a one-line message that this folder isn't in a git repo, and no red stack
  trace.
- [x] The smoke test still passes. *(assistant, both providers)*
- [ ] **(you)** *The next time you're on another PC:* pull, run the install, open a new
  terminal, make a practice repo, and run `orch status` there. This check stays open and
  doesn't block the next steps.

**Done:** 2026-10-18, MSI (the other-PC check is still open)

**Notes:**
- 2026-10-18: a single flag after the command, as in `orch status -Once`, reached the script as
  separate characters. A lone leftover argument is a string, and splatting a string passes its
  characters. Fixed by always making the leftover arguments a list.
- 2026-10-18: an extra test found an older bug. A relative `-Plan` path was resolved against
  the folder the PowerShell process started in, not the folder you had moved to with `cd`. This
  affected the long commands too. Fixed in `Get-OrchPaths`, and the new smoke test check
  covers it.
- The assistant ran its checks in a new PowerShell process that loads your profile, and whose
  environment had no `ORCH_HOME`, like a VS Code terminal started before the install.

---

## Step 1b: Watch views without a provider flag

**Why:** these are the commands you keep open during a run. After this step, none of them
needs a path or `-Provider`.

**Decided** (2026-10-18)
- Of these four commands, only `watch` needs a provider. `timeline`, `talk` and `stop` never
  took one.
- The provider comes from `-Provider`, then from the plan, then from your default for this PC.
  A plan made for Copilot holds Copilot model names, so the plan is the most reliable source.
  `Plan-Tasks.ps1` now records it in `tasks.json` as `provider`, a small engine change. Older
  plans lack it and fall through to your default.
- Your default is the user environment variable `ORCH_PROVIDER`, which
  `Install-Orch.ps1 -Provider` sets. On this PC (MSI) it is `Claude`.
- The idea of saving the provider to `project.json` moves to step 1c. It only matters for
  `orch plan`, where no plan exists yet.

**What changes**
- `orch watch`, `orch timeline`, `orch talk` and `orch stop`.
- `Plan-Tasks.ps1` records `provider` in `tasks.json`, and the schema allows it.
- `Install-Orch.ps1 -Provider Claude|Copilot` sets `ORCH_PROVIDER`.
- The first line of each command names the repo, plus the provider and where it came from
  when the command needs one.
- The README gets a table of the `orch` commands and the `provider` plan field. The smoke test
  checks that the plan records its provider and that `orch watch` uses it.

**Checks** (in a practice repo with a finished run)
- [x] Each view draws once and returns, without asking for a provider: *(assistant)*
  ```powershell
  orch watch -Once
  orch timeline -Once
  orch talk -Once
  ```
- [x] Stop, then cancel: *(assistant)*
  ```powershell
  orch stop
  orch stop -Cancel
  ```
  You should see `Stop requested for ...`, then `Stop request cleared for ...`.
- [x] Set the default: `.\Install-Orch.ps1 -Provider Claude` says `Default provider set to
  Claude.` Running it again says nothing changed. *(assistant)*
- [x] The provider order. The first line of `orch watch -Once` says which provider it used and
  why: *(assistant)*
  - In a Copilot practice repo (`.\tests\New-PracticeRepo.ps1 -Provider Copilot`):
    `provider Copilot (from the plan)`. The dashboard lists live Copilot processes.
  - The same, with `-Provider Claude` added: `provider Claude (from -Provider)`.
  - In a plan without `provider`, as made before this step: `provider Claude (from your
    default)`.
  - With none of them: `orch: no provider. Add -Provider Claude or -Provider Copilot, or set
    your default with Install-Orch.ps1 -Provider.` Nothing runs.
- [x] The smoke test still passes. *(assistant, both providers)*
- [x] **(you)** The live dashboard works through `orch`. In a VS Code terminal: *(you, in
  Windows Terminal)*
  ```powershell
  cd $env:TEMP\orch-practice\demo
  orch watch
  ```
  You should see the dashboard of a finished run, which stays on screen. Its heading
  `Live Copilot CLI processes` (or `Claude`) shows the provider. The dashboard covers the
  whole terminal, so `orch`'s grey line is hidden while it runs. Press `q` to quit. The normal
  screen comes back, with the grey line `orch: repo ..., provider ...` above your prompt.

**Done:** 2026-10-18, MSI

**Notes:**
- 2026-10-18: the assistant tested the case with no provider anywhere before setting your
  default, so it didn't have to remove the default afterwards.

---

## Step 1c: orch plan and orch run

**Why:** so you can start a run from the repo you're in, with your usual settings.

**Decided** (2026-10-18)
- `orch run` takes the provider from the plan, like `orch watch`.
- `orch plan` usually has no plan to read, because finishing a run archives it. So
  `Plan-Tasks.ps1` also saves the provider in the repo's `.orchestrator\project.json`, which
  outlives the run and is never committed. The order is: `-Provider`, the plan, `project.json`,
  your default. A repo you build with Copilot keeps using Copilot.
- `-MaxParallel` from `project.json` is skipped for now. Nothing writes it, and
  `orch run -MaxParallel 5` works, since flags pass through.

**What changes**
- `orch plan <spec>` and `orch run`. Outside a repo, `orch plan` suggests `-RepoPath <folder>`
  for a new project.
- `Plan-Tasks.ps1` saves the provider in `project.json`, and its closing hint also mentions
  `orch run`.
- `New-PracticeRepo.ps1` retries deleting the old practice folder for a few seconds, since a
  run that has just finished can hold a file for a moment.
- The README and the smoke test, which now plans and runs through `orch`.

**Checks** (with the fake agent, through `-AgentPath`, so no tokens)
- [x] Plan in a repo that has no plan yet: *(assistant)*
  ```powershell
  .\tests\New-PracticeRepo.ps1 -Stage Empty
  cd $env:TEMP\orch-practice\demo
  orch plan $env:TEMP\orch-practice\spec.md
  orch status
  ```
  You should see `provider Claude (from your default)`, the planner's waves, `or, with the orch
  command ... orch run`, then the four tasks, each `pending`. `project.json` now holds
  `"provider": "Claude"`.
- [x] A dry run starts nothing. `orch run -DryRun` says `provider Claude (from the plan)` and
  lists `Wave 1`, `Wave 2` and `Wave 3`. `orch status` still shows every task `pending`.
  *(assistant)*
- [x] A real run. `orch run` runs all four tasks and exits with code 0, and `orch status` then
  shows each one `done`. *(assistant)*
- [x] The repo remembers its provider. In a Copilot practice repo whose run was archived,
  `orch plan` says `provider Copilot (from project.json)`. *(assistant)*
- [x] A new project. Outside any repo, `orch plan <spec>` says to add `-RepoPath <folder>`.
  With `-RepoPath` set to a new folder, it creates the project skeleton and plans there.
  *(assistant)*
- [x] The smoke test still passes. *(assistant, both providers)*

**Done:** 2026-10-18, MSI

**Notes:**
- 2026-10-18: the first smoke test run of the new `orch` flow failed with "no changes". By
  then, `main` already held the files the fake agent writes. The test now sets `FAKE_SHARED`,
  as the earlier rerun check does, so every task changes a shared file.
- 2026-10-18: re-creating the practice repo right after a run once failed with "in use", and
  worked a moment later. The script now retries for up to five seconds.

---

## Step 1d: orch try and orch finish

**Why:** so you can look at the result without hunting for the worktree folder, and merge and
archive the run in one go.

**Decided** (2026-10-18)
- Runs stay hands-off `main`. If the base branch got commits during the run, `orch finish`
  stops before merging, because the integration check never saw them. `orch finish -Force`
  merges anyway; a merge that fails is undone, and nothing changes.
- `orch finish` merges into the run's base branch, which `tasks.json` records. That isn't
  always `main`.

**What changes**
- `orch try` opens `<repo>.worktrees\_integration` in a new VS Code window.
- `orch finish` checks first, and stops with a clear message when: a run is active, a task
  isn't done, a worktree has uncommitted changes, the main checkout is on another branch or
  has uncommitted changes, your terminal is inside a worktree, or the base branch moved
  (without `-Force`). Then it shows what it will do and asks y/N; `-Yes` skips the question.
  On yes, it merges `orch/integration` into the base branch and archives the run with the
  orchestrator's own `Complete-Run`. It never pushes.
- `Get-RunProblems` in `Orchestrator.psm1` now names the first changed file correctly. It used
  to lose its first letter.
- The README (steps 6 and 7, the `orch` table, the command reference) and the smoke test,
  which checks that `orch finish` stops when `main` moved and that `-Force` merges and
  archives.

**Checks** (in a practice repo with a finished run, from `$env:TEMP\orch-practice\demo`)
- [x] **(you)** `orch try` opens a new VS Code window on
  `...\orch-practice\demo.worktrees\_integration`. Close that window before the next check.
  *(you)*
- [x] **(you)** Saying no changes nothing. *(you)* Run `orch finish` and answer `n`. It says `Nothing
  changed.`, and `orch status` and `git log --oneline -1` look the same as before.
- [x] It refuses, with a message that names the problem, and changes nothing when: *(assistant)*
  - a task isn't done: `The run isn't finished: 4 of 4 tasks are not done (contracts, ...)`
  - the main checkout has an uncommitted change: `... uncommitted changes (skeleton.txt) ...`
  - the integration worktree has one: `... the worktree ...\_integration has uncommitted
    changes that would be deleted (skeleton.txt)`
  - the main checkout is on another branch: `... is on other, but the run was based on main
    ...`
  - the terminal is inside the integration worktree: `Your terminal is in ... Run cd ...
    first.`
  - an unknown flag: `orch finish takes only -Yes and -Force, not -Now.`
  - `main` got a commit during the run: `main got 1 new commit(s) during the run ...`
- [x] `-Force` merges although `main` moved. The summary says so in yellow, then it merges and
  archives. *(assistant)*
- [x] The y/N question, answered by a pipe: `n` changes nothing, `y` merges and archives.
  *(assistant)*
- [x] **(you)** Saying yes merges and archives. Run `orch finish` and answer `y`. Then: *(you)*
  ```powershell
  git log --oneline -3                              # a merge of orch/integration on top
  git branch --list 'orch/*'                        # nothing
  Get-ChildItem $env:TEMP\orch-practice\demo.runs   # one timestamp folder
  ```
- [x] The smoke test still passes. *(assistant, both providers)*

**Done:** 2026-10-18, MSI. Your checks ran in Windows Terminal.

**Notes:**
- 2026-10-18: the assistant's first check run showed two message bugs, both fixed. "Tasks not
  done" printed a list type name instead of the reason. "Uncommitted changes" lost the first
  letter of the first file name, because git's output is trimmed, and the orchestrator's own
  worktree check had the same bug.

---

## Step 2: Skills from any repo

**Why:** so `/write-spec`, `/plan-tasks` and `/auto-develop` work in the chat of any repo, with
that repo as the target, and a `git pull` keeps them current.

**Investigation** (2026-10-18; Claude Code 2.1.302, Copilot CLI 1.0.97, from the docs and this
PC)
- **Where personal skills are read:**
  - Claude Code (CLI and VS Code extension): `~\.claude\skills\<name>`. The docs allow a
    symbolic link there; Windows junctions aren't mentioned.
  - Copilot CLI: `~\.copilot\skills` and `~\.agents\skills`. It has not read `~\.claude` since
    version 1.0.36. A `skillDirectories` setting and `copilot skill add <folder>` register a
    folder in place. Skills behind symbolic links load since version 1.0.62.
  - VS Code Copilot chat: the docs list `~\.copilot\skills`, `~\.claude\skills` and
    `~\.agents\skills`. Whether its default "Copilot" harness reads `~\.claude\skills` is
    unclear. The setting for extra folders (`chat.agentSkillsLocations`) is deprecated and
    ignored by that harness.
- **Plugins:**
  - Claude Code: plugin skills always get a prefix, so `/write-spec` becomes
    `/orch:write-spec`. The docs say a plugin from a local marketplace loads in place, but
    on this PC a plugin from a local marketplace was copied into `plugins\cache`.
  - Copilot plugins: in VS Code they are off by default (`chat.plugins.enabled`), and the
    setting for a local plugin folder is experimental.
- **Finding the scripts:** the shell that Claude Code runs commands in doesn't load the
  PowerShell profile. So in a chat, `orch` isn't available, and `ORCH_HOME` may exist only in
  the registry. A skill can name its own folder with `${CLAUDE_SKILL_DIR}`, but through a link
  that path points into `~\.claude\skills`, not into the checkout.
- **Workers:** Claude planners, workers and reviewers get a fixed tool list without the
  skill tool, so they can't start a skill. The Claude bootstrap and resolver have no list and
  could. Every Copilot session gets a tool list built from `allowedTools`, which never names
  the skill tool.

**Link test** (2026-10-18, MSI). A throwaway skill in the scratchpad was linked with Windows
junctions (no admin rights or Developer Mode needed) into `~\.claude\skills` and
`~\.copilot\skills`, then called from the practice repo:
- [x] Claude Code CLI (`claude -p` on Haiku): `LINK-TEST-OK C:/Users/kbjer/.claude/skills/orch-link-test`.
  `${CLAUDE_SKILL_DIR}` is the link's path, not the real folder. *(assistant)*
- [x] Claude Code in VS Code: the same reply. A running session picked up the new skill
  without a restart. *(you)*
- [x] Copilot CLI, both `copilot -p` and an interactive session: `LINK-TEST-OK
  C:\Users\kbjer\.copilot\skills\orch-link-test`. *(assistant, you)*
- [ ] **(you)** VS Code Copilot chat: not set up on this PC. Try it on a PC where it is.

The test links, the skill and the `~\.copilot\skills` folder it needed were removed again.

**Decided** (2026-10-18)
- Link the skills with junctions into the personal skill folders, and make no plugin. A plugin
  would rename the skills (`/orch:write-spec`), Copilot plugins are off by default in VS Code,
  and the scripts would have to move into a plugin folder.
- The skills find the orchestrator through `ORCH_HOME`, with the registry as a fallback, and
  run its scripts by full path.
- `Install-Orch.ps1` allows this checkout and `~\.claude\skills` once in
  `~\.claude\settings.json`, so Claude reads the orchestrator's files from another repo without
  asking.

**What changes**
- `Install-Orch.ps1` links the three skills into `~\.claude\skills` and `~\.copilot\skills`,
  and allows the two folders for Claude after a backup of `settings.json`.
- `write-spec` and `plan-tasks` get a "Where things are" section. The repo the chat is open
  in is the default target, and scripts run by full path. `plan-tasks` writes `provider` into
  `tasks.json` and `project.json`, and the hand-offs mention `orch plan` and `orch run`.
- No headless agent can start these skills. Claude sessions deny `Skill(write-spec)`,
  `Skill(plan-tasks)` and `Skill(auto-develop)`. A Copilot session without a tool list loses
  the skill tool (`--excluded-tools=skill`).
- The README (the "Agent chat" row, setup item 6, the command reference, a safety note) and
  the smoke test, which checks that every headless call blocks the skills.

**Checks**
- [x] The install. A dry run lists six links and the settings change, the install makes them,
  and a second run changes nothing. *(assistant)*
- [x] `settings.json` equals its backup apart from the two new entries. *(assistant)*
- [x] A real folder with a skill's name is left alone, with a warning. *(assistant)*
- [x] The Claude block. Asked to load `plan-tasks`, Haiku replies `BLOCKED` with the block and
  loads the skill without it. *(assistant)*
- [x] The Copilot block. `--deny-tool=skill(plan-tasks)` is silently ignored, so it isn't
  used; `--excluded-tools=skill` blocks. *(assistant)*
- [x] The real skill from the practice repo, with no `ORCH_HOME` in the environment.
  `/plan-tasks`, asked only for its setup, reports `orch: C:\Data\AI\AgentOrchestration` and
  `target: ...\orch-practice\demo`, in Claude (Haiku) and in Copilot. *(assistant)*
- [x] The smoke test, both providers, with the new check `headless agents cannot start
  skills`. That check does note a call without the block. *(assistant)*
- [x] **(you)** The real flow in VS Code. In the Claude Code panel of the practice repo,
  `/plan-tasks` plans the practice spec with you, writes `tasks.json` with `provider`, and
  validates it with the orchestrator's scripts. Afterwards `orch status` shows the plan.
  *(you; the assistant also checked the files, `orch status` and `orch run -DryRun`)*
  - It asked for the provider and the split in one question, then wrote four tasks:
    `contracts`, then `component-a` and `component-b` side by side, then `wire`.
  - `tasks.json` and `project.json` both hold `"provider": "Claude"`, and `project.json` kept
    `setup` and `integrationCheck`.
  - `Show-Tasks.ps1` and the dry run found nothing to fix. It gave the start command and
    didn't start the run.
  - Reading the orchestrator's files asked for no permission. Only running its two scripts
    did.
  - `orch run -DryRun` said `provider Claude (from the plan)`.
- [ ] **(you)** VS Code Copilot chat, on a PC where it is set up: `/plan-tasks` is offered in
  another repo. This check stays open and doesn't block the next steps.
- [ ] **(you)** *The next time you're on another PC:* pull, and run `.\Install-Orch.ps1` again
  to make the links and the settings entry there. This check stays open and doesn't block
  the next steps.

**Done:** 2026-10-19, MSI (the two other-PC checks are still open)

**Notes:**
- 2026-10-19: for the user's check of the real `/plan-tasks` flow, the practice repo was made
  with `.\tests\New-PracticeRepo.ps1 -Stage Empty`, and `$env:TEMP\orch-practice\spec.md` was
  copied to `.orchestrator\spec.md` in it.

---

## Later steps

These get detailed checks when we reach them, in the same way as steps 1 and 2.

### Step 3: The /orch guiding skill

- It includes the rule changes from the design notes: new blank-canvas wording in `CLAUDE.md`
  and the write-spec skill, and never committing or pushing in the target repo without asking.
- The check, in outline: in a practice repo, `/orch <idea>` goes from spec to plan, waits for
  your OK, runs in the background, and tells you when the run finishes or a task fails.

### Step 4: Per-repo conventions

- The check, in outline: with `specArchive` set in a practice repo's `project.json`,
  `orch finish` saves the spec under the next numbered name.

---

## Decisions

| Date | Decision |
|---|---|
| 2026-10-18 | Build in the order the design notes suggest, with step 1 split into 1a to 1d. Every check runs in a practice repo made with the fake agent, never in a real project. |
| 2026-10-18 | The assistant runs the checks, after saying up front what it will do. The user does the checks marked **(you)** and can take over any part. |
| 2026-10-18 | `orch` loads through `ORCH_HOME`, set per PC, from a profile line with no path in the all-hosts profile (see step 1a). |
| 2026-10-18 | The provider comes from `-Provider`, then the plan (`Plan-Tasks.ps1` records it), then `ORCH_PROVIDER` for the PC (see step 1b). |
| 2026-10-18 | `Plan-Tasks.ps1` also saves the provider in `project.json`, checked after the plan and before `ORCH_PROVIDER`. `-MaxParallel` from `project.json` is skipped for now (see step 1c). |
| 2026-10-18 | Runs stay hands-off `main`: `orch finish` stops when the base branch moved, and `-Force` merges anyway (see step 1d). |
| 2026-10-18 | The skills reach other repos through junctions in the personal skill folders, not a plugin. Claude is allowed this checkout once in its user settings (see step 2). |
