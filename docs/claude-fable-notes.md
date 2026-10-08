# Claude Fable notes

Found while building Beatfall (October 2026, Claude Code 2.1.289, model alias `fable` =
`claude-fable-5-1`) with Fable as planner, worker and reviewer.

## The planner can loop on its own reasoning

With the default effort (`high`), the headless planner read the skeleton in 15 seconds and
then reasoned for about 62K tokens without calling a tool. That exhausts Fable's 64K output
budget, so Claude Code printed `Output token limit hit. Resume directly ...` and the model
started over. Three such cycles passed before the fourth produced the plan: 58 minutes and
14 USD for a 300-line spec. The plan itself was good.

The cause is one long reasoning pass with no tool call to break it up. Workers and
reviewers did not show it: 12 tasks, 0 limit hits, because they interleave reads, writes
and test runs.

**What to do:** bound the planner with `Plan-Tasks.ps1 -Effort medium` (added after this
run). `-WorkerEffort` writes `settings.effort` for the workers and reviewers; leave it
unset to keep the CLI default. Watch for the loop with

```powershell
Get-ChildItem <repo>\.orchestrator\logs -Recurse -Filter *.events.jsonl |
    Select-String -Pattern 'Output token limit hit' | Measure-Object
```

## Cost and speed

- Beatfall: 12 tasks, 110 C# files, 8.3K lines, 447 tests. Planning 16 USD (bootstrap 2.30,
  planner 14.12), build 56 USD, every task merged on its first attempt. Wall clock: 1 hour
  for the build with `-MaxParallel 4`, after the hour lost to the planner loop.
- A trivial `claude -p --model fable` call from this repo costs about 0.80 USD because the
  system prompt (CLAUDE.md, skills, tool list) is 41K cache-creation tokens. In a target
  repo without CLAUDE.md the per-call floor is lower.
- The `fable` alias works everywhere the orchestrator passes `--model`.

## The account session limit burns every attempt in seconds

Found while building The Last Ninja: The Movie (October 2026). When the account's session
limit is reached, every `claude -p` call returns at once with
`You've hit your session limit · resets 4:50pm`. The orchestrator treats that as a worker
error, starts the next attempt immediately, and so marks a task failed after three attempts
in about ten seconds. Six tasks failed that way within two minutes, and the run ended with
their dependents blocked.

**What to do after the reset:**

1. Check each failed worktree: `git -C <repo>.worktrees\<task> status --porcelain`.
   A worker that was cut off mid-task leaves its files uncommitted, and `-RetryFailed`
   refuses such a worktree. Commit the work on the task branch
   (`git add -A -- <owned paths>` and `git commit -m "WIP"`): the retry then runs in sync
   mode, which re-runs the checks and sends their failures back to the same worker session.
2. Rerun `Invoke-Orchestrator.ps1 ... -RetryFailed`. The attempt counter is per pipeline
   run, so the three spent attempts do not count against the retry and `state.json` needs
   no edit.

A task that had finished its worker and failed only in the review (its branch is one commit
ahead of `orch/integration`) needs nothing: the retry re-runs acceptance and review.

## Launching the orchestrator from inside a Claude Code session

A `claude -p` started from a Claude Code session inherits `CLAUDECODE=1` and the other
`CLAUDE_CODE_*` variables. Clear them before the orchestrator starts, otherwise the nested
CLI may refuse to run or attach to the parent session:

```bash
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \
    -u CLAUDE_PID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
    -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_EFFORT \
    pwsh -NoProfile -File ./orchestrator/Invoke-Orchestrator.ps1 -Provider Claude -RepoPath <repo> -MaxParallel 4
```

Planning this project with `-Effort medium` took 11 minutes and 3.64 USD for a 900-line
spec with 22 tasks, with no output-limit loop.
