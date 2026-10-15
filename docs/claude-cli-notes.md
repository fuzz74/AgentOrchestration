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
  Example Projects E, C and D show one using it. Such a session also lists
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

## Calling the CLI from an app at runtime

Checked on 2026-10-15 with Claude Code 2.1.296, for Example Project L, an app that calls
`claude -p` itself.

**A minimal call.** These flags gave about 3-5 s per call (haiku, sonnet and opus alike) and only
about 670 cache-creation tokens, against roughly 41K with the default system prompt:

```
-p --model <m> --output-format json --system-prompt-file <file> --tools "" --strict-mcp-config
   --no-session-persistence --disable-slash-commands --setting-sources "" [--json-schema <json>] [--effort low]
```

- Send the user prompt on stdin. Put the system prompt in a file: `--system-prompt-file` works and
  avoids quoting and command-line length problems.
- `--json-schema` takes inline JSON only. A file path fails with `Error: --json-schema is not a
  valid JSON Schema`.
- Structured output still works with `--tools ""`. The answer is in `structured_output`, and
  `result` holds the same JSON as text. `enum`, `minimum`/`maximum`, `pattern`, integers and
  nested arrays were all accepted. A 33-property schema took 6.6 s on sonnet.
- `--effort low` roughly halved the cost on sonnet and opus at the same latency.
- An unknown model exits 1 with `[claude-code:unrecognized_model] {...}` on stderr. Stdout still
  holds a JSON result with `is_error: true`, `api_error_status: 404` and a readable `result`.
- Run it in an empty working folder, and remove the session variables listed above from the child
  environment. Otherwise a CLI started from a terminal inside Claude Code inherits them.
- Answers sometimes contain emoji and `*emphasis*`, even when the prompt forbids them. Clean the text
  before it is shown or spoken.
- Generating the next answer while the current one is still in use hides the 3-5 s latency
  completely. In the live check, nothing waited on the CLI after the first answer.

**Repeated phrasing across calls.** Checked on 2026-10-15, in the second follow-up round of Example
Project L. The app feeds earlier answers back as context, and the model copied its own earlier
habits from them: the same opener, the same short phrase, the same closing shape.
- **Prompt rules alone helped, not enough.** One rule was "use a pet phrase at most once every few
  turns". Descriptive fields in the system prompt, such as a style description, still pull a phrase into nearly every answer.
- **Hints in the next prompt helped more.** A deterministic check of the earlier answers names the
  habit in the next prompt, for that call only ("You keep saying …; leave that out this time"). It
  costs no extra call. The habit then turned up in about a quarter as many answers.
- **Research agreed with what we saw:**
  - No free anti-repetition tool works without logit access, which `claude -p` does not give.
  - A second "rewrite" call per answer works but doubles cost and latency.
  - Short varied examples in the prompt help style, but examples get copied, so keep them unlike
    the real content.
