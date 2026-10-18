# Progress: the orchestrator from any repo

This file tracks building what [orchestrator-from-any-repo.md](orchestrator-from-any-repo.md)
describes, one step at a time. A step starts only when every check of the step before it has
passed. The file lives in the repo, so it works from any PC and with Claude or Copilot.

## Status

| Step | What you get | Status |
|---|---|---|
| [0](#step-0-starting-point-and-practice-repo) | A known-good starting point and a practice repo | Not started |
| [1a](#step-1a-orch-status) | `orch status` from anywhere inside a repo | Not started |
| [1b](#step-1b-watch-views-without-a-provider-flag) | `orch watch`, `timeline`, `talk` and `stop` with no `-Provider` | Not started |
| [1c](#step-1c-orch-plan-and-orch-run) | `orch plan` and `orch run` | Not started |
| [1d](#step-1d-orch-try-and-orch-finish) | `orch try` and `orch finish` | Not started |
| [2](#step-2-skills-from-any-repo) | `/write-spec` and `/plan-tasks` from any repo | Later |
| [3](#step-3-the-orch-guiding-skill) | The `/orch` guiding skill | Later |
| [4](#step-4-per-repo-conventions) | Per-repo conventions in `project.json` | Later |

The statuses are *Not started*, *Building*, *Ready to check*, *Done*, and *Later* (no checks
written yet).

## How a step goes

1. **Agree on the checks.** Before building a step, we read its checks together and adjust them.
2. **Build.** Claude or Copilot builds the step, runs the smoke test, updates the README, sets
   the step to *Ready to check*, and commits and pushes.
3. **Check.** You run the checks in a PowerShell 7 terminal. Every check says what you should
   see. Tell the assistant what you saw, and it ticks the boxes.
4. **Done or fix.** When every check has passed, the step is set to *Done* and its *Done* line
   is filled in. If something looks wrong, it goes under the step's *Notes* and gets fixed
   before the next step starts.

For assistants: tick a check or set a step to *Done* only after the user says it passed. Never
tick one because your own run of it passed.

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
- **Provider:** taken from `-Provider`, then the repo's `project.json`, then your own default.
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
- [ ] The smoke test passes for both providers:
  ```powershell
  .\tests\Run-SmokeTest.ps1 -Provider Claude
  .\tests\Run-SmokeTest.ps1 -Provider Copilot
  ```
  You should see green `PASS` lines, and each run ends with `Smoke test passed.`
- [ ] A practice repo with a finished run:
  ```powershell
  .\tests\New-PracticeRepo.ps1
  .\orchestrator\Show-Tasks.ps1 -RepoPath $env:TEMP\orch-practice\demo
  ```
  You should see a table of the four tasks, each with status `done`. Step 1a compares
  `orch status` with this table.
- [ ] A practice repo with a plan that hasn't run:
  ```powershell
  .\tests\New-PracticeRepo.ps1 -Stage Planned
  .\orchestrator\Show-Tasks.ps1 -RepoPath $env:TEMP\orch-practice\demo
  ```
  You should see the four tasks, each with status `pending`.
- [ ] An empty practice repo:
  ```powershell
  .\tests\New-PracticeRepo.ps1 -Stage Empty
  git -C $env:TEMP\orch-practice\demo log --oneline
  ```
  You should see one commit and no `.orchestrator\tasks.json`.

**Done:** (date, PC)

**Notes:**

---

## Step 1a: orch status

**Why:** it's the smallest useful piece. It only reads, so it can't harm a run. It also proves
the two things every later command needs: `orch` is installed, and it finds the right repo.

**Decide first**
- Your PowerShell profile is in OneDrive (`Dokumenter\PowerShell`). If OneDrive syncs it to
  your other PCs, a line in it with this PC's checkout path breaks on any PC where the checkout
  is somewhere else. Proposal: the profile line loads `orch` from `$env:ORCH_HOME`, a user
  environment variable that the install script sets on each PC. That also settles the
  `ORCH_HOME` half of step 2.

**What changes**
- A new `orch` module in `orchestrator\`, with one command: `orch status`.
- A new install script, run once per PC.

**Checks**
- [ ] Install, then open a **new** terminal:
  ```powershell
  .\Install-Orch.ps1
  ```
  You should see a message saying which folder `orch` was installed from.
- [ ] Running the install a second time changes nothing. It says `orch` is already installed.
- [ ] `orch` with nothing after it lists its commands. Only `status` exists so far.
- [ ] It works from the repo, from a folder inside it, and from the integration worktree:
  ```powershell
  .\tests\New-PracticeRepo.ps1
  cd $env:TEMP\orch-practice\demo; orch status
  cd $env:TEMP\orch-practice\demo\.orchestrator; orch status
  cd $env:TEMP\orch-practice\demo.worktrees\_integration; orch status
  ```
  You should see the same table as in step 0, three times. Each starts with a line that names
  `...\orch-practice\demo` as the repo.
- [ ] Outside any repo:
  ```powershell
  cd $env:TEMP; orch status
  ```
  You should see a one-line message that this folder isn't in a git repo, and no red stack
  trace.
- [ ] The smoke test still passes (`-Provider Claude` is enough).
- [ ] *The next time you're on another PC:* pull, run the install, open a new terminal, make a
  practice repo, and run `orch status` there.

**Done:** (date, PC)

**Notes:**

---

## Step 1b: Watch views without a provider flag

**Why:** these are the commands you keep open during a run. After this step, none of them
needs a path or `-Provider`.

**Decide first**
- Where your own default provider lives: an `ORCH_PROVIDER` user environment variable (simple,
  set per PC) or a small settings file.
- Whether `orch` saves the provider to `project.json` the first time you pass `-Provider` in
  a repo.

**What changes**
- `orch watch`, `orch timeline`, `orch talk` and `orch stop`.
- The provider lookup, shown in each command's first line.

**Checks** (in a practice repo with a finished run)
- [ ] Each view draws once and returns, without asking for a provider:
  ```powershell
  orch watch -Once
  orch timeline -Once
  orch talk -Once
  ```
- [ ] Stop, then cancel:
  ```powershell
  orch stop
  orch stop -Cancel
  ```
  You should see `Stop requested for ...`, then `Stop request cleared for ...`.
- [ ] The provider order. The first line of `orch watch -Once` says which provider it used and
  why:
  - With only your default set: your default, "(your default)".
  - With `"provider": "Copilot"` added to the practice repo's `project.json`: Copilot,
    "(project.json)".
  - With `-Provider Claude` added to the command: Claude, "(flag)".
  - With none of them set: a message that tells you how to set one, and nothing runs.
- [ ] The smoke test still passes.

**Done:** (date, PC)

**Notes:**

---

## Step 1c: orch plan and orch run

**Why:** so you can start a run from the repo you're in, with your usual settings.

**What changes**
- `orch plan <spec>` and `orch run`.
- `-MaxParallel` can also come from `project.json`.
- The smoke test gets a part that drives a run through `orch`, so this stays tested.

**Checks.** First, in the same terminal, point the orchestrator at the fake agent so nothing
spends tokens. If your default provider is Copilot, set `ORCH_COPILOT` instead.
```powershell
$env:ORCH_CLAUDE = "$env:ORCH_HOME\tests\fake-claude.ps1"
```
- [ ] Plan in a repo that has no plan yet:
  ```powershell
  .\tests\New-PracticeRepo.ps1 -Stage Empty
  cd $env:TEMP\orch-practice\demo
  orch plan $env:TEMP\orch-practice\spec.md
  orch status
  ```
  You should see the planner finish, then the four tasks, each `pending`.
- [ ] A dry run starts nothing. `orch run -DryRun` lists the tasks as `Wave 1`, `Wave 2` and
  `Wave 3`, and `orch status` still shows every task `pending`.
- [ ] A real run. `orch run` runs all four tasks, and `orch status` then shows each one `done`.
- [ ] Settings from `project.json`. With `"maxParallel": 1` added there, the first line of
  `orch run` shows max parallel 1.
- [ ] The smoke test still passes.

**Done:** (date, PC)

**Notes:**

---

## Step 1d: orch try and orch finish

**Why:** so you can look at the result without hunting for the worktree folder, and merge and
archive the run in one go.

**Decide first**
- The open choice from the design notes: do runs stay hands-off `main`, or does `orch finish`
  first merge `main` into `orch/integration` and rerun the integration check? If we choose the
  second, this step gets a check for it.
- `orch finish` merges into the run's base branch, which `tasks.json` records. That isn't
  always `main`.

**What changes**
- `orch try` opens `<repo>.worktrees\_integration` in a new VS Code window.
- `orch finish` shows what it's about to do and asks first. If you say yes, it merges
  `orch/integration` into the base branch and archives the run. It never pushes.

**Checks** (in a new practice repo with a finished run, from `$env:TEMP\orch-practice\demo`)
- [ ] `orch try` opens a new VS Code window on `...\orch-practice\demo.worktrees\_integration`.
  Close that window before the next check.
- [ ] Saying no changes nothing. Run `orch finish` and answer `n`. `orch status` and
  `git log --oneline -1` look the same as before.
- [ ] It refuses while the main checkout has uncommitted changes:
  ```powershell
  Add-Content skeleton.txt 'local edit'
  orch finish
  git checkout -- skeleton.txt
  ```
  You should see a clear refusal that names the changed file, and nothing merged.
- [ ] Saying yes merges and archives. Run `orch finish` and answer `y`. Then:
  ```powershell
  git log --oneline -3                              # a merge of orch/integration on top
  git branch --list 'orch/*'                        # nothing
  Get-ChildItem $env:TEMP\orch-practice\demo.runs   # one timestamp folder
  ```
- [ ] The smoke test still passes.

**Done:** (date, PC)

**Notes:**

---

## Later steps

These get detailed checks when we reach them, in the same way as step 1.

### Step 2: Skills from any repo

- It starts with a quick test on this PC, to choose between a Claude Code plugin and
  `ORCH_HOME` skill folders. The test answers whether a plugin installed from a local path
  picks up a `git pull`, and where Copilot chat and Copilot CLI look for personal skills.
- The check, in outline: in a VS Code window opened on a practice repo, `/write-spec` and
  `/plan-tasks` are offered, and they find the orchestrator's scripts without asking for folder
  access.

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
