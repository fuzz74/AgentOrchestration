# Copilot CLI notes

Tool and sub-agent observations below were checked on 2026-10-03 with GitHub Copilot
CLI 1.0.91 and model `gpt-6-sol` on Windows (and again on 2026-10-09 where noted).
Those are historical observations, not the orchestrator's current model setting.

## Current model and reasoning configuration

The orchestrator no longer pins Copilot calls to `gpt-6-sol`. With no explicit
choice it sends `--model gpt-6.1-sol --reasoning-effort high` for bootstrap, planning,
workers, reviews and conflict resolution, including retries and resumed sessions.
`Initialize-Project.ps1 -Model`/`-Effort` set standalone bootstrap choices.
`Plan-Tasks.ps1 -Model`/`-Effort` select the planner; `-WorkerModel` selects the
new-project bootstrap model and persists `settings.model` and `settings.reviewModel`;
`-WorkerEffort` selects bootstrap reasoning and persists `settings.effort` for
workers, reviews and conflict resolution. For example, from the orchestrator checkout:

```powershell
.\orchestrator\Plan-Tasks.ps1 -Provider Copilot -Spec C:\src\myapp\.orchestrator\spec.md -RepoPath C:\src\myapp -Model gpt-6.1-sol -Effort medium -WorkerModel gpt-6.1-sol -WorkerEffort none
```

For standalone initialization of a new coding repo:

```powershell
.\orchestrator\Initialize-Project.ps1 -Provider Copilot -Spec C:\src\myapp\.orchestrator\spec.md -RepoPath C:\src\myapp -Model gpt-6.1-sol -Effort low
```

In `tasks.json`, a task's `model` overrides `settings.model` for that worker only;
`settings.reviewModel` controls reviewers and conflict resolvers. Omitted or JSON
`null` `settings.effort` means the effective provider's default (Copilot `high`;
Claude sends no effort flag). `none` is an explicit Copilot level, not a null value.
Copilot accepts `none`, `minimal`, `low`, `medium`, `high`, `xhigh` and `max` at these
entry points, forwarding the chosen value as `--reasoning-effort`. Claude keeps its
`opus` planner, `sonnet` bootstrap/workers/reviewers, and omitted-effort defaults.

The orchestrator does not keep a model allowlist or discover account models: it passes
explicit IDs unchanged as `--model`. The installed CLI and the signed-in account
decide availability and compatible model/effort pairs. Invalid effort is rejected;
a CLI rejection is surfaced as an agent failure with its diagnostic, with no fallback
model or dropped effort. CLI 1.0.103 advertises `--model` and all seven
`--reasoning-effort` values; support for any particular model depends on the account.
Changing providers for a run changes defaults only where a value is omitted: an
explicit Claude model in a plan is still sent unchanged when running with Copilot,
and may fail. Review or edit explicit values before overriding `-Provider`.

## What Copilot reads from this repo

- Instructions: `copilot instruction list` shows `CLAUDE.md` as the repository instructions.
- Skills: `copilot skill list` finds `plan-tasks` and `write-spec` in `.claude/skills/`.
  Copilot also looks in `.github/skills/` and `.agents/skills/`.

## Tools

Tools the CLI sends to the model by default (25; non-interactive, shell available):
`view`, `apply_patch`, `glob`, `rg`, `powershell`, `read_powershell`, `stop_powershell`,
`list_powershell`, `web_fetch`, `web_search`, `task`, `read_agent`, `list_agents`,
`write_agent`, `run_dynamic_workflow`, `dynamic_workflows_manage`, `sql`,
`session_store_sql`, `skill`, `fetch_copilot_cli_documentation`, and five
`github-mcp-server-*` tools (`get_copilot_space`, `get_file_contents`,
`list_copilot_spaces`, `search_code`, `search_users`).

When the shell tool is filtered out (planner and reviewer sessions), 13 more
`github-mcp-server-*` tools show up in the list: `actions_get`, `actions_list`, `get_commit`,
`get_job_logs`, `issue_read`, `list_branches`, `list_commits`, `list_issues`,
`list_pull_requests`, `pull_request_read`, `search_issues`, `search_pull_requests`,
`search_repositories`. The help text also names an `ask_user` tool (interactive) and memory
(off in prompt mode); neither was in the list.

## How the orchestrator maps tools

`Invoke-Agent` in `orchestrator/Orchestrator.psm1` passes `--available-tools` together with
`--allow-all-tools`, so the filter is the only thing keeping Copilot's planner and reviewer
read-only.

- Until 2026-10-03: Read, Glob and Grep mapped to `view`; Edit and Write to `apply_patch`;
  Bash and PowerShell to `powershell`. Workers had three tools, reviewers and the planner
  only `view`. Earlier bootstrap and planner logs were captured with this mapping.
- Since 2026-10-03: Read to `view`, Glob to `glob`, Grep to `rg`, Edit and Write to
  `apply_patch`, Bash and PowerShell to `powershell` plus `read_powershell`,
  `stop_powershell` and `list_powershell`.
- Since 2026-10-09: Task (sub-agents) to `task`, `read_agent` and `list_agents`, for workers
  and the planner only.
- Deliberately not exposed: `write_agent` (follow-up messages to a sub-agent; add it only if
  a test shows sub-agents need them), workflows, web, GitHub and `session_store_sql`.

## Sub-agents

Checked on 2026-10-09 with CLI 1.0.91, and again with 1.0.95.

- **A sub-agent gets its parent's tools.** A session with
  `--available-tools=view,glob,rg,task,read_agent,list_agents` and `--allow-all-tools` was
  told to start a general-purpose sub-agent that writes a file. The sub-agent listed only
  those six tools and wrote nothing. The process log showed the same six tools in every model
  call, including those of the sub-agents it started in turn. So the planner's sub-agents
  stay read-only, and both workers and the planner get sub-agents.
- Nesting stops at depth 4 ("Maximum sub-agent depth of 4 reached").
- The `task` tool takes `description`, `prompt`, `agent_type`, `name` and `mode`. Calls
  without `mode` ran `sync`. In those historical sessions, a `general-purpose`
  sub-agent used the session model (`gpt-6-sol`); `task` and `explore` sub-agents
  used `gpt-5.6-luna`, set by their agent definition. These observations do not
  imply a current orchestrator model pin. A worker also chose `explore` by itself.
- Copilot's own instructions tell the model to delegate only work that needs a separate
  context, not work it can finish in five or fewer tool calls, and to use background mode only
  while it does independent work. The worker and planner prompts ask for `mode: "sync"`.

To check again after an update, ask such a session for a general-purpose sub-agent that writes
a file, with `--log-level all --log-dir <dir>`, and read `copilotToolsFingerprint.tools` in
the process log for every model call.

### Sub-agent events in the stream

- The agent's call is a `tool.execution_start` with `data.toolName` `task` and the arguments
  above in `data.arguments`.
- `subagent.started` follows, with a top-level `agentId` (the new sub-agent),
  `data.toolCallId` (the call), `data.agentDescription`, `data.agentDisplayName` (the
  `name`), `data.agentType`, `data.model` and `data.executionMode`. `subagent.configured` and
  `subagent.completed` (with totals) carry the same `agentId`.
- Every event of a sub-agent has that top-level `agentId`: messages, deltas, model calls and
  tool calls. Its tool events also have `data.parentToolCallId`. The agent's own events have
  no `agentId`.
- A sub-agent's answer is an `assistant.message` with `phase: final_answer`, like the agent's
  own. `Invoke-Agent` ignores those that carry an `agentId`, so a sub-agent's answer cannot
  become the agent's result.
- `session.background_tasks_changed` events (with empty `data`) come throughout, also for
  `sync` sub-agents. There was one `result` event, at the end.

## Where tool lists appear in logs

- Every Copilot `*.events.jsonl` has a `session.info` event whose message is
  `Disabled tools: ...` (the tools hidden by the filter). Enabled tools are not listed in the
  event stream.
- Running the CLI with `--log-level all --log-dir <dir>` writes a process log that contains
  `copilotToolsFingerprint.tools` (the exact list sent) and the full system instructions.

## CLI location

`%LOCALAPPDATA%\Microsoft\WinGet\Packages\GitHub.Copilot_Microsoft.Winget.Source_8wekyb3d8bbwe\copilot.exe`.
Inside the VS Code extension host it was not on PATH. The orchestrator then resolves VS
Code's `copilot.bat` shim, which prompts interactively when it cannot find the CLI.

The CLI updates itself: a run downloads the new version for the next start. On 2026-10-09 it
went from 1.0.91 to 1.0.95 in one afternoon, so note the version with each finding.
