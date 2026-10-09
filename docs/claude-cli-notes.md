# Claude Code CLI notes

Checked on 2026-10-09 with Claude Code 2.1.289 in headless runs
(`claude -p --output-format stream-json --verbose`), mostly with Haiku.

## Sub-agents

### The tool has two names

- The `system`/`init` event lists the tool as `Task`, and `--tools`, `--allowedTools` and
  `--disallowedTools` take that name. Tool calls in the event stream are named `Agent`, and
  that is the name the model sees, so the worker and planner prompts say "the Agent tool".
- A session started without `--tools` has the tool, whatever `--allowedTools` says. Workers,
  the bootstrap agent and the resolver always had it that way; none of 114 agent logs from
  VeloSage, GhostRacer and The Last Ninja show one using it. Such a session also lists
  `SendMessage`, which continues a sub-agent by its id; the prompts don't ask for it.
- `--permission-mode dontAsk` blocks the tool unless it is on the allow list. It also blocks,
  in the sub-agents, every tool that is not on the list, so a read-only session
  (`--tools Read,Glob,Grep,Task`, the same `--allowedTools`) has read-only sub-agents.
- Agent types in a headless session: `general-purpose`, `Explore`, `Plan`, `claude` (a
  catch-all with all tools) and `statusline-setup` (sets up the status line; Read and Edit
  only), plus custom agents from `~/.claude/agents` and the repo's `.claude/agents`. When the
  model names no type, the sub-agent is `general-purpose`; in one test the model chose
  `Explore` itself.

### Background sub-agents give several result events

- The model may start a sub-agent in the background (`run_in_background: true`), and did so
  unprompted. The session then ends its turn while the sub-agent works and starts a new turn
  when it reports back. Every turn ends with a `result` event: two background sub-agents gave
  three, with `result_index` 0, 1 and 2. Only the last one has the real answer.
- The CLI held results 0 and 1 back until both sub-agents had finished, sent them together,
  started the last turn (with a new `system`/`init` event) and sent result 2 when it ended.
  So the session is still working after the first result.
- `total_cost_usd` is the session total at the time of the event; the last result has it all.
- `Invoke-Agent` keeps the last result. `Watch-Orchestrator.ps1` counts an agent as finished
  only when nothing follows a result.
- With `run_in_background: false` the sub-agent runs in the foreground. Several foreground
  calls in one message still run in parallel, and the session ends with one result. The
  worker and planner prompts ask for this, and the real test runs followed it.
- `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` removes `run_in_background` from the tool, so
  every sub-agent runs in the foreground. The orchestrator does not set it, because it also
  turns off background and auto-backgrounded shell commands for workers. 1 of the 114 agent
  sessions above used one: a worker's `dotnet build`, which it waited for before it finished.

### Sub-agent events in the stream

- Every `assistant` and `user` event of a sub-agent has `parent_tool_use_id` set to the `id`
  of the `Agent` call that started it, plus `subagent_type` and `task_description`. The
  agent's own events have no `parent_tool_use_id`, or `null`.
- The `Agent` call's `input` has `description` (3-5 words, e.g. "Survey billing module"),
  `prompt`, and optionally `subagent_type` and `run_in_background`.
- In the foreground the sub-agent's prompt comes as its first `user` event, and its final
  report only inside the agent's `tool_result` for the `Agent` call, after a
  "[Subagent hand-back]" preamble. In the background there is no prompt event, and the report
  comes as the sub-agent's last `assistant` text event.
- `system` events: `task_started` (with `tool_use_id`, `description`, `prompt`,
  `is_backgrounded`), `task_progress`, `task_updated`, `task_notification` (with `summary`,
  the sub-agent's final text) and `background_tasks_changed` (the background tasks still
  running). A long or background shell command sends the same events with
  `task_type: local_bash`.
- The `result` event has `subagent_stats` (spawned, foreground or background, completed,
  failed, by type) and `modelUsage`, the cost per model.

### Cost

Each sub-agent starts with a fresh context. Two Haiku sub-agents that only counted files cost
0.02 USD in the foreground and 0.03 to 0.04 USD in the background (the extra turns), in a
scratch folder without CLAUDE.md; an earlier run of the same test came to 0.12 USD. A Haiku
worker that surveyed two small modules with two sub-agents and wrote a summary cost 0.16 USD.
The session's `total_cost_usd` includes its sub-agents.

## Testing a headless session from inside Claude Code

Clear the variables the nested CLI inherits first (see also
[claude-fable-notes.md](claude-fable-notes.md)). In PowerShell, `Remove-Item env:...` was
blocked by the sandbox; this works:

```powershell
Get-ChildItem env: | Where-Object Name -match '^(CLAUDECODE|CLAUDE_CODE_|CLAUDE_PID|CLAUDE_EFFORT)' |
    ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name, $null) }
```

A quick look at a session's tools and events:

```powershell
'prompt' | claude -p --output-format stream-json --verbose --permission-prompts none --model haiku `
    --permission-mode dontAsk --tools 'Read,Glob,Grep,Task' --allowedTools 'Read,Glob,Grep,Task' `
    --settings '{"autoMemoryEnabled":false}' > events.jsonl
```

The tool list is in the `system`/`init` event; follow `parent_tool_use_id` in the others.
