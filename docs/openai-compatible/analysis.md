# OpenAI-compatible API provider: analysis and recommendation

Date: 2026-10-28. Inputs: [provider-coupling.md](provider-coupling.md) (inventory, ids R1-R14),
[endpoint-findings.md](endpoint-findings.md) and [evidence/](evidence/), and the code on this
branch. Every input claim this report relies on was re-checked against the code; line numbers
are those of this tree. The implementation spec built from this report is
[docs/specs/openai-compatible-provider.md](../specs/openai-compatible-provider.md).

New observations made for this report (all 2026-10-28, Windows 11, PowerShell 7.6.9):

| Id | Observation | How |
| --- | --- | --- |
| O1 | Ollama 0.40.12 lists `huihui_ai/gemma-4-abliterated:26b` (17 GB) and `:31b-v2` (19 GB). `ollama show` for the 26b: context length 262144, capabilities `completion, vision, tools, thinking`, thinking levels `false, true`. | `ollama --version`, `ollama list`, `ollama show` |
| O2 | The loaded 26b model runs with `context_length: 4096` (`GET /api/ps`), far below its 262144 maximum. `size_vram` is 13.6 GB of 18.1 GB. | `Invoke-RestMethod http://localhost:11434/api/ps` |
| O3 | Ollama documents a 4096-token default context, the `OLLAMA_CONTEXT_LENGTH` server variable, and "Tasks which require large context like web search, agents, and coding tools should be set to at least 64000 tokens". The OpenAI-compatible API "does not have a way of setting the context size". | <https://docs.ollama.com/faq>, <https://docs.ollama.com/context-length>, <https://docs.ollama.com/api/openai-compatibility> |
| O4 | Ollama's compatibility page says `reasoning_effort` takes "model-defined names and compatibility aliases"; `/api/show` gives each model's supported values. | <https://docs.ollama.com/api/openai-compatibility> |
| O5 | OpenAI Chat Completions: `max_tokens` is "deprecated in favor of `max_completion_tokens`, and is not compatible with o-series models". | <https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create> |
| O6 | A `System.Net.HttpListener` on `http://127.0.0.1:<random port>/` started without admin rights and answered an `Invoke-RestMethod -NoProxy` call from a thread job. So a local fake endpoint is feasible in tests. | inline PowerShell, non-admin session |
| O7 | `.orchestrator/` is excluded from git by `Initialize-RunDir` (`orchestrator/Orchestrator.psm1:88-95`), so `tasks.json` and `project.json` are repo-local but **not committed**. The spec's phrase "committed plan or project settings" does not match the code; this report treats them as repo-local, git-excluded files. | code |

## Summary

- **Recommendation: approach A, a built-in agent loop owned by the orchestrator, run as its
  own child process** (`pwsh -File orchestrator/providers/OpenAICompatible/Invoke-AgentLoop.ps1`).
  It speaks Chat Completions to any endpoint, implements six tools in PowerShell, writes the
  orchestrator's canonical event stream, keeps session files for resume, and validates the
  structured result itself. It is the only approach whose core facts were verified on all
  three example endpoints (Ollama live, OpenAI and Anthropic from docs) and that needs no new
  runtime dependency.
- **One generic provider, `OpenAICompatible`.** OpenAI, Anthropic and Ollama are endpoint
  profiles in a user-level JSON file. Every per-endpoint difference found in the evidence is
  a profile field or capability flag; the rest are listed limitations. A fourth endpoint is
  one more profile.
- **Providers become modules.** `orchestrator/providers/<Name>.psm1` holds one provider
  definition (operations as scriptblocks plus capability flags). A registry discovers the
  files, so no script lists provider names. Claude and Copilot move behind the same contract
  first, guarded by the existing smoke tests, before the new provider is added.
- **One event format.** Invoke-Agent writes canonical events (the `assistant` / `user` /
  `result` / `system` subset Claude Code already emits). Copilot's events are translated by
  its module. The watch views then read one shape only.
- **Secrets**: profiles hold the *name* of an environment variable, never a key. Keys stay
  out of every file, prompt, command line and log, and out of the environment of commands
  the agent runs.
- **Biggest risks**: weak local models in long tool loops (untested beyond single calls),
  and Ollama's 4096-token runtime context on this PC (O2), which silently cuts agent prompts
  unless the server is started with a larger `OLLAMA_CONTEXT_LENGTH`.

## Execution approaches

The approaches are those of spec 4.1, assessed in
[endpoint-findings.md "Harness candidates"](endpoint-findings.md). A is split into A1
(loop inside the orchestrator's worker thread) and A2 (the same loop as a child process),
because the difference matters for the gates.

| Criterion | A1 built-in loop, in-process | A2 built-in loop, child process | B1 Codex CLI | B2 OpenCode | C Claude Code via `ANTHROPIC_BASE_URL` | D Copilot CLI BYOK |
| --- | --- | --- | --- | --- | --- | --- |
| Fit with gates (owns, acceptance, review, resume, structured result, nudge, stop, heartbeat) | All under own control; but a hung HTTP call blocks the worker thread, and `Stop-Job` on interrupt (`Invoke-Orchestrator.ps1:286-289`) cannot reliably end it | All, and it plugs into Invoke-Agent's existing process contract: prompt on stdin, JSON lines on stdout, exit code, `--resume`, `--name` (`Orchestrator.psm1:800-843`). Process detection keeps working (`Watch-Orchestrator.ps1:203-231`) | JSONL events, `--output-schema`, `exec resume` per docs; all untested. Events need a translator | `--format json`, `--session`; no structured-result flag found in the docs read; untested | Works end to end against Ollama (3 probe runs). Resume, `--json-schema`, edit tools untested there. Cost is invented, so budget is meaningless | Untested; `copilot` not installed |
| New code the orchestrator owns | Most: HTTP client, loop, six tools, session store, validation | Same as A1, plus a small argument parser | Translator, config writer | Translator, config writer | Almost none (Claude provider plus environment) | Little (Copilot provider plus config) |
| External dependency | None | None (uses the running `pwsh`) | New binary or npm package | New binary or npm (Node) | None for Ollama; a translating proxy for OpenAI-dialect endpoints (untested) | Copilot CLI and its account |
| Covers all three endpoints as one generic provider | Yes, Chat Completions is the common subset | Yes | Doubtful: docs show `wire_api = "responses"`; Anthropic's compat layer has no Responses API; chat wire API not verified | By docs (`@ai-sdk/openai-compatible`) | No: Anthropic dialect only; OpenAI needs a proxy | Docs show `type: openai` with `baseUrl`; untested |
| Weak local models | Own guards possible: turn limit, invalid-argument recovery, output-limit detection, tool output truncation, a small tool set | Same | Unknown; large system prompts | Unknown | Large prompts (about 3.2k input plus 3.4k cache tokens for a two-turn run), many tools, 335 `thinking_tokens` events in one run | Unknown |
| Testability with a fake endpoint, no network | Good (fake HTTP server, O6) | Good, and the loop can also be tested alone | Needs the binary installed in CI | Same | Needs the Claude CLI; a fake Anthropic server is extra work | Needs the CLI |
| Security of tool execution | Own path confinement; read-only roles get only read tools; commands run in the worktree | Same, plus the loop can strip key variables from command environments | `--sandbox` modes (docs) | Permission config (docs, not read) | Claude's permission system (tested read-only set) | Not checked |
| Tested on this PC | API facts only (Ollama live) | API facts only | No | No | Yes, 3 runs | No |

**Recommendation: A2.** Reasons:

1. It is the only option that is one generic provider for all three endpoints on verified
   facts: Ollama tool calls, tool round trip and `json_schema` worked live
   (endpoint-findings "Ollama (live)"); OpenAI and Anthropic document Chat Completions tool
   calling (endpoint-findings "OpenAI", "Anthropic"). B1 depends on the Responses API, which
   Anthropic's layer lacks; C depends on the Anthropic dialect.
2. It keeps every gate without workarounds. As a child process it looks to Invoke-Agent like
   a CLI harness, so stdin, the event stream, exit code, `--resume`, `--name`, the stop file
   (checked between sessions, `Orchestrator.psm1:887-888,998,1037`) and the heartbeat work
   the same way, and the watch dashboard still finds the process.
3. No new runtime dependency, matching spec section 7.
4. Endpoint deviations become data: the loop sends only fields that a profile enables.
5. Cost: the largest amount of new code. This is accepted because the user asked for a
   first-class design, and the code is testable offline (O6).

Rejected: A1 for interrupt and isolation reasons; B1 and B2 for an unverified, uninstalled
dependency and a second event schema; C because it is not an OpenAI-dialect provider and
fabricates cost (endpoint-findings, `costBasis: "unknown"`); D because it is untested and
ties the generic provider to a Copilot account.

Untested claims under this recommendation: **[U1]** reliability of a local model over long
tool loops; **[U2]** `response_format` combined with `tools` on one endpoint; **[U3]** the
in-process alternative's interrupt behaviour was not measured (A1 rejection rests on code
reading).

## Provider abstraction

### Shape

- A provider is a file `orchestrator/providers/<Name>.psm1`. It sets `$script:Definition`
  and exports nothing. The registry imports each file with `Import-Module -PassThru` and reads
  the definition with `& $module { $script:Definition }` (the same module-scope call
  `tests/Run-SmokeTest.ps1:96` already uses). Scriptblocks defined in a module stay bound to
  it, so they can call the module's private helpers, and two providers never clash on
  function names.
- The provider name is the file's base name. Adding a provider means adding one file (plus,
  for endpoint-based providers, configuration). No script has a provider list.
- Invoke-Agent keeps its parameters but loses every `$Provider -eq` branch: it calls the
  operations below.

### Operations

| Operation | PowerShell signature | Returns | Responsibility |
| --- | --- | --- | --- |
| `GetCapabilities` | `param([string]$Endpoint)` | hashtable of flags (next table) | R9, R10, R12, R13 |
| `Resolve` | `param([string]$Endpoint)` | `[pscustomobject]@{ FilePath = [string]; PrefixArgs = [string[]] }`; throws when not found | R1 |
| `GetDefaults` | `param([string]$Endpoint)` | `@{ planner; worker; reviewer; bootstrap; effort }` (strings or `$null`) | R11 |
| `NewInvocation` | `param([hashtable]$Request)` | `[pscustomobject]@{ Arguments = [string[]]; Prompt = [string] }` | R3, R4, R7, R10 |
| `ConvertEvent` | `param([Collections.IDictionary]$StreamEvent, [hashtable]$StreamState)` | zero or more canonical events | R5, R6 |
| `GetNudgePrompt` | `param([string]$SchemaError)` | `[string]` | R8 |
| `GetSubAgentText` | `param([ValidateSet('worker', 'planner')][string]$Role)` | `@{ TOOL; FOREGROUND }`, or `$null` when there are no sub-agents | R9 |
| `TestReady` | `param([string]$Endpoint, [string[]]$Models)` | `[string[]]` problems; empty means ready | R1, R11 |
| `GetEndpoints` | `param()` | `[pscustomobject[]]` with `Name, BaseUrl, Model, IsDefault`; empty for providers without endpoints | R2 |

Plain fields: `Name`, `UsesEndpoint` (bool), `Install = @{ SkillFolder; SettingsFile }`
(paths under `$HOME` or `$null`; R1/R3 entries of `Install-Orch.ps1:67-100`).

`$Request` keys: `Prompt, Schema, SchemaJson, Model, Effort, PermissionMode, Tools,
AllowedTools, SubAgents, MaxBudgetUsd, ResumeSessionId, Name, AdditionalDirectories,
Endpoint, WorkDir`. Tool names stay the orchestrator's vocabulary (`Read, Edit, Write, Glob,
Grep, Bash, PowerShell, Task` and rules like `Bash(git add *)`); each provider maps them.

### Capability flags

| Flag | Meaning | Claude | Copilot | OpenAICompatible |
| --- | --- | --- | --- | --- |
| `NativeStructuredOutput` | The result event carries `structured_output`; otherwise core validates the result text (today's Copilot path, `Orchestrator.psm1:857-865`) | true (`--json-schema`) | false | true (the loop validates) |
| `SubAgents` | A sub-agent tool exists | true | true | false |
| `CommandRules` | Accepts rules with arguments such as `Bash(git add *)` (`Orchestrator.psm1:959-960`) | true | false | true (loop matches commands with `-like`) |
| `Cost` | `total_cost_usd` is a real cost | true | false | false |
| `Budget` | Enforces `maxBudgetUsd` | true | false | false |
| `Effort` | Passes effort to the model | true | true | profile `capabilities.reasoningEffort` |
| `Resume` | Can continue a session | true | true | true (session file) |
| `CanonicalEvents` | Raw output already is the canonical event format | true | false | true |
| `ProcessName` | Executable name for the dashboard (`Watch-Orchestrator.ps1:206`) | `claude.exe` | `copilot.exe` | `pwsh.exe` |
| `ResumeOmitsName` | A resumed process has no `--name`; match it by session id (`Watch-Orchestrator.ps1:209-224`, `Orchestrator.psm1:797`) | false | true | false |

### How each provider fills the operations

| Operation | Claude | Copilot | OpenAICompatible |
| --- | --- | --- | --- |
| `Resolve` | Today's lookup: `claude` on PATH, VS Code extension binary (`Orchestrator.psm1:121-140`) | `copilot.exe`, `copilot` outside the chat shim, extension, managed folder (`:121-147`) | `$PSHOME/pwsh(.exe)` with `-NoProfile -NonInteractive -File <loop script>` |
| `GetDefaults` | planner `opus`, others `sonnet`, effort `$null` (`Plan-Tasks.ps1:47-48`, `Initialize-Project.ps1:31`, `Orchestrator.psm1:17-19`) | all `gpt-6.1-sol`, effort `high` (`Orchestrator.psm1:8,40-44,174,746`) | profile `model`, `reviewModel`, `plannerModel` (fall back to `model`), profile `effort` |
| `NewInvocation` | Today's args (`Orchestrator.psm1:754-768`): stream-json, auto memory off, denied MCP servers and skills, `--json-schema`, `--model`, `--effort`, `--permission-mode`, tool lists, `--max-budget-usd`, `--resume`, `--name` | Today's args (`:771-797`): schema in prompt, `--output-format json --allow-all-tools`, tool-name mapping, `--excluded-tools=skill`, `--name` only when fresh | GNU-style loop flags: `--endpoint`, `--model`, `--effort`, `--tools`, `--allowed-commands`, `--add-dir`, `--schema-file`, `--resume`, `--name`. `Task` is dropped (no sub-agents) |
| `ConvertEvent` | Identity | Translates `tool.execution_*`, `assistant.message`, `subagent.*`, `model.call_*`, `result` into canonical events; buffers the agent's own `final_answer` (`:821-823`) as the result text | Identity (the loop writes canonical events) |
| `GetNudgePrompt` | "…calling the StructuredOutput tool…" (`:895`) | "Your previous JSON did not match the schema: <error>…" (`:895`) | "…did not match the schema: <error>. Call the StructuredOutput tool (or return the JSON) now." The mode text comes from the profile's `structuredOutput` value, not a vendor name |
| `GetSubAgentText` | `the Agent tool`, `run_in_background: false` (`:668-669`) | `the task tool`, `mode: "sync"` | `$null`, so `{{SUBAGENTS}}` becomes empty |
| `TestReady` | none (empty) | none | `GET {baseUrl}/models` when `listModels`; reports models the run needs that the endpoint does not list |
| `GetEndpoints` | empty | empty | profiles of the endpoints file |
| `Install` | `.claude/skills`, `.claude/settings.json` | `.copilot/skills`, `$null` | `$null`, `$null` |

### Canonical event format

Interpretation from the inventory (R5): the watch views already accept Claude's shape
(`Watch-Orchestrator.ps1:89-96`, `Watch-AgentTimeline.ps1:121-145`, `Watch-Conversations.ps1:62,82`)
and the Copilot shape side by side. Making Claude's subset the one canonical format, and
translating Copilot once at write time, removes the Copilot branches from four places
(`Invoke-Agent`, `Get-SubAgentName`, three watch scripts) and fixes the gap where the
dashboard's review feedback only reads Copilot logs (`Watch-Orchestrator.ps1:118-134`). The
loop adds two optional event kinds the timeline already shows for Copilot: model call start
and end (`Watch-AgentTimeline.ps1:66-79`), as `system` events. The exact format is in the
implementation spec, section 4.3.

### The built-in loop (OpenAICompatible)

- Tools sent to the model use the orchestrator's names and Claude-style inputs, so
  `Format-ToolUse` (`Orchestrator.psm1:674-699`) formats them unchanged: `Read{file_path,
  offset, limit}`, `Glob{pattern}`, `Grep{pattern, path, glob}`, `Edit{file_path, old_string,
  new_string}`, `Write{file_path, content}`, `PowerShell{command, timeout_sec}`, plus
  `StructuredOutput` when the profile's mode is `tool`.
- Paths are resolved and must lie in the working folder or an `--add-dir` folder. Read-only
  roles (reviewer, planner) get only `Read, Glob, Grep`, enforced by the loop itself.
- `PowerShell` runs `pwsh -NoProfile -NonInteractive -Command` in the working folder, with a
  timeout, and without the profile's key variables in its environment.
- Ends when a reply has no tool calls (or calls `StructuredOutput`). Limits: `maxTurns`,
  `maxOutputTokens`, `maxToolOutputChars`. A reply with empty content and
  `finish_reason: length` is an error, not an answer (endpoint-findings, "Observations that
  matter").
- Never sends `tool_choice`, `strict`, `n`, `temperature` or `stream` unless a profile's
  `extraBody` adds them: Anthropic's layer errors on forced tool use for several models and
  limits `temperature` (endpoint-findings "Anthropic").
- Session file: `<main checkout>/.orchestrator/sessions/<session-id>.json` (messages only),
  found through `git rev-parse --git-common-dir`, so a worktree's session survives a paused
  run and is archived with the run.

## Refactoring plan

Each step keeps `.\tests\Run-SmokeTest.ps1 -Provider Claude` and `-Provider Copilot` green.
"Guard" names the existing test that must still pass; "new" marks a test the spec adds where
no existing test covers the change.

| Step | Change | Inventory entries replaced | Guard |
| --- | --- | --- | --- |
| 1 | Add the registry (`Get-OrchProvider`, `Get-OrchProviderNames`, `Resolve-OrchProviderName`) and the definition contract in `Orchestrator.psm1`; create `providers/Claude.psm1` and `providers/Copilot.psm1` with capability flags only | none yet (foundation) | Run-SmokeTest (both); new `tests/Test-ProviderRegistry.ps1` |
| 2 | Move argument building and tool mapping into `NewInvocation`: Claude args, Copilot args, tool mapping, skill/MCP denial, `--name` rule | `Orchestrator.psm1:12,15,729-736,754-797`; R3, R4, R7 parts | Run-SmokeTest "agent roles receive configured flags", "headless agents cannot start skills", "long Copilot prompt uses stdin", "reference directory passed to agents"; fake-claude role checks (`tests/fake-claude.ps1:47-67`) |
| 3 | Move defaults into `GetDefaults`; `Get-DefaultSettings`, `Resolve-AgentModel`, `Read-Plan` effort fill, `Plan-Tasks`/`Initialize-Project` role defaults call it | `Orchestrator.psm1:8,17-52,171-174,737-746`; `Plan-Tasks.ps1:47-48`; `Initialize-Project.ps1:31`; schema text `:29-32`; R11 | `tests/Test-CopilotModelSettings.ps1` (all cases); Run-SmokeTest model flags and "Copilot plan did not use GPT-6.1 Sol defaults" (`:61-62`) |
| 4 | Move discovery into `Resolve`; core keeps `-AgentPath`, then `ORCH_<NAME>` | `Orchestrator.psm1:116-149`; `Invoke-Orchestrator.ps1:66`; `Plan-Tasks.ps1:77`; `Initialize-Project.ps1:92`; R1 | Run-SmokeTest (all calls use `-AgentPath`). PATH and extension fallbacks have no test today; manual check |
| 5 | Canonical events: Invoke-Agent writes `ConvertEvent` output to `.events.jsonl` (raw to `.raw.jsonl` when `CanonicalEvents` is false) and parses only canonical events; Copilot translator; `Get-SubAgentName` and `Format-ToolUse` read canonical only; watch scripts drop Copilot event types; review feedback reads `result.structured_output` | `Orchestrator.psm1:674-717,806-883`; `Watch-Orchestrator.ps1:74-95,102-110,128,151`; `Watch-Conversations.ps1:60-96`; `Watch-AgentTimeline.ps1:63-140`; R5, R6 | Run-SmokeTest "watch views label sub-agents", "only the last result ends a session", "agent output read as UTF-8", "orchestrator exit code 0" |
| 6 | Structured output and nudge through `NativeStructuredOutput` and `GetNudgePrompt` | `Orchestrator.psm1:760,771-773,855-868,884-902`; R8, R10 | Run-SmokeTest "missing result recovered by nudge" (`FAKE_NO_STRUCTURED`); fake-claude nudge triggers (`:113-121`) |
| 7 | Sub-agent text through `GetSubAgentText`; `-SubAgents` adds `Task` only when `SubAgents` is true | `Orchestrator.psm1:662-672,747-751`; prompts `{{SUBAGENTS}}`; R9 | Run-SmokeTest "prompts explain sub-agents"; fake-claude Task checks (`:59-67`) |
| 8 | Resolver tools from `CommandRules`; budget and cost from `Budget`/`Cost` with a start-of-run warning | `Orchestrator.psm1:959-960,763-766,879`; schema `:44`; R4, R12 | Run-SmokeTest "conflict was resolved", fake-claude resolver tool check (`:54`); new registry test for the budget warning |
| 9 | Process detection from `ProcessName` and `ResumeOmitsName` | `Watch-Orchestrator.ps1:203-231,312`; `Invoke-Orchestrator.ps1:121,287`; R13 | Run-SmokeTest "orch watch uses the plan provider" (label "Live X CLI processes" kept) |
| 10 | Names: remove all 12 `ValidateSet('Claude','Copilot')`, the two re-casing lines and the schema enum; validate through the registry; add `-Endpoint` plumbing and `orch providers`; `Resolve-OrchProvider` validates | `Orchestrator.psm1:38,117,156,665,736`; `Initialize-Project.ps1:20`; `Invoke-Orchestrator.ps1:21`; `Plan-Tasks.ps1:30,113,154-163`; `Watch-Orchestrator.ps1:26`; `Install-Orch.ps1:31,48`; `Run-SmokeTest.ps1:13`; `New-PracticeRepo.ps1:22`; `tasks.schema.json:20-23`; `Orch.psm1:5-9,161-178,210-217`; R2, R14 | Run-SmokeTest "orch watch uses the plan provider", "orch plan takes project.json provider", "orch run takes the plan provider" (`:461-473`); Test-CopilotModelSettings cross-provider cases (`:127-133`); new registry test for unknown names |
| 11 | `Install-Orch.ps1` links skills to each provider's `Install.SkillFolder` and allows directories in its `Install.SettingsFile` | `Install-Orch.ps1:14-26,47-55,67-100`; R1, R2, R3 | none exists; manual `Install-Orch.ps1 -WhatIf` |
| 12 | Smoke test per provider: provider-specific assertions move from `Run-SmokeTest.ps1` into fixtures `tests/providers/<Name>.ps1`; generic checks that need sub-agents run only when `SubAgents` is true | `Run-SmokeTest.ps1:19-20,52-99,135-150,170,207,214-215,237,352-367`; `New-PracticeRepo.ps1:27,51`; `Test-CopilotModelSettings.ps1:28-186` | the smoke tests themselves, both providers |
| 13 | Add `providers/OpenAICompatible.psm1`, the loop, the endpoints schema, the fake endpoint, its fixture and tests. No core file changes | new | new `tests/Test-OpenAICompatible.ps1`; `Run-SmokeTest.ps1 -Provider OpenAICompatible` |
| 14 | README, `docs/openai-compatible-notes.md`, `docs/analysis-mode.md:61-66`, skills `orch`, `plan-tasks`, `write-spec`; the four wrappers stay provider-free | README rows in the inventory; skills rows; docs rows | `tests/Test-AnalysisSkills.ps1` (extended) |

Entries deliberately left: `prompts/planner.md:12` (a sentence, not a branch);
`Clear-Orchestrator.ps1:47` (neutral); `docs/orchestrator-from-any-repo*.md`,
`docs/claude-fable-notes.md:70` (historical records and one valid example);
`docs/dotnet-notes.md` (false positives); `tests/fake-claude.ps1:7` (a test double may
recognise the CLI it imitates). `Orch.psm1:113` describes Claude Code session variables of the
*chat* shell, which are stripped for every provider; it stays.

## Configuration

### Fields

| Field | Required | Default | Lives in | Notes |
| --- | --- | --- | --- | --- |
| Provider name | yes | `ORCH_PROVIDER` | `-Provider`; `tasks.json` `provider`; `project.json` `provider`; user env `ORCH_PROVIDER` | Unchanged resolution order (`Orch.psm1:161-178`), now validated |
| Endpoint profile name | for `OpenAICompatible` | profile file `default` | `-Endpoint`; `tasks.json` `endpoint`; `project.json` `endpoint`; user env `ORCH_ENDPOINT`; then the file's `default` | Same order as the provider, so `orch run` reuses the plan's endpoint |
| `baseUrl` | yes | none | profile | e.g. `http://localhost:11434/v1` |
| `dialect` | no | `chat-completions` | profile | Only value in v1; a new dialect is new code, a new vendor is not |
| `apiKeyEnv` | no | `null` (no auth header) | profile holds the variable **name**; the value lives in the environment (process, else User) | Ollama needs none (endpoint-findings) |
| `authHeader`, `authScheme` | no | `Authorization`, `Bearer` | profile | Covers `api-key`-style headers with `authScheme: ""` |
| `headers`, `headersFromEnv` | no | none | profile (non-secret values; secret ones by env var name) | e.g. `anthropic-workspace-id` |
| `model`, `reviewModel`, `plannerModel` | `model` yes | `reviewModel` and `plannerModel` fall back to `model` | profile; overridden per run by `tasks.json` `settings.model`, `settings.reviewModel`, task `model` | |
| `effort` | no | `null` | profile; overridden by `tasks.json` `settings.effort` | |
| `requestTimeoutSec` | no | 600 | profile | Local reasoning models are slow (9.3 s for one short chat, endpoint-findings) |
| `maxOutputTokens`, `maxTokensParameter` | no | 8192, `max_tokens` | profile | `max_completion_tokens` for OpenAI (O5) |
| `maxTurns`, `maxToolOutputChars`, `retries` | no | 60, 30000, 2 | profile | Spend and context guards |
| `extraBody` | no | none | profile | Merged into every request; the escape hatch for endpoint-only parameters; never secrets |
| `capabilities.structuredOutput` | no | `tool` | profile | `tool`, `json_schema`, `json_object`, `prompt` |
| `capabilities.reasoningEffort`, `capabilities.effortMap` | no | false, none | profile | Map orchestrator levels to endpoint values |
| `capabilities.listModels` | no | true | profile | Pre-flight `GET /models` |

### Where the profiles live: one user-level file

**Recommendation:** `[Environment]::GetFolderPath('ApplicationData')/AgentOrchestration/endpoints.json`
(on Windows `%APPDATA%\AgentOrchestration\endpoints.json`), overridable by the environment
variable `ORCH_ENDPOINTS_FILE`. The repo-local `tasks.json` and `project.json` record only
the provider and profile *names*. Keys live only in environment variables.

Why this beats a git-ignored file in the repo:

- The orchestrator works on many target repos, including new blank ones that have no
  `.gitignore` yet; a repo file can be committed by accident. A user file is outside every repo.
- Task worktrees are fresh checkouts (`New-TaskWorktree`), so an ignored file in the main
  checkout is not in them; the loop would need a path back anyway.
- Endpoint facts are per PC: `localhost` URLs and the installed Ollama models differ between
  the user's PCs; keys are per PC too. `ORCH_PROVIDER` is already a per-PC user variable
  (`Install-Orch.ps1:47-55`).
- One file serves every repo; a per-repo copy drifts.
- Repo-local per-run choice is still possible: the profile name sits in `tasks.json` and
  `project.json`, which are git-excluded (O7).

CLAUDE.md's rule against per-machine stores is about knowledge. The committed knowledge here
is the example profiles in `docs/openai-compatible-notes.md`, which every PC copies from.

### Keeping secrets out

| Place | How |
| --- | --- |
| git | No file holds a key: profiles hold variable names; `.orchestrator/` is git-excluded |
| `tasks.json`, `project.json`, `state.json` | Hold provider and profile names only |
| Command line | The loop gets `--endpoint <name>` and reads the profile itself; no URL, header or key on the command line, so the dashboard's command-line scan (`Watch-Orchestrator.ps1:216`) sees none |
| Prompts, session files | Keys never enter messages |
| `*.events.jsonl`, `.stderr`, result logs | The loop never writes request headers; HTTP error text names the variable, never its value |
| Commands the agent runs | The `PowerShell` tool's child process gets an environment without `apiKeyEnv` and `headersFromEnv` variables, so `echo $env:...` cannot leak a key into a tool result, a log or a commit |
| Tests | A dummy key value is used and every file under the run folder is scanned for it |

### Worked examples

One file, three example profiles plus a fourth added by configuration only:

```json
{
  "version": 1,
  "default": "ollama-local",
  "profiles": {
    "ollama-local": {
      "baseUrl": "http://localhost:11434/v1",
      "apiKeyEnv": null,
      "model": "huihui_ai/gemma-4-abliterated:26b",
      "requestTimeoutSec": 900,
      "maxOutputTokens": 8192,
      "capabilities": { "structuredOutput": "json_schema", "reasoningEffort": false }
    },
    "openai": {
      "baseUrl": "https://api.openai.com/v1",
      "apiKeyEnv": "OPENAI_API_KEY",
      "model": "gpt-6.1-sol",
      "maxTokensParameter": "max_completion_tokens",
      "capabilities": { "structuredOutput": "json_schema", "reasoningEffort": true }
    },
    "anthropic-compat": {
      "baseUrl": "https://api.anthropic.com/v1",
      "apiKeyEnv": "ANTHROPIC_API_KEY",
      "model": "claude-opus-5-5",
      "capabilities": { "structuredOutput": "tool", "reasoningEffort": false }
    }
  }
}
```

- Ollama: no key (endpoint-findings: "Ollama needs no auth header"); `json_schema` worked live;
  `reasoningEffort` off because this model's thinking levels are only `false, true` (O1) and
  the effect of the value was not measured. The model tag is the one tested.
- OpenAI: Bearer key from `OPENAI_API_KEY`; `max_completion_tokens` (O5). **[U4]** The model
  id `gpt-6.1-sol` is the Copilot default in `Orchestrator.psm1:8`; whether the OpenAI API
  serves it was not checked (needs a key). Replace it with an id from `GET /v1/models`.
- Anthropic: key from `ANTHROPIC_API_KEY` sent as `Authorization: Bearer` (endpoint-findings:
  "authorization: Fully supported"); `structuredOutput: tool` because `response_format` is
  ignored; model name from the Anthropic docs example. **[U5]** All behaviour beyond the 401
  shape is untested.

Run selection: `orch plan spec.md -Provider OpenAICompatible -Endpoint openai`; the plan
records both names, so `orch run` reuses them (`orch watch` needs only the provider).
`-Endpoint ollama-local` on a rerun switches the endpoint for that run.

**Fourth endpoint by configuration alone** (hypothetical "Example Server B", a local
OpenAI-compatible server on port 8000 with a key and an org header):

1. Add to `profiles` in the user file:
   ```json
   "example-b": {
     "baseUrl": "http://localhost:8000/v1",
     "apiKeyEnv": "EXAMPLE_B_KEY",
     "headers": { "X-Example-Org": "team-1" },
     "model": "example-coder-7b",
     "capabilities": { "structuredOutput": "prompt", "listModels": false }
   }
   ```
2. Set the key once: `[Environment]::SetEnvironmentVariable('EXAMPLE_B_KEY', '<key>', 'User')`.
3. Check: `orch providers` lists `example-b`.
4. Run: `orch plan spec.md -Provider OpenAICompatible -Endpoint example-b`.

No code, schema or test changes. The spec's tests prove this with a profile that exists only
in the test's endpoints file.

Azure OpenAI, vLLM and LM Studio: vLLM and LM Studio serve Chat Completions, so a profile
covers them by design (untested). Azure needs an `api-key` header (covered by `authHeader`)
and may need an `api-version` query parameter, which v1 profiles cannot express.

### Per-endpoint differences (spec 3.8)

| Difference (endpoint-findings) | Covered by |
| --- | --- |
| Base URL | `baseUrl` |
| Auth: none (Ollama), Bearer (OpenAI), Bearer plus optional `anthropic-workspace-id` (Anthropic) | `apiKeyEnv` (null = no header), `authHeader`, `authScheme`, `headers`, `headersFromEnv` |
| Model naming (`name:tag`, OpenAI ids, `claude-*`) | `model`, `reviewModel`, `plannerModel` strings |
| Responses API: OpenAI recommends it; Anthropic lacks it | `dialect: chat-completions`, the common subset |
| Structured output: works (Ollama, OpenAI); ignored (Anthropic) | `capabilities.structuredOutput`; the loop validates locally in every mode |
| `strict` ignored and forced tool choice errors (Anthropic) | The loop never sends either; arguments are validated locally |
| Reasoning effort: model-defined (Ollama), `none..max` per model (OpenAI), ignored (Anthropic) | `capabilities.reasoningEffort`, `capabilities.effortMap` |
| `max_tokens` deprecated for OpenAI reasoning models | `maxTokensParameter` |
| Reasoning text in `message.reasoning` (Ollama), not returned (Anthropic) | Ignored by the loop; no field needed |
| Streaming tool calls arrive whole (Ollama) | The loop does not stream; no field needed |
| Usage: `cached_tokens` (Ollama, OpenAI), details empty (Anthropic) | The loop reads `prompt_tokens` and `completion_tokens` only, missing = 0 |
| `temperature` limits, `n` must be 1 (Anthropic) | Not sent; `extraBody` can add |
| System messages hoisted (Anthropic) | The loop sends one system message first |
| Endpoint-only parameters (e.g. Anthropic `thinking`) | `extraBody` |
| **Limitation:** no cost field on any endpoint | Cost 0, budget not enforced (see Capability gaps) |
| **Limitation:** Ollama's context size cannot be set through the OpenAI API (O3) and is 4096 on this PC (O2) | Server setting (`OLLAMA_CONTEXT_LENGTH`); documented in the live check |
| **Limitation:** no prompt caching through Anthropic's layer | Cost and latency only |
| **Limitation:** Anthropic calls its layer a test layer, not production | Documented |

No row needs a vendor branch.

## Capability gaps

Behaviour of `OpenAICompatible` when an endpoint or model lacks a capability, and what the
user sees. "Progress" means a line in `.orchestrator/progress.md` and the console.

| Capability | Behaviour | What the user sees |
| --- | --- | --- |
| Model not served | With `listModels`, the run stops before any task starts. Without it, the first request fails with the endpoint's error | Run start: `Endpoint 'x' does not list model 'y'. It lists: a, b.` Otherwise the task fails with the HTTP status and the endpoint's message |
| Effort | `reasoningEffort: false`: not sent. `true`: sent as `reasoning_effort`, mapped through `effortMap`. A value the endpoint rejects fails the call with its message, as Copilot's CLI rejection does today (`Test-CopilotModelSettings.ps1:138-186`) | Progress, once per call: `effort 'high' not sent: endpoint profile 'x' has reasoningEffort off` |
| Budget | No endpoint reports cost, so `Budget` and `Cost` are false; `maxBudgetUsd > 0` is ignored. `maxTurns` and `maxOutputTokens` bound the spend instead; token usage goes into the result event | Run start: `maxBudgetUsd is ignored: provider OpenAICompatible reports no cost`. Costs show 0.00 USD. The same warning now also covers Copilot, which has no cap today either |
| Sub-agents | None in v1; `{{SUBAGENTS}}` is empty and `Task` is dropped from tool lists | Prompts have no sub-agent section; watch views show no `↳` lines |
| Structured output | Mode from the profile; the loop validates against the schema in every mode. Invalid: core nudges once (`GetNudgePrompt`). Still invalid: a worker continues to the gates with its text (today's behaviour, `Orchestrator.psm1:1070-1075`); planner and reviewer fail | Progress: `worker gave no structured result; continuing to the gates with its text answer`, or `Review agent failed: the run finished without a valid structured result: <schema error>` |
| Tool calling | A model that rejects `tools` fails the call (HTTP error). A model that ignores tools produces no changes; the existing gate gives feedback and retries until `maxAttempts` | Task error with the endpoint's message, or `No file changes were found on your branch` attempts, then failure |
| Output limit | Empty content with `finish_reason: length` ends the session as an error | `the model used its whole output budget (maxOutputTokens 8192) without an answer; raise maxOutputTokens or lower effort` |
| Turn limit | `maxTurns` reached ends the session as an error (subtype `error_max_turns`) | Task error naming the limit |
| Context too small | Not detectable through the OpenAI API (O3); the server may cut the prompt | Poor or off-task answers. The notes and the live check tell the user to raise the server context **[U6]** |

## Risks and untested claims

| Id | Claim the design rests on | Status | Affects | Mitigation |
| --- | --- | --- | --- | --- |
| U1 | A local model can finish real worker tasks in a multi-turn tool loop | Untested: only single-tool probes and 3 short Claude Code runs (endpoint-findings "Untested claims") | Recommendation A2 for local use; live check | Turn limit, argument-error recovery, gates and retries; the opt-in live check measures it |
| U2 | `response_format` and `tools` can be combined in one request | Untested | Mode `json_schema` | `json_schema` is applied only to a final request without tools; mode `tool` is the default |
| U3 | A1 cannot be interrupted reliably | Code reading only (`Invoke-Orchestrator.ps1:286-289`) | Choice of A2 over A1 | none needed; A2 is safer either way |
| U4 | `gpt-6.1-sol` is served by the OpenAI API | Untested (needs a key) | OpenAI example only | Example says to pick an id from `GET /v1/models` |
| U5 | Anthropic's compat layer accepts tools and Bearer auth for agent use | Docs only; 401 shape checked live | Anthropic example | Profile uses mode `tool`; documented as a test layer |
| U6 | Raising `OLLAMA_CONTEXT_LENGTH` to 65536 fits this PC's memory and keeps acceptable speed | Untested; the model is already partly outside VRAM at 4096 (O2) | Live check | Live check states the setting and the expected slowdown; the 31b model is not suggested |
| U7 | Anthropic's layer accepts `max_tokens` | Not in the docs read | Anthropic example | Default `max_tokens`; switch with `maxTokensParameter` |
| U8 | Codex, OpenCode and Copilot BYOK behave as documented | Not installed; docs only | Rejection of B and D | Rejection does not depend on them working |
| U9 | `pwsh -File` reads a piped prompt from stdin as UTF-8 for the loop | Untested here; `fake-claude.ps1` runs in-process, not as a child | A2 transport | Spec requires a test with non-ASCII text through the real child process |
| U10 | `HttpListener` on `127.0.0.1` works for every developer PC without a URL ACL | Observed on this PC only (O6) | Offline tests | Tests use `127.0.0.1` and a random free port |
| U11 | Translating Copilot events at write time keeps every watch line the smoke test checks | Design reading; smoke checks use case-insensitive matches (`Run-SmokeTest.ps1:199-202`) | Step 5 | Both smoke tests guard it |

Other limits of this report: Claude Code and Copilot CLI flags were not re-run; their
behaviour comes from the code and the repo's notes. Copilot CLI is not installed on this PC,
so its smoke run uses the fake agent only, as today.
