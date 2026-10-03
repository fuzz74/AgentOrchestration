# Copilot CLI notes

Checked on 2026-10-03 with GitHub Copilot CLI 1.0.91 and model `gpt-6-sol` on Windows. Moved
here from an assistant's local memory on the same day.

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
  only `view`. The TextKit bootstrap and planner logs were captured with this mapping.
- Since 2026-10-03: Read to `view`, Glob to `glob`, Grep to `rg`, Edit and Write to
  `apply_patch`, Bash and PowerShell to `powershell` plus `read_powershell`,
  `stop_powershell` and `list_powershell`.
- Deliberately not exposed: sub-agents, workflows, web, GitHub and `session_store_sql`.

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
