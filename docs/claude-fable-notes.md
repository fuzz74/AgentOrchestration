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
