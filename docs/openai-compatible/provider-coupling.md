# Provider coupling inventory

Scan date: 2026-10-28, branch `orch/task/coupling-inventory`, read from the working tree only. No code was run and no CLI was called. Line numbers are those of this tree and drift when files change.

Scope scanned: `orchestrator/*.ps1`, `orchestrator/*.psm1`, `orchestrator/schemas/*.json`, `orchestrator/prompts/*.md`, `tests/*.ps1`, `Install-Orch.ps1`, `.claude/skills/**/SKILL.md`, `README.md`, `docs/**/*.md`.

## Summary

- Counts: 116 inventory rows over about 40 files; 14 provider responsibilities (R1-R14): 5 invocation, 3 output interpretation, 3 capability, 3 configuration. `Responsibilities` gives the split per id.
- 12 `ValidateSet('Claude','Copilot')` parameters (5 in `Orchestrator.psm1`, 7 in scripts and tests), plus the `tasks.schema.json` enum at `:20-23` and two re-casing lines (`Plan-Tasks.ps1:113`, `Install-Orch.ps1:48`). A third provider touches all of them.
- Hotspot 1: `Invoke-Agent` (`Orchestrator.psm1:729-902`) holds argument building, tool mapping, event parsing, result/session/cost extraction, structured output and the nudge in one function.
- Hotspot 2: model and effort defaults are spread over `Get-DefaultSettings`, `Resolve-AgentModel`, `Read-Plan`, `Plan-Tasks.ps1`, `Initialize-Project.ps1`, the schema text and README.
- Hotspot 3: event shapes are parsed separately in `Invoke-Agent`, `Get-SubAgentName`, `Format-ToolUse`, `Watch-Orchestrator.ps1`, `Watch-Conversations.ps1` and `Watch-AgentTimeline.ps1`; the watch scripts accept both shapes without a provider flag.
- Hotspot 4: `Resolve-AgentPath` and `Get-AgentProcesses` hard-code executable names and install locations; `Resolve-OrchProvider` does not validate the name.
- The tool vocabulary (`allowedTools`, `Task`, `Bash(git add *)`) is Claude's, and the Copilot branch translates it.
- Tests: 5 test files; `fake-claude.ps1` and `Run-SmokeTest.ps1` carry most provider assertions. Skills: 3 name providers (`orch`, `plan-tasks`, `write-spec`), 4 do not. Docs: README plus 5 docs files name providers.
- Static reading only; nothing was run, so CLI behaviour stated here comes from code and the repo's notes (untested).

## Inventory

Responsibility ids (R1-R14) are defined in the Responsibilities section.

### orchestrator/Orchestrator.psm1

| File | Location | What is provider-specific | Responsibility |
| --- | --- | --- | --- |
| Orchestrator.psm1 | `:8` `$script:CopilotModel` | Copilot default model `gpt-6.1-sol` hard-coded. | R11 |
| Orchestrator.psm1 | `:12` `$script:ClaudeDeniedMcpServers` | claude.ai connectors (Spotify, Strava, Claude Docs) denied for Claude agents only. | R3 |
| Orchestrator.psm1 | `:15` `$script:OrchestratorSkills` | Skill names denied to headless agents; used only by the Claude branch (`:758`). | R3 |
| Orchestrator.psm1 | `:17-34` `$script:DefaultSettings` | `model='sonnet'`, `reviewModel='sonnet'`, `effort=$null`, `permissionMode='acceptEdits'`, `allowedTools` in Claude tool names (`Read, Edit, Write, Glob, Grep, Bash, PowerShell`), `maxBudgetUsd`. | R11, R4 |
| Orchestrator.psm1 | `:37-46` `Get-DefaultSettings` | `ValidateSet('Claude','Copilot')`; `-eq 'Copilot'` swaps model and reviewModel to `gpt-6.1-sol` and effort to `high`. | R11, R14 |
| Orchestrator.psm1 | `:48-52` `Resolve-AgentModel` | `-eq 'Copilot'` and no model gives `gpt-6.1-sol`; Claude passes the model through (may be null). | R11 |
| Orchestrator.psm1 | `:116-149` `Resolve-AgentPath` | `ValidateSet`; override env var `ORCH_CLAUDE` / `ORCH_COPILOT` built from the provider name (`:119`); command `claude` vs `copilot.exe` (`:121`); Copilot skips a PATH hit under `*github.copilot-chat*` (`:124-126`); VS Code extension globs `anthropic.claude-code-*` vs `github.copilot-chat-*` and binary subpaths (`:130-135`); Copilot-only managed folder `globalStorage/github.copilot-chat/copilotCli` (`:141-146`); error text names the provider (`:148`). | R1 |
| Orchestrator.psm1 | `:155-174` `Read-Plan` | `ValidateSet` on `-Provider`; `$doc.provider -in 'Claude','Copilot'` else Claude (`:171`); provider defaults (`:172`); Copilot null effort becomes `high` (`:174`). | R14, R11 |
| Orchestrator.psm1 | `:662-672` `Format-SubAgents` | `ValidateSet`; Copilot gets "the `task` tool" and `mode: "sync"`, Claude gets "the Agent tool" and `run_in_background: false`; fills `{{SUBAGENTS}}` from `prompts/subagents.md`. | R9 |
| Orchestrator.psm1 | `:675-698` `Format-ToolUse` | Reads Claude `tool_use` blocks only; names `Read, Edit, Write, MultiEdit, NotebookEdit, Glob, Grep, Bash, PowerShell, StructuredOutput, Task, Agent` (`:686-693`). Copilot tool events are not formatted here. | R5 |
| Orchestrator.psm1 | `:700-717` `Get-SubAgentName` | Claude: `assistant` event with `tool_use` named `Task`/`Agent`, then `parent_tool_use_id` (`:709-714`). Copilot: `subagent.started` with `agentId` and `data.agentDescription` (`:708`, `:714`). | R5, R9 |
| Orchestrator.psm1 | `:729-736` `Invoke-Agent` signature | `ValidateSet('Claude','Copilot')`, default `Claude`; Claude-flavoured parameters `PermissionMode`, `AllowedTools`, `Tools`, `MaxBudgetUsd`, `-SubAgents` (adds `Task`, `:748-752`). | R3, R14, R9, R12 |
| Orchestrator.psm1 | `:737-746` | Effort list `none..max` validated for both (`:738-741`); `Resolve-AgentModel`; Copilot null effort becomes `high`. | R11 |
| Orchestrator.psm1 | `:754-769` Claude args | `-p --output-format stream-json --verbose --permission-prompts none`; `--settings {"autoMemoryEnabled":false}`; `--disallowedTools`; `--json-schema`; `--model`; `--effort`; `--permission-mode`; `--allowedTools`; `--tools`; `--max-budget-usd`; `--resume`; `--name`. | R3, R7, R10 |
| Orchestrator.psm1 | `:770-804` Copilot args | Schema text appended to the prompt (`:771-773`); `--output-format json --allow-all-tools`; `--model`; `--reasoning-effort`; `--available-tools=` or `--excluded-tools=skill`; `--resume`; `--name` only when not resuming (`:802`). | R3, R7, R10 |
| Orchestrator.psm1 | `:776-796` tool-name mapping | Read to `view`, Glob to `glob`, Grep to `rg`, Edit/Write to `apply_patch`, Bash/PowerShell to `powershell`, `read_powershell`, `stop_powershell`, `list_powershell`, Task to `task`, `read_agent`, `list_agents`; anything else throws (`:789`). | R4 |
| Orchestrator.psm1 | `:806-846` event loop | Result event `type -eq 'result'` is common (`:818`); Copilot final answer is `assistant.message` with `data.phase -eq 'final_answer'` and no `agentId` (`:821-823`); Copilot activity from `tool.execution_start` (`:824-828`); Claude activity from `assistant` `tool_use` blocks via `Format-ToolUse` (`:829-836`). | R5, R13 |
| Orchestrator.psm1 | `:854` finished test | Copilot `$parsed.exitCode -eq 0`; Claude `-not $parsed.is_error`. | R6 |
| Orchestrator.psm1 | `:857-868` structured output | Claude: `$parsed.structured_output` from the CLI. Copilot: fence stripped from the final answer, `Test-Json` against the schema, `ConvertFrom-Json`. | R10 |
| Orchestrator.psm1 | `:869-873` error text | Uses Claude result fields `subtype` and `result`; `"$Provider ended with / exited with"`. | R6 |
| Orchestrator.psm1 | `:876-883` result object | `SessionId` from `sessionId` (Copilot) or `session_id` (Claude); `Cost` from `total_cost_usd` (a Claude field; Copilot results carry none, so 0); `Text` from `copilotText` or `result`. | R6 |
| Orchestrator.psm1 | `:884-902` nudge | Resumes the session once. Claude prompt names the `StructuredOutput` tool (`:895`); Copilot prompt asks for corrected JSON using `$schemaError`. | R8, R7 |
| Orchestrator.psm1 | `:959-960` `Sync-WithIntegration` resolver tools | Copilot: `AllowedTools + Bash`; Claude: `AllowedTools + Bash(git add *), Bash(git status *), Bash(git diff *)` (Claude permission-rule syntax). | R4 |
| Orchestrator.psm1 | `:1000` review call | `-PermissionMode 'dontAsk' -Tools Read,Glob,Grep`. The Copilot branch does not use `PermissionMode`; it maps `Tools` to `--available-tools`. | R3, R4 |
| Orchestrator.psm1 | `:1041-1068` worker resume | Resume with feedback uses the `SessionId` that both providers must return; passes `Provider`, `-SubAgents`, `PermissionMode`. | R7, R9 |
| Orchestrator.psm1 | `:650` `Get-CompactSchema` | Provider-neutral itself; output feeds Claude `--json-schema` (`:760`) and the Copilot prompt (`:772`). | R10 |

### Entry scripts, Orch.psm1 and the watch scripts

| File | Location | What is provider-specific | Responsibility |
| --- | --- | --- | --- |
| Invoke-Orchestrator.ps1 | `:4`, `:15-17` | Synopsis and examples name Claude and Copilot. | R14 |
| Invoke-Orchestrator.ps1 | `:21` | `Mandatory`, `ValidateSet('Claude','Copilot')` on `$Provider`. | R14 |
| Invoke-Orchestrator.ps1 | `:38`, `:66` | `Read-Plan -Provider`, `Resolve-AgentPath -Provider`. | R1, R11 |
| Invoke-Orchestrator.ps1 | `:121`, `:287` | Log line `"${Provider}: $agent"`; warning "Check for leftover $Provider processes". | R13 |
| Invoke-Orchestrator.ps1 | `:149`, `:155` | `Resolve-AgentModel -Provider` for model and reviewModel; `Provider`, `AgentPath` put in the task context. | R11, R3 |
| Plan-Tasks.ps1 | `:23-25` | Examples name both providers and give per-provider model names. | R14 |
| Plan-Tasks.ps1 | `:30` | `Mandatory`, `ValidateSet('Claude','Copilot')` on `$Provider`. | R14 |
| Plan-Tasks.ps1 | `:47-48` | `-eq 'Claude'` gives planner `opus` and worker `sonnet`; Copilot goes through `Resolve-AgentModel` to `gpt-6.1-sol`. | R11 |
| Plan-Tasks.ps1 | `:52`, `:77`, `:90`, `:95` | Passes `Provider` to bootstrap, `Resolve-AgentPath`, `Format-SubAgents $Provider 'planner'`, `Invoke-Agent`. | R1, R9, R3 |
| Plan-Tasks.ps1 | `:113` | `provider = [string](@('Claude','Copilot') -eq $Provider)` re-cases the value into the tasks.json enum. | R14 |
| Plan-Tasks.ps1 | `:140`, `:154-163` | `Read-Plan -Provider`; writes `project.provider`; closing hints print `-Provider $Provider`. | R2 |
| Initialize-Project.ps1 | `:14`, `:20` | Example and `Mandatory`, `ValidateSet('Claude','Copilot')`. | R14 |
| Initialize-Project.ps1 | `:31` | `-eq 'Claude'` gives bootstrap model `sonnet`; Copilot through `Resolve-AgentModel`. | R11 |
| Initialize-Project.ps1 | `:92`, `:100` | `Resolve-AgentPath`; `Invoke-Agent` with provider and `Schema='bootstrap-result.schema.json'`. | R1, R3 |
| Orch.psm1 | `:5`, `:6`, `:9` | Command table flag `Provider = $true` for `plan`, `run`, `watch` only. | R2 |
| Orch.psm1 | `:161-178` `Resolve-OrchProvider` | Order: `-Provider`, `tasks.json` `provider`, `project.json` `provider`, `ORCH_PROVIDER` (process, then User). Returns the raw name without validating it. | R2 |
| Orch.psm1 | `:210-217` | Error text "Add -Provider Claude or -Provider Copilot, or set your default with Install-Orch.ps1 -Provider"; header prints provider and its source. | R2, R14 |
| Orch.psm1 | `:113` comment | Env vars of a Claude Code session (`CLAUDECODE`, session id) are stripped from the child unless `-UserEnvironment`. | R3 |
| Watch-Orchestrator.ps1 | `:18-26` | Examples; `Mandatory`, `ValidateSet('Claude','Copilot')` on `$Provider`. | R14 |
| Watch-Orchestrator.ps1 | `:74-95` | `Done = type -eq 'result'` (common); Copilot `tool.execution_start` with `toolName -eq 'task'` and `assistant.message` `final_answer`; Claude `assistant` `tool_use` and `text` blocks via `Format-ToolUse`. Parses both shapes without using `$Provider`. | R5 |
| Watch-Orchestrator.ps1 | `:102-110`, `:151` `Get-ResultCost` | Reads `total_cost_usd` from the logged result file (a Claude field). | R6 |
| Watch-Orchestrator.ps1 | `:128` `Get-ReviewFeedback` | Matches only Copilot `assistant.message` `final_answer` events in `*-review-*.json.events.jsonl`. Whether a Claude review log yields feedback here was not tested; by the code it would not match. | R5, R10 |
| Watch-Orchestrator.ps1 | `:203-229` `Get-AgentProcesses` | `copilot.exe` vs `claude.exe` (`:206`); Copilot also matches `--resume <session-guid>` to running tasks' `sessionId` (`:209-224`); both match `--name orch:<task>[:review\|resolve]`. | R13, R7 |
| Watch-Orchestrator.ps1 | `:312` | Label "Live $Provider CLI processes". | R13 |
| Watch-Conversations.ps1 | `:60-62`, `:67-96` | Both shapes, no `$Provider`: Copilot `tool.execution_start` (`toolName -eq 'task'`), `assistant.message`; Claude `assistant` `tool_use` named `Task`/`Agent`, `text`; `Get-SubAgentName`. | R5, R9 |
| Watch-AgentTimeline.ps1 | `:63-140` `Convert-AgentEvent` | Copilot event types `model.call_start`, `model.call_finished`, `assistant.message`, `tool.execution_start`, `tool.execution_complete`; Claude `assistant` `tool_use`, `user` `tool_result` (`:121-138`). No `$Provider` parameter. | R5 |
| Clear-Orchestrator.ps1 | `:47` | Resets `sessionId` (field is provider-neutral). Complete-, Show-, Wait-, Request-… scripts: no provider branch found. | none |

### Schemas and prompts

| File | Location | What is provider-specific | Responsibility |
| --- | --- | --- | --- |
| schemas/tasks.schema.json | `:20-23` | `provider` enum `["Claude","Copilot"]`. | R14 |
| schemas/tasks.schema.json | `:29-30` | Descriptions: model default "sonnet for Claude, gpt-6.1-sol for Copilot". | R11 |
| schemas/tasks.schema.json | `:32` | `effort` enum `none..max` plus null; Claude sends it as `--effort`, Copilot as `--reasoning-effort`. | R11 |
| schemas/tasks.schema.json | `:44` | `maxBudgetUsd` "Spend cap per claude call"; Copilot has none. | R12 |
| prompts/worker.md `:23`, analysis-worker.md `:25`, planner.md `:19` | `{{SUBAGENTS}}` | Placeholder for the provider-specific sub-agent text (from `prompts/subagents.md` with `{{TOOL}}`, `{{FOREGROUND}}`, `{{EDITS}}`). | R9 |
| prompts/planner.md | `:12` | The only literal provider word: "Do not choose a type from the provider name". Not a branch. | none |
| schemas/worker-result, review-result, plan-output, bootstrap-result | structured-output contracts | Neutral JSON Schema; used by `--json-schema` (Claude) or prompt plus `Test-Json` (Copilot). | R10 |

### Install-Orch.ps1

| File | Location | What is provider-specific | Responsibility |
| --- | --- | --- | --- |
| Install-Orch.ps1 | `:14-26` | Help text for `-Provider`, `ORCH_PROVIDER`, `~\.claude\skills`, `~\.copilot\skills`. | R2, R14 |
| Install-Orch.ps1 | `:31` | `ValidateSet('Claude','Copilot')` on `$Provider`. | R14 |
| Install-Orch.ps1 | `:47-55` | Re-cases the name with `@('Claude','Copilot') -eq $Provider`; writes user env var `ORCH_PROVIDER`. | R2, R14 |
| Install-Orch.ps1 | `:67-85` | Links skills into `~\.claude\skills` and `~\.copilot\skills`. | R1 |
| Install-Orch.ps1 | `:88-100` | Edits `~\.claude\settings.json` `permissions.additionalDirectories` (Claude only). | R3 |

### Tests

| File | Location | What is provider-specific | Responsibility |
| --- | --- | --- | --- |
| tests/fake-claude.ps1 | `:7` | Detects Copilot by `--output-format json` (Claude uses `stream-json`). | R3 |
| tests/fake-claude.ps1 | `:8-10` | `FAKE_REQUIRE_MODEL` check, "Expected Copilot model". | R11 |
| tests/fake-claude.ps1 | `:18-24` | `FAKE_CHECK_SKILL_BLOCK`: Copilot must carry `--available-tools=` or `--excluded-tools=skill`. | R4 |
| tests/fake-claude.ps1 | `:47-58` | Expected `--available-tools` string per role (reviewer `view,glob,rg`; planner adds `task,read_agent,list_agents`; bootstrap and resolver `$edit`; worker `$edit` plus task tools). | R4 |
| tests/fake-claude.ps1 | `:59-67` | Claude: `Task` in `--allowedTools` / `--tools` only for planner and worker. | R4, R9 |
| tests/fake-claude.ps1 | `:73-91` | Sub-agent event streams in both shapes (Copilot `subagent.started`, `agentId`; Claude `parent_tool_use_id`, an early `result`, background Agent). | R5, R9 |
| tests/fake-claude.ps1 | `:96-110` `Out-Result` | Copilot: `assistant.message` `final_answer`, a trailing sub-agent answer, `result` with `sessionId` and `exitCode`. Claude: `result` with `session_id`, `total_cost_usd`, `structured_output`. | R6, R10 |
| tests/fake-claude.ps1 | `:113-120` | Nudge triggers by prompt text: `Report your result now` (Claude) and `Your previous JSON did not match the schema` (Copilot). | R8 |
| tests/Run-SmokeTest.ps1 | `:13` | `Mandatory`, `ValidateSet('Claude','Copilot')` on `$Provider`. | R14 |
| tests/Run-SmokeTest.ps1 | `:19-20`, `:207`, `:502`, `:526`, `:539` | Hard-coded `fake-claude.ps1` and temp folder `fake-claude`; skill-block and bootstrap-call notes. | R3 |
| tests/Run-SmokeTest.ps1 | `:52`, `:73`, `:83`, `:253-347`, `:428-443`, `:506-618` | Pass `-Provider $Provider -AgentPath $fake` to `Plan-Tasks`, `Invoke-Orchestrator`, `Initialize-Project`. | R14 |
| tests/Run-SmokeTest.ps1 | `:61-62` | Copilot plan must carry `gpt-6.1-sol` for model and reviewModel. | R11 |
| tests/Run-SmokeTest.ps1 | `:89-95`, `:220` | Copilot only: 50 000-character prompt through `Invoke-Agent -Provider Copilot` ("long Copilot prompt uses stdin"). | R3 |
| tests/Run-SmokeTest.ps1 | `:98-99` | Heartbeat check with a planner role and `-SubAgents`. | R13, R9 |
| tests/Run-SmokeTest.ps1 | `:102-117` | UTF-8 check: a fake `claude.cmd` emits Claude-format events and runs `Invoke-Agent -Provider Claude`. | R5, R6 |
| tests/Run-SmokeTest.ps1 | `:135-150` `$modelFlagsOk` | Copilot: `--model` and `--reasoning-effort high`; Claude: `--model`, no `--effort`; `--name` values `orch:planner`, `orch:*:review`. | R3, R11 |
| tests/Run-SmokeTest.ps1 | `:170` | Expected sub-agent text per provider (`the task tool ... mode: "sync"` vs `the Agent tool ... run_in_background: false`). | R9 |
| tests/Run-SmokeTest.ps1 | `:214-215` | `orch watch uses the plan provider`: plan `provider` equals `$Provider`; output `provider X (from the plan)` and `Live X CLI processes`. | R2, R13 |
| tests/Run-SmokeTest.ps1 | `:237`, `:352-367` | Copilot only: `settings.effort='xhigh'` kept on retries and resume (`--reasoning-effort`, `--resume`). | R7, R11 |
| tests/Run-SmokeTest.ps1 | `:461-473` | `orch plan takes project.json provider`; `orch run takes the plan provider`. | R2 |
| tests/Test-CopilotModelSettings.ps1 | `:28-47` `Assert-Role` | Effort flag `--reasoning-effort` (Copilot) vs `--effort` (Claude); Claude must not get a Copilot effort flag. | R3, R11 |
| tests/Test-CopilotModelSettings.ps1 | `:49-91` `Write-Plan`, `Run-Case` | Plans for provider A run under provider B. | R2, R11 |
| tests/Test-CopilotModelSettings.ps1 | `:105-120` | Copilot bootstrap and planner defaults `gpt-6.1-sol` / `high`; explicit overrides; persisted settings. | R11 |
| tests/Test-CopilotModelSettings.ps1 | `:127-133` | Cases `claude-plan-copilot-run`, `copilot-plan-claude-run`, `claude-ids-under-copilot`, worker-only and review-only overrides. | R11, R2 |
| tests/Test-CopilotModelSettings.ps1 | `:138-186` | `Invoke-Agent -Provider Copilot`: unlisted model passes through, invalid effort rejected, CLI effort rejection surfaces, tasks schema accepts null effort. | R11, R6 |
| tests/New-PracticeRepo.ps1 | `:22`, `:27`, `:51` | `ValidateSet('Claude','Copilot')` with default Claude; `fake-claude.ps1`; passes `-Provider` and `-AgentPath`. | R14, R3 |
| tests/Test-AnalysisSkills.ps1 | whole file | Static checks of skill text. No provider branch and no `-Provider` assertion found by grep. | none |

### Skills, README and docs

| File | Location | What is provider-specific | Responsibility |
| --- | --- | --- | --- |
| .claude/skills/orch/SKILL.md | `:56-57`, `:84-93` | Provider order (request, `project.json`, `ORCH_PROVIDER`); per-provider defaults in the plan step (`:86-87`); report of which provider runs the tasks. | R2, R11 |
| .claude/skills/plan-tasks/SKILL.md | `:10`, `:44-54` | "Claude or Copilot headless worker"; permission setup for both CLIs; order `project.json`, `ORCH_PROVIDER`, then Claude; "do not copy the models from an example plan for a different provider". | R2, R11 |
| .claude/skills/plan-tasks/SKILL.md | `:65`, `:148`, `:151` | `-Provider <Claude\|Copilot>` in commands for `Initialize-Project.ps1` and `Invoke-Orchestrator.ps1`. | R14 |
| .claude/skills/plan-tasks/SKILL.md | `:106-107`, `:128` | Set `provider` in `tasks.json` and `project.json`; example `"provider": "Claude"`. | R14, R2 |
| .claude/skills/plan-tasks/SKILL.md | `:136-143` | Copilot defaults, explicit effort `none`, supported Copilot levels. | R11 |
| .claude/skills/write-spec/SKILL.md | `:10`, `:85`, `:151-154` | "Claude or Copilot headless worker"; Copilot CLI permission setup; `Plan-Tasks.ps1 -Provider <Claude\|Copilot>`; "Ask which provider to use". | R14, R2 |
| .claude/skills/auto-develop, analyze, auto-analyze, write-spec-analyze `SKILL.md` | no match | No provider words found by grep. They reach the provider through `orch` and `write-spec`. | none |
| README.md | `:8-10`, `:68`, `:76-80`, `:86` | Intro; agent chat; install; login (`copilot login`); `-AgentPath`, then `ORCH_CLAUDE` / `ORCH_COPILOT`; smoke test commands for both providers. | R1, R14 |
| README.md | `:122-136`, `:186` | `Install-Orch.ps1 -Provider Claude\|Copilot`; skill links `~\.claude\skills`, `~\.copilot\skills`. | R2 |
| README.md | `:199-230` | "Choosing Claude or Copilot": ways to pick, resolution order, cross-provider model caveat. | R2, R11 |
| README.md | `:274`, `:305`, `:379-404`, `:427-446`, `:526` | `/auto-develop ... Use Copilot`; planner defaults per provider; examples with `-Provider Copilot`. | R14, R11 |
| README.md | `:453-455` | Dashboard lists live CLI process ids; resumed Copilot sessions may lack a name. | R13 |
| README.md | `:621-685` | tasks.json `provider` field; defaults table for `model`, `reviewModel`, `effort`, `maxBudgetUsd` (Claude only); Copilot effort levels. | R14, R11, R12 |
| README.md | `:759-764` | Structured output: Claude `--json-schema`; Copilot validated locally. | R10 |
| README.md | `:813`, `:840`, `:898-911` | Worker is `claude -p`; Copilot has no USD cap; script parameter table (`-Provider Claude\|Copilot` for `Initialize-Project`, `Plan-Tasks`, `Invoke-Orchestrator`, `Watch-Orchestrator`, `Install-Orch`, `Run-SmokeTest`; `New-PracticeRepo`). | R14, R12 |
| README.md | `:927-963`, `:1003-1007` | Copilot tool filter, local result validation, skill denial (Claude by name, Copilot by `--excluded-tools=skill`), no `write_agent`, cost (Claude client-side USD, Copilot none). | R4, R10, R12, R6 |
| README.md | `:1032` | Link to Claude headless docs. | R3 |
| docs/copilot-cli-notes.md | `:7-45`, `:69-85`, `:86-126`, `:127-134`, `:135-150` | Copilot model and reasoning, tool mapping, sub-agents and their events, log locations, CLI location. | R11, R4, R9, R5, R1 |
| docs/claude-cli-notes.md | whole file | Claude CLI notes. grep found no Copilot or provider words. | R3 |
| docs/claude-fable-notes.md | `:70` | Example command with `-Provider Claude`. | R14 |
| docs/analysis-mode.md | `:61-66` | "Claude and Copilot runs block the three interactive analysis entry skills, using their existing provider-specific skill restrictions." | R3 |
| docs/orchestrator-from-any-repo.md | `:14`, `:39`, `:47`, `:51`, `:61-63` | Design note: `-Provider` from `project.json`; user-level skill folders for both CLIs. | R2 |
| docs/orchestrator-from-any-repo-progress.md | about 84 hits, e.g. `:82`, `:221-246`, `:260-271`, `:296-334` | Progress log: provider order, `ORCH_PROVIDER`, watch views, smoke runs for both providers. Historical record. | R2, R13 |
| docs/dotnet-notes.md | `:29`, `:135`, `:705`, `:1016` | False positives: .NET `ISampleProvider` and `TimeProvider`. `docs/electron-notes.md` has no hit. | none |

## Responsibilities

Kinds: invocation (builds and starts the call), output interpretation (reads what comes back), capability (something a provider can or cannot do), configuration (a value the user or the plan sets).

| Id | Responsibility | Kind | Entries | Claude today | Copilot today |
| --- | --- | --- | --- | --- | --- |
| R1 | Agent discovery | invocation | `Resolve-AgentPath` (`Orchestrator.psm1:116-149`); `Install-Orch.ps1:67-85`; README `:76-80` | PATH `claude`; env `ORCH_CLAUDE`; VS Code extension `anthropic.claude-code-*` native binary. | PATH `copilot.exe` (not the chat extension shim); `ORCH_COPILOT`; extension globs and the managed `copilotCli` folder. |
| R2 | Provider resolution and persistence | configuration | `Resolve-OrchProvider` (`Orch.psm1:161-178`); `Plan-Tasks.ps1:113,154-163`; `tasks.schema.json:20`; `Install-Orch.ps1:47-55`; skills; README `:199-230` | Name `Claude` accepted as written. | Same, name `Copilot`. Resolution does not validate the name. |
| R3 | Invocation and argument building | invocation | `Invoke-Agent:754-804`; `ClaudeDeniedMcpServers`, `OrchestratorSkills`; `Install-Orch.ps1:88-100`; fake-claude `:7`; Run-SmokeTest `:19`, `:89-95`, `:135-150` | stdin prompt; `-p --output-format stream-json --verbose`; denies connectors and skills; `--settings` turns off auto memory; permission flags. | stdin prompt; `--output-format json --allow-all-tools`; schema pasted into the prompt; skill tool removed by `--excluded-tools=skill`. |
| R4 | Tool-name and permission mapping | invocation | `DefaultSettings.allowedTools`; mapping `:776-796`; resolver tools `:959-960`; review `:1000`; fake-claude `:18-67`; README `:927-963`; copilot-cli-notes `:69-85` | Native names; permission rules such as `Bash(git add *)`; `--allowedTools` and `--tools`. | Mapped to `view, glob, rg, apply_patch, powershell*, task, read_agent, list_agents` in `--available-tools`; rules with arguments throw; `PermissionMode` unused. |
| R5 | Event-stream interpretation | output interpretation | `Format-ToolUse`; `Get-SubAgentName`; event loop `:806-846`; Watch-Orchestrator `:74-95,128`; Watch-Conversations `:60-96`; Watch-AgentTimeline `:63-140`; fake-claude `:73-110` | JSON lines: `assistant` with `tool_use` / `text`, `user` with `tool_result`, one or more `result`. | JSON lines: `tool.execution_start` / `_complete`, `assistant.message` (`commentary`, `final_answer`), `model.call_*`, `subagent.*`, `result`. |
| R6 | Result, session and cost extraction | output interpretation | `:854`, `:869-883`; Watch-Orchestrator `:102-110,151`; fake-claude `:96-110` | `result` event: `is_error`, `subtype`, `result`, `session_id`, `total_cost_usd`. | `result` event: `exitCode`, `sessionId`; text from the last agent-own `final_answer`; no cost. |
| R7 | Session resume | invocation | `--resume` `:767`, `:801`; `--name` rule `:802`; worker resume `:1041-1068`; Watch-Orchestrator `:209-224`; Run-SmokeTest `:352-367` | `--resume <id>`; `--name` always sent. | `--resume <id>`; `--name` only on a fresh call, so a resumed process is found by session id in its command line. |
| R8 | Structured-output nudge | invocation | `:884-902`; fake-claude `:113-120` | Asks the model to call the `StructuredOutput` tool. | Asks for corrected JSON, quoting the validation error. |
| R9 | Sub-agent support | capability | `Format-SubAgents`; `-SubAgents` `:748-752`; `Get-SubAgentName`; prompts `{{SUBAGENTS}}`; fake-claude `:59-91`; Run-SmokeTest `:170` | `Agent` tool, `run_in_background: false`; `Task` added to the lists; events keyed by `parent_tool_use_id`. | `task` tool, `mode: "sync"`; `read_agent`, `list_agents`; no `write_agent`; events keyed by `agentId`. |
| R10 | Structured-output production and validation | capability | `:760`, `:771-773`, `:857-868`; `Get-CompactSchema:650`; README `:759-764` | Native `--json-schema`; value arrives as `structured_output`. | Local: fence stripped, `Test-Json`, parsed to a hashtable; the error text feeds the nudge. |
| R11 | Model, effort and defaults | configuration | `CopilotModel`, `DefaultSettings`, `Get-DefaultSettings`, `Resolve-AgentModel`, `Read-Plan:171-174`, `Invoke-Agent:745-746`; Plan-Tasks `:47-48`; Initialize-Project `:31`; schema `:29-32`; Test-CopilotModelSettings; Run-SmokeTest `:61-62,135-150`; README `:665-685` | `sonnet` workers and reviewers, `opus` planner, effort omitted (flag `--effort`). | `gpt-6.1-sol` everywhere, effort `high` (flag `--reasoning-effort`); effort `none` allowed. |
| R12 | Budget and cost capability | capability | `MaxBudgetUsd` `:763`; schema `:44`; README `:671`, `:840`, `:1007` | `--max-budget-usd`; client-side USD estimate returned. | No budget flag; no cost. |
| R13 | Activity and process detection | output interpretation | `Invoke-Agent` activity (`:821-836`); `Get-AgentProcesses` (`Watch-Orchestrator.ps1:203-229`); `:312`; `Invoke-Orchestrator.ps1:121,287` | `claude.exe`, matched by `--name orch:...`. | `copilot.exe`, matched by `--name` or by `--resume` plus session id. |
| R14 | Validation and enumeration of provider names | configuration | Every `ValidateSet('Claude','Copilot')` (`Orchestrator.psm1:38,117,156,665,736`; `Initialize-Project.ps1:20`; `Invoke-Orchestrator.ps1:21`; `Plan-Tasks.ps1:30`; `Watch-Orchestrator.ps1:26`; `Install-Orch.ps1:31`; `Run-SmokeTest.ps1:13`; `New-PracticeRepo.ps1:22`); `@('Claude','Copilot') -eq` (`Plan-Tasks.ps1:113`, `Install-Orch.ps1:48`); `Read-Plan:171`; schema enum; help text; README and skills | Fixed list of two. | Fixed list of two. |

Observations from the table (what the code shows):

- The `-eq 'Copilot'` / `-eq 'Claude'` branches sit in a few functions: `Get-DefaultSettings`, `Resolve-AgentModel`, `Resolve-AgentPath`, `Read-Plan`, `Format-SubAgents`, `Invoke-Agent`, `Sync-WithIntegration`, `Get-AgentProcesses`, plus `Plan-Tasks.ps1:47-48` and `Initialize-Project.ps1:31`. `Invoke-Agent` alone holds R3 to R10 and R13 in one function of about 170 lines (`:729-902`).
- `ValidateSet('Claude','Copilot')` appears on 12 parameters: 5 in `Orchestrator.psm1` (`Get-DefaultSettings`, `Resolve-AgentPath`, `Read-Plan`, `Format-SubAgents`, `Invoke-Agent`) and 7 in scripts and tests (`Initialize-Project`, `Invoke-Orchestrator`, `Plan-Tasks`, `Watch-Orchestrator`, `Install-Orch`, `Run-SmokeTest`, `New-PracticeRepo`).
- The watch views (Conversations, Timeline, the Orchestrator activity pane) take no `-Provider` for event parsing; they accept both shapes.
- Claude vocabulary is the neutral vocabulary today: `allowedTools`, `permissionMode`, `Task` and rules such as `Bash(git add *)` are Claude names that the Copilot branch translates (R4).

Interpretations (not tested): a third event shape would need a branch in each watch script unless events are normalised once when written; a provider with no CLI has no process to detect (R13), no `--resume` (R7) and no native structured output (R10), so those would become capability flags.

## Affected tests and docs

"Asserts" is what the file checks or says today. All were read statically; none was run for this inventory.

### Tests

| File | Asserts or names | Responsibilities |
| --- | --- | --- |
| tests/Run-SmokeTest.ps1 | Requires `-Provider Claude\|Copilot`. Whole flow with the fake agent: bootstrap, plan, run, review, resolver, retry, resume, analysis mode. Copilot plan uses `gpt-6.1-sol`; model and effort flags per role; `--name` values; sub-agent prompt text per provider; skills blocked; `orch` provider resolution text; Copilot long prompt on stdin; Copilot effort kept on retry and resume; Claude-format UTF-8 events. README names it as the guard for both providers. | R2, R3, R4, R7, R9, R11, R13, R14 |
| tests/fake-claude.ps1 | The fake agent for both providers. Detects Copilot by `--output-format json`. Checks `--available-tools` per role, `Task` in Claude tool lists, skill blocking, `FAKE_REQUIRE_MODEL`, effort rejection, sub-agent event shapes, result shapes and nudge prompt text. Its name and temp folder `fake-claude` are referenced from Run-SmokeTest, New-PracticeRepo and Test-CopilotModelSettings. | R3, R4, R5, R6, R8, R9, R10 |
| tests/Test-CopilotModelSettings.ps1 | Copilot and Claude model and effort defaults, overrides, cross-provider plans, flags `--reasoning-effort` vs `--effort`, invalid effort, CLI rejection, tasks schema accepts null effort. | R2, R3, R11 |
| tests/New-PracticeRepo.ps1 | `-Provider` ValidateSet, default Claude; builds the practice repo with `fake-claude.ps1`. | R14, R3 |
| tests/Test-AnalysisSkills.ps1 | Static skill-text contracts for analyze, auto-analyze, write-spec-analyze, orch, plan-tasks, write-spec. No provider word found by grep, so it asserts no `-Provider` value. | none |

### Skills

| Skill | Provider content | Responsibilities |
| --- | --- | --- |
| .claude/skills/orch/SKILL.md | Resolution order, per-provider defaults, report of the provider. | R2, R11 |
| .claude/skills/plan-tasks/SKILL.md | Resolution order, `provider` field in tasks.json and project.json, `-Provider <Claude\|Copilot>` commands, Copilot effort rules, permission setup for both CLIs. | R2, R11, R14 |
| .claude/skills/write-spec/SKILL.md | "Claude or Copilot" worker text, Copilot permission setup, `Plan-Tasks.ps1 -Provider <Claude\|Copilot>`, "Ask which provider to use". | R2, R14 |
| .claude/skills/auto-develop, analyze, auto-analyze, write-spec-analyze (`SKILL.md`) | No provider words (grep). They inherit provider behaviour from `orch` and `write-spec`; a later spec that adds a provider to the request flow must still name them. | R2 (indirect) |

### Docs and other files

| File | Provider content | Responsibilities |
| --- | --- | --- |
| README.md | Install, login, provider choice, settings table, script parameter table, tool mapping, cost, structured output (see Inventory). Largest doc surface. | R1, R2, R3, R4, R6, R10, R11, R12, R13, R14 |
| docs/copilot-cli-notes.md | Copilot model and effort, tool mapping, sub-agent events, CLI location. A neutral reference would sit beside it. | R1, R4, R5, R9, R11 |
| docs/claude-cli-notes.md | Claude CLI notes; no provider-switch content. | R3 |
| docs/claude-fable-notes.md | One example command with `-Provider Claude` (`:70`). | R14 |
| docs/analysis-mode.md | Skill restrictions for both providers (`:61-66`). | R3 |
| docs/orchestrator-from-any-repo.md | Design note for `orch`; provider from `project.json`; skill folders for both CLIs. | R2 |
| docs/orchestrator-from-any-repo-progress.md | Progress log with provider-order and watch-view text. Historical. | R2, R13 |
| orchestrator/schemas/tasks.schema.json | `provider` enum, model and budget descriptions. A schema change is a contract change for existing plans; plans without `provider` fall back to Claude (`Read-Plan:171`). | R14, R11, R12 |
| Install-Orch.ps1 | `-Provider` ValidateSet, `ORCH_PROVIDER`, per-CLI skill folders, `~\.claude\settings.json` edit. | R2, R14, R3 |
| orchestrator/Orch.psm1 | Provider resolution and its error text. | R2 |

### Limits of this inventory

- Static reading only. Claude Code and Copilot CLI flags and event shapes were not re-checked live; descriptions come from the code and the repo's own notes (`docs/copilot-cli-notes.md`, README) and are untested here.
- `docs/orchestrator-from-any-repo-progress.md` (about 84 hits) was sampled by line ranges, not read in full. `docs/claude-cli-notes.md`, `docs/electron-notes.md` and the body of `Test-AnalysisSkills.ps1` were searched by keyword only.
- Line ranges come from `grep -n` and `sed` output of this tree; ends of ranges such as `Test-CopilotModelSettings.ps1:138-186` and `Orchestrator.psm1:1041-1068` are approximate bounds around the hits.
- Orchestrator files other than those listed (for example `Show-Tasks.ps1`, `Wait-Orchestrator.ps1`) were searched by keyword for `claude|copilot|provider` and had no hits.
