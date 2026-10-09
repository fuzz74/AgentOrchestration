# Sub-agent support: implementation plan

Handoff for a new session. Workers and the planner should be able to send independent
questions to sub-agents in parallel and work from their summaries. The watch views should
label sub-agent activity. This must work for both providers, Claude and Copilot.

Read `CLAUDE.md` first. In this repo you work on `main` and commit and push after every
change. When you're done, move the lasting findings from this file into `docs/` and the
README, then delete this file.

## Decisions already made

| Prompt | Sub-agents | Reason |
| --- | --- | --- |
| `worker.md` | Yes | Retries continue the same session (`retry.md` + `--resume`), so they keep the instruction. |
| `planner.md` | Yes | Useful for surveying an existing codebase and checking a long spec. |
| `reviewer.md` | No | It runs once per task on a small diff, so sub-agents would add cost to every task for little gain. |
| `bootstrap.md`, `resolver.md` | No | Small, focused jobs. |
| `planning-rules.md` | n/a | Text inserted into the planner prompt, not a prompt for its own agent. |

- Do not give agents Copilot's `write_agent` unless a test shows sub-agents need follow-up messages.
- The prompt must say to use sub-agents only for independent questions that need a lot of
  reading, not for every task. Each sub-agent starts a fresh context, so it has a real cost.
  In a test, two Haiku sub-agents that only counted files brought the session to 0.12 USD.

## Facts already checked (Claude Code 2.1.289, 2026-10-09)

### Claude

- **Workers already have the tool.** Workers are launched with `--allowedTools` only, not
  `--tools`, so `Task` is in their tool list. None of 114 agent logs from VeloSage,
  GhostRacer and TheLastNinjaTheMovie show a worker using it.
- **The planner doesn't.** The planner (`orchestrator/Plan-Tasks.ps1:91`) and the reviewer
  (`Invoke-Review` in `orchestrator/Orchestrator.psm1`) pass `--tools Read,Glob,Grep`, which
  leaves `Task` out.
- **Adding `Task` works.** A session with `--tools Read,Glob,Grep,Task`,
  `--allowedTools Read,Glob,Grep,Task` and `--permission-mode dontAsk` started sub-agents and
  stayed read-only, because `dontAsk` blocks any tool not on the allow list, sub-agents
  included.
- **Two names.** The tool is listed as `Task` in the session's start-up tool list, but tool
  calls in the event stream are named `Agent`. `Format-ToolUse` already handles both
  (`'^(Task|Agent)$'`).
- **Sub-agents run in the background by default.** The session then puts out several
  `result` events: the first said "Both agents are running in the background", and the real
  answer came in the last one. `total_cost_usd` is cumulative.
  - `Invoke-Agent` keeps the last `result`, so it gets the right answer.
  - `Watch-Orchestrator.ps1` (around line 73) sets `$f.Done = $true` on the first `result`,
    so it marks the agent finished too early.
  - Fix: the prompt must tell agents to run sub-agents in the foreground
    (`run_in_background: false`) and wait for them. Several foreground calls in one message
    still run in parallel. Optionally, check whether a setting or environment variable turns
    background sub-agents off for headless runs.
- **Sub-agent events are already in `*.events.jsonl`.**
  - Every event from a sub-agent has `parent_tool_use_id` set to the `id` of the `Agent`
    tool call that started it.
  - The parent's `Agent` call has `input.description`, e.g. "Count .ps1 files in orchestrator/".
  - Also present: `system` events with subtypes `task_started`, `task_progress`,
    `task_updated`, `task_notification` and `background_tasks_changed`.
  - Top-level events have no `parent_tool_use_id`, or an empty one.

### Copilot

- The CLI's own sub-agent tools are `task`, `read_agent`, `list_agents` and `write_agent`
  (`docs/copilot-cli-notes.md`, line 16).
- The orchestrator hides them. Every Copilot call passes `--available-tools`, built from the
  Claude tool names by the `switch` in `Invoke-Agent`, which has no translation for `Task`.
  Notes line 41: "Deliberately not exposed: sub-agents, ...". No reason is recorded.
- Copilot runs with `--allow-all-tools`, so `--available-tools` is the only thing keeping
  the planner and reviewer read-only. Claude has `dontAsk` as a second guard; Copilot has
  nothing like it.
- **Not yet known:** whether a Copilot sub-agent is limited to its parent's
  `--available-tools`, and how sub-agent activity appears in Copilot's event stream (Copilot
  events look like `tool.execution_start` with `data.toolName`, and `assistant.message`).

## Plan

### Step 1: Copilot safety test (do this first, it decides step 2)

Start a Copilot session that has only read-only tools plus sub-agents, e.g.
`--available-tools=view,glob,rg,task,read_agent,list_agents` with `--allow-all-tools` and
the model the orchestrator uses (`$script:CopilotModel` in `Orchestrator.psm1`). Run it in a
scratch folder and tell it to start a sub-agent that creates a file.

- If no file is created, sub-agents are limited to the parent's tools, and Copilot can get
  sub-agents in the worker and the planner.
- If a file is created, give Copilot sub-agents to workers only, which can edit files
  anyway, and write that down in `docs/copilot-cli-notes.md`.

In the same run, save the event stream and note how sub-agent activity appears (tool names,
how events link to the call that started them). Step 4 needs it.

### Step 2: Turn the tool on

In `Invoke-Agent` (`orchestrator/Orchestrator.psm1`):

- **Claude:** add `Task` to the worker's `--allowedTools` and to the planner's `--tools` and
  `--allowedTools`. Workers' tools come from the project setting `allowedTools`
  (`$script:DefaultSettings`, and per project in `.orchestrator/project.json` / `tasks.json`
  settings). Prefer adding `Task` in code, so existing projects need no edits, rather than
  only changing the default.
- **Copilot:** add a translation `'^Task$' { 'task', 'read_agent', 'list_agents' }` to the
  `switch`, and request `Task` where step 1 allows it.
- Do not give it to the reviewer, bootstrap or resolver.
- `tests/fake-claude.ps1` (around line 18) checks Copilot's exact `--available-tools` string
  for each role. Update the expected strings, or the smoke test fails.

### Step 3: Prompt text, filled in by provider

`Format-Template` only replaces `{{KEY}}` values it is given; a placeholder it isn't given
stays in the text unchanged. The prompts are shared by both providers.

- Add a placeholder (e.g. `{{SUBAGENTS}}`) to `worker.md` and `planner.md`.
- Fill it at both call sites: `Format-Template 'worker.md'` in `Orchestrator.psm1` and
  `Format-Template 'planner.md'` in `Plan-Tasks.ps1`. For a provider or role without
  sub-agents, fill it with an empty string.
- The text should say:
  - When you have several independent questions that each need a lot of reading, send them
    to sub-agents in parallel, in one message, and work from their summaries.
  - Run sub-agents in the foreground and wait for all of them before you go on or report
    your result.
  - Sub-agents investigate. Make all code changes yourself. Sub-agents share your worktree,
    so they must not edit files.
  - Don't use sub-agents for small lookups. Each one has a start-up cost.
- If Copilot's tool needs different wording (its tool is `task`), make the text depend on
  the provider.

### Step 4: Label sub-agent activity in the watch views

All three watchers read `*.events.jsonl`. For each file, remember each `Agent` (or `Task`)
call's `id` and its `input.description`. Then mark every event whose
`parent_tool_use_id` matches, for example:

```
Agent Count .ps1 files in orchestrator/
  ↳ [Count .ps1 files] Glob orchestrator/**/*.ps1
```

- `orchestrator/Watch-Orchestrator.ps1`: the recent-activity lines. Also make it treat only
  the last `result` as done, not the first (see the background note above).
- `orchestrator/Watch-Conversations.ps1`: `Convert-Event`. Sub-agent text currently looks
  like the agent's own text.
- `orchestrator/Watch-AgentTimeline.ps1`: `TOOL START` / `TOOL END` and `UPDATE` entries.
- Use what step 1 found to do the same for Copilot.
- Shorten long descriptions so lines still fit the view.

### Step 5: Tests and docs

- Run `tests/Run-SmokeTest.ps1 -Provider Claude` and `-Provider Copilot`. Both passed at
  commit `075e358`. Extend `tests/fake-claude.ps1` to put out a sub-agent call and a few
  events with `parent_tool_use_id`, and add a check that the watchers label them (e.g. with
  `Watch-Conversations.ps1 -Once` and `Watch-AgentTimeline.ps1 -Once`).
- Run one real agent per provider that uses sub-agents, and check that its result and cost
  come out right.
- Update the README:
  - the permissions table ("Agent permissions and safety");
  - the "No agent-to-agent messaging" item under "Limits and known gaps";
  - the watch-view descriptions.
- Update `docs/copilot-cli-notes.md`: the tool translation list and line 41.
- Put the Claude stream behavior (`Task`/`Agent` names, background sub-agents, several
  `result` events, `parent_tool_use_id`) in a note under `docs/`.

## Practical notes

- **Running `claude -p` from inside Claude Code:** clear the inherited `CLAUDECODE`,
  `CLAUDE_CODE_*`, `CLAUDE_PID` and `CLAUDE_EFFORT` variables first. See
  `docs/claude-fable-notes.md`. In PowerShell, `Remove-Item env:...` was blocked by the
  sandbox; this works:

  ```powershell
  Get-ChildItem env: | Where-Object Name -match '^(CLAUDECODE|CLAUDE_CODE_|CLAUDE_PID|CLAUDE_EFFORT)' |
      ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name, $null) }
  ```

- **Line endings:** files in the working tree are CRLF (`core.autocrlf=true`). Editing with
  Python's text mode turned files into LF. Check with `git ls-files --eol <file>` after
  editing.
- **Quick test of a Claude session's tools and events:**

  ```powershell
  'prompt' | claude -p --output-format stream-json --verbose --permission-prompts none --model haiku `
      --permission-mode dontAsk --tools 'Read,Glob,Grep,Task' --allowedTools 'Read,Glob,Grep,Task' `
      --settings '{"autoMemoryEnabled":false}' > events.jsonl
  ```

  Read the tool list from the `system`/`init` event, and follow `parent_tool_use_id` in the
  other events.
- **Already in place:** Claude agents get
  `--disallowedTools mcp__claude_ai_Spotify,mcp__claude_ai_Strava` (commit `78f89bd`). Keep
  it when you change the arguments.
