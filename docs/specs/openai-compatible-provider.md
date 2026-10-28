# OpenAI-compatible API provider (coding spec)

## 1. Summary

This is a **coding spec** (`workerType: coding`) for the AgentOrchestration repo. It makes
providers a first-class, pluggable concept and adds one generic provider, `OpenAICompatible`,
for any endpoint that speaks the OpenAI Chat Completions API. OpenAI, Anthropic's
compatibility endpoint and a local Ollama server are example endpoint profiles, not separate
providers. The provider runs the agent tool loop itself, in a child `pwsh` process, so every
gate keeps working. Done means: Claude and Copilot run behind the same provider contract with
unchanged behaviour, `OpenAICompatible` passes an offline smoke run against a fake endpoint,
and a further compatible endpoint can be added by editing a profile file only. The design and
its evidence are in `docs/openai-compatible/analysis.md`.

## 2. Scope

**In scope**
- A provider registry and contract; Claude and Copilot refactored into provider modules.
- One canonical agent event format for logs and watch views.
- The `OpenAICompatible` provider: endpoint profiles, the agent loop, offline tests, an opt-in
  live check against Ollama.
- User-facing changes: `-Provider` and `-Endpoint`, `orch providers`, `Install-Orch.ps1`,
  README, a docs note, skills.
- Setting up this PC: the recommended Ollama models, the user's profiles file and a live check (area 8).

**Out of scope**
- Other API dialects (Responses API, Anthropic Messages); streaming; sub-agents for
  `OpenAICompatible`; cost tracking or pricing tables.
- Calls to paid APIs in any test; installing software. Pulling Ollama models, except the two named in 8.1 by the ollama-setup module.
- Live testing against OpenAI or Anthropic. Local Ollama is the only real endpoint used during
  development. The OpenAI and Anthropic profiles are built only from their documentation, as
  cited in `docs/openai-compatible/endpoint-findings.md`. Their documented differences are
  exercised offline through the fake endpoint (6.3).
- Changing prompts other than through `{{SUBAGENTS}}`; changing the task pipeline's gates.
- Historical docs: `docs/orchestrator-from-any-repo*.md`, `docs/claude-fable-notes.md`.

## 3. Requirements

### 1. Provider registry
**Objective:** As the maintainer, I want providers discovered from files, so that adding one needs no script edits.

1.1 The provider registry shall load every `orchestrator/providers/*.psm1` file and every `*.psm1` file in the folders listed in `ORCH_PROVIDER_PATH` (separated by `;`), and use each file's base name as the provider name.
1.2 If a provider file sets no `$script:Definition` or its `Name` differs from the file's base name, the registry shall throw an error that names the file.
1.3 When a script or `orch` receives a provider name, the registry shall match it case-insensitively and return the registered name, which is what `tasks.json`, `project.json` and `ORCH_PROVIDER` store.
1.4 If a provider name is not registered, `Plan-Tasks.ps1`, `Initialize-Project.ps1`, `Invoke-Orchestrator.ps1`, `Watch-Orchestrator.ps1`, `Install-Orch.ps1`, `Read-Plan` and `orch` shall stop with `Unknown provider '<name>'. Installed providers: <names>.`
1.5 The code under `orchestrator/` outside `orchestrator/providers/`, and `Install-Orch.ps1`, shall contain no `ValidateSet` of provider names, no comparison with a provider-name literal and no provider-name list; the only provider-name literal shall be the default `'Claude'`, used where no provider is given.
1.6 The `Invoke-Agent` function shall build, run and interpret an agent call only through the operations and capability flags of section 4.3.
1.7 When a provider file is placed in a folder of `ORCH_PROVIDER_PATH`, every script shall accept its name with no other change.
1.8 When the user runs `orch providers`, the `orch` command shall list each provider with its default models and, for providers with `UsesEndpoint`, each profile's name, base URL, model and default mark, and no key value. If a provider's `GetEndpoints` or `GetDefaults` throws, for example because the profiles file is missing, it shall print the error text under that provider and continue.

### 2. Claude and Copilot behind the contract
**Objective:** As a user of the existing providers, I want unchanged behaviour after the refactoring.

2.1 The Claude and Copilot provider modules shall pass the same CLI arguments and prompt text as before the refactoring for the bootstrap, planner, worker, reviewer, resolver and nudge calls.
2.2 The `GetDefaults` operation shall return planner `opus`, worker, reviewer and bootstrap `sonnet` and effort `$null` for Claude, and `gpt-6.1-sol` for every role with effort `high` for Copilot.
2.3 When no `-AgentPath` is given, `Resolve-AgentCommand` shall use the environment variable `ORCH_<NAME>` (name in upper case) if set, else the provider's `Resolve` operation.
2.4 When `Sync-WithIntegration` starts the resolver, it shall add the rules `Bash(git add *)`, `Bash(git status *)` and `Bash(git diff *)` if the provider's `CommandRules` is true, else `Bash`.
2.5 When `maxBudgetUsd` is above 0 and the provider's `Budget` flag is false, `Invoke-Orchestrator.ps1` shall log `maxBudgetUsd is ignored: provider <name> reports no cost` once at run start.
2.6 While the provider's `SubAgents` flag is false, `Format-SubAgents` shall return an empty string and `Invoke-Agent -SubAgents` shall add no sub-agent tool.
2.7 The `Install-Orch.ps1` script shall link the skills into each provider's `Install.SkillFolder` and allow the checkout in each provider's `Install.SettingsFile`, skipping `$null` values.
2.8 The `Watch-Orchestrator.ps1` dashboard shall find agent processes by the provider's `ProcessName` and `--name orch:<task>`, and by `--resume <session id>` only where `ResumeOmitsName` is true.
2.9 When `tests/Run-SmokeTest.ps1 -Provider Claude`, `-Provider Copilot` and `tests/Test-CopilotModelSettings.ps1` run, they shall pass.
2.10 The `Run-SmokeTest.ps1` script shall take provider-specific setup and checks from `tests/providers/<Provider>.ps1` (section 4.3). It shall run every generic check except those the fixture lists in `Skip`, and run checks that need sub-agents only while the provider's `SubAgents` flag is true. The CLI-argument checks `agent roles receive configured flags`, `headless agents cannot start skills`, `long Copilot prompt uses stdin` and `reference directory passed to agents` may be skipped by a fixture whose `Checks` adds an equivalent.
2.11 When `Plan-Tasks.ps1` or `Invoke-Orchestrator.ps1` starts, it shall call the provider's `TestReady` with the models it will use and stop before any agent call if problems come back, printing each one.
2.12 The test `tests/Test-ProviderRegistry.ps1` shall have one named check each for 1.2, 1.3, 1.4, 1.5, 1.7, 1.8, 2.5, 4.4, 4.5 and 4.13, using a provider file in a temporary `ORCH_PROVIDER_PATH` folder; the 4.5 and 4.13 checks run `Install-Orch.ps1 -WhatIf` and assert that no user environment variable changed. The test shall write a temporary profiles file that is valid against the endpoints schema of section 4.3 and holds the profile name it passes to `-Endpoint`, set `ORCH_ENDPOINTS_FILE` to it in process scope and pass it as `-EndpointsFile`, so that its result does not depend on the providers registered or on files of the user.

### 3. Canonical events
**Objective:** As a user of the watch views, I want one event format, so that every provider shows up the same way.

3.1 When an agent call runs, `Invoke-Agent` shall write every event returned by the provider's `ConvertEvent` to `<LogPath>.events.jsonl` in the format of section 4.3, and the raw lines to `<LogPath>.raw.jsonl` while the provider's `CanonicalEvents` is false.
3.2 The Copilot `ConvertEvent` operation shall map tool starts and completions, commentary, final answers, sub-agent starts, model calls and the result to canonical events, with the agent's own last final answer as the `result` text and sub-agent events keyed by `parent_tool_use_id`.
3.3 The `Invoke-Agent` function, `Get-SubAgentName`, `Format-ToolUse`, `Watch-Orchestrator.ps1`, `Watch-Conversations.ps1` and `Watch-AgentTimeline.ps1` shall read only canonical events and shall not name Copilot event types.
3.4 When a review log holds a result event with `structured_output`, the dashboard's review feedback shall read the verdict from it, for every provider.
3.5 While the provider's `NativeStructuredOutput` is false, `Invoke-Agent` shall validate the result text, with a Markdown fence removed, against the schema.
3.6 When a call finishes without a valid structured result and has a session id, `Invoke-Agent` shall resume it once with the provider's `GetNudgePrompt` text.
3.7 When a canonical `system` event with subtype `warning` arrives, `Invoke-Agent` shall write its `message` to the progress file after the call's activity label.

### 4. Endpoints and configuration
**Objective:** As a user, I want endpoints described as data, so that a new endpoint needs no code and no key reaches a file.

4.1 The scripts `Plan-Tasks.ps1`, `Initialize-Project.ps1` and `Invoke-Orchestrator.ps1` shall accept `-Endpoint <name>` and pass it to every provider operation and to `Invoke-Agent`; `Invoke-Orchestrator.ps1` shall use the plan's `endpoint` when `-Endpoint` is not given and the provider's `UsesEndpoint` is true, and ignore it otherwise.
4.2 For `orch plan` and `orch run`, the `orch` command shall resolve the endpoint in the order `-Endpoint`, `tasks.json` `endpoint`, `project.json` `endpoint`, `ORCH_ENDPOINT` (process, then User scope), pass it on, and print it in its header, only while the resolved provider's `UsesEndpoint` is true; for other providers it shall resolve and pass no endpoint.
4.3 When `Plan-Tasks.ps1` plans for a provider with `UsesEndpoint`, it shall record the `-Endpoint` value it received in `tasks.json` `endpoint` and `project.json` `endpoint`, and write no `endpoint` when it received none, so that the profiles file's `default` applies at run time.
4.4 If `-Endpoint` is given explicitly on the command line for a provider whose `UsesEndpoint` is false, the scripts shall stop with `Provider <name> does not use endpoint profiles.`
4.5 When `Install-Orch.ps1 -Endpoint <name>` runs and no provider's `InitializeUser` reports a `problem`, it shall set the user environment variable `ORCH_ENDPOINT`.
4.6 The OpenAICompatible provider shall read profiles from the file named by `ORCH_ENDPOINTS_FILE`, else from `<ApplicationData>/AgentOrchestration/endpoints.json` (`[Environment]::GetFolderPath('ApplicationData')`).
4.7 If the profiles file is missing, fails `orchestrator/schemas/endpoints.schema.json`, or lacks the requested profile, the provider shall stop with an error that names the file and the problem and lists the profile names.
4.8 When no endpoint name is given or recorded, the OpenAICompatible provider shall use the file's `default`.
4.9 When a profile names `apiKeyEnv`, the agent loop shall read the key from that variable at request time, process scope first, then User scope; if it is empty, the loop shall fail with an error that names the variable.
4.10 The OpenAICompatible provider and agent loop shall write no key value to any file, prompt, command line, event or error text.
4.11 When the agent loop runs a `PowerShell` tool command, it shall remove the profile's `apiKeyEnv` and `headersFromEnv` variables from that command's environment.
4.12 The OpenAICompatible provider code (`*.ps1`, `*.psm1`) shall contain no branch on the names `OpenAI`, `Anthropic` or `Ollama`; endpoint differences shall come only from profile fields.
4.13 When `Install-Orch.ps1` runs, it shall accept `-Endpoint` and `-EndpointsFile`, call the `InitializeUser` operation (section 4.3) of every registered provider that has one, passing `Endpoint` and `EndpointsFile` only to providers whose `UsesEndpoint` is true, print each returned message with its status, set each returned `UserVariables` entry as a user environment variable through `ShouldProcess`, and exit with code 1 if any message has status `problem`.
4.14 When `InitializeUser` runs and the profiles file (`-EndpointsFile`, else 4.6) does not exist, the OpenAICompatible provider shall copy `orchestrator/providers/OpenAICompatible/endpoints.example.json` there, creating the folder, and report `changed`; it shall never overwrite an existing file, and under `WhatIf` it shall create nothing, report the file it would create and validate against the example's content.
4.15 When `InitializeUser` is given an `EndpointsFile`, the OpenAICompatible provider shall return its full path in `UserVariables` as `ORCH_ENDPOINTS_FILE`, so that one secret-free profiles file, for example in a synced folder, can serve several PCs.
4.16 If the profiles file fails `endpoints.schema.json` or lacks the profile named by `Endpoint`, `InitializeUser` shall report a `problem` that names the file and lists the profile names.
4.17 For each `apiKeyEnv` and `headersFromEnv` variable in the profiles, `InitializeUser` shall report `info` `<VAR> is set` or `warning` `<VAR> is missing (used by profile <name>)`, checking process scope, then User scope, and shall never report a value.
4.18 The file `endpoints.example.json` shall pass `endpoints.schema.json` and hold the profiles `ollama-local` (default, model `gpt-oss:20b`), `ollama-coder` (model `qwen3-coder:30b`), `openai` and `anthropic-compat`. It shall fill every field that the documentation or the live check settles, starting from the worked examples in `docs/openai-compatible/analysis.md` (Configuration), and give keys only as variable names. The OpenAI and Anthropic model ids shall come from those vendors' current model documentation, with the URLs in `docs/openai-compatible-notes.md`, and not from a request to their APIs.
4.19 While the provider's `UsesEndpoint` is true, `Plan-Tasks.ps1` shall write `settings.model` and `settings.reviewModel` to `tasks.json` only when `-WorkerModel` is given, and `settings.effort` only when `-WorkerEffort` is given. Otherwise the endpoint profile used by each run supplies them through `GetDefaults`. While `UsesEndpoint` is false, it shall write them as before.

### 5. Agent loop
**Objective:** As the orchestrator, I want a headless agent for Chat Completions endpoints that keeps every gate.

5.1 When called, the agent loop shall send `POST {baseUrl}/chat/completions` with `model`, `messages`, `tools`, the output limit under `maxTokensParameter`, `reasoning_effort` only while `capabilities.reasoningEffort` is true (mapped by `effortMap`), the auth header, `headers`, and `extraBody` merged last.
5.2 The agent loop shall not send `tool_choice`, `stream`, `n` or `temperature` unless `extraBody` adds them.
5.3 When a reply has tool calls, the agent loop shall run each, send its output as a `role: tool` message with the call's `tool_call_id`, and request again; when a reply has no tool calls, the tool loop shall end.
5.4 The agent loop shall offer only the tools named by `--tools`, out of `Read`, `Glob`, `Grep`, `Edit`, `Write` and `PowerShell`, with the inputs of section 4.3.
5.5 If a tool path resolves outside the working folder and the `--add-dir` folders, the agent loop shall return an error tool result and leave the path untouched.
5.6 While `--allowed-command` patterns are given, the agent loop shall run a `PowerShell` command only if it matches one with `-like`, else return an error tool result.
5.7 If tool call arguments are not valid JSON or name an unknown tool, the agent loop shall return an error tool result and continue.
5.8 When a tool output exceeds `maxToolOutputChars`, the agent loop shall cut it and append `[output cut at <n> characters]`.
5.9 When `--schema-file` is given, the agent loop shall obtain the result in the profile's `structuredOutput` mode (section 4.3), validate it with `Test-Json`, and put it in the result's `structured_output`, or leave that null and put the validation error in `result`.
5.10 The agent loop shall write canonical events to stdout: `model_call_start` and `model_call_end` per request, `assistant` per reply, `user` per tool result, and one `result` with `usage` summed over requests and `total_cost_usd` 0.
5.11 The agent loop shall store each session's messages in `<main checkout>/.orchestrator/sessions/<session-id>.json`, found through `git rev-parse --git-common-dir`, and when called with `--resume <id>` shall load them and append the new prompt.
5.12 If `maxTurns` requests are reached, the agent loop shall end with an `error_max_turns` result; if a reply has empty content, no tool calls and `finish_reason: length`, it shall end with `error_output_limit` and a message naming `maxOutputTokens`.
5.13 If a request fails with HTTP 429, a 5xx status, a refused connection or a timeout, the agent loop shall retry it up to `retries` times after 5 and 20 seconds; other HTTP errors shall end the session with the status and the endpoint's error message.
5.14 When the base URL host is `localhost`, `127.0.0.1` or `::1`, the agent loop shall bypass the system proxy.
5.15 While the profile's `capabilities.listModels` is true, the OpenAICompatible `TestReady` operation shall request `GET {baseUrl}/models` and return `Endpoint '<profile>' does not list model '<model>'. It lists: <ids>.` for each missing model.
5.16 While `capabilities.reasoningEffort` is false and an effort is set, the agent loop shall emit one `warning` event: `effort '<value>' not sent: endpoint profile '<name>' has reasoningEffort off`.
5.17 The agent loop shall read the prompt from stdin and write events as UTF-8, so that non-ASCII text survives the child process.

### 6. Tests
**Objective:** As the maintainer, I want offline proof of the provider and of configuration-only endpoints.

6.1 The fake endpoint `tests/fake-openai-endpoint.ps1` shall serve `GET /<profile>/v1/models` and `POST /<profile>/v1/chat/completions` on `http://127.0.0.1:<free port>` from a background runspace of the test process, script replies by the `orchestrator-role` marker like `tests/fake-claude.ps1`, and honour those `FAKE_*` variables of `tests/fake-claude.ps1` whose effect is visible in a request body or a reply (such as `FAKE_CAPTURE_ARGS` and `FAKE_NO_STRUCTURED`); variables that inspect CLI arguments (such as `FAKE_REQUIRE_ADD_DIR`, `FAKE_CHECK_SKILL_BLOCK`, `FAKE_REJECT_MODEL`) are covered by the fixture's equivalent checks instead.
6.2 If a request lacks a field or header that its profile path expects, the fake endpoint shall answer HTTP 400 with the reason; while `FAKE_CAPTURE_ARGS` is set, it shall save each request body with `role` and profile, without header values.
6.3 The test `tests/Test-OpenAICompatible.ps1` shall run every role through `Invoke-Agent -Provider OpenAICompatible` against two profiles that differ in `structuredOutput`, auth, `maxTokensParameter`, `headers` and `extraBody`, and pass.
6.4 The test `tests/Test-OpenAICompatible.ps1` shall run a third profile that exists only in the test's endpoints file, with no other change.
6.5 The test `tests/Test-OpenAICompatible.ps1` shall have one named check each for the behaviours of 4.7, 4.9, 4.10, 4.11, 4.12, 5.5, 5.6, 5.7, 5.8, 5.11, 5.12, 5.13 and 5.17, where 4.12 is a scan of `orchestrator/**/*.ps1` and `orchestrator/**/*.psm1` (data files such as `endpoints.example.json` excluded) for `['"](OpenAI|Anthropic|Ollama)['"]` (case-insensitive).
6.6 When `tests/Run-SmokeTest.ps1 -Provider OpenAICompatible` runs with the fixture `tests/providers/OpenAICompatible.ps1`, it shall pass every check that applies to a provider without sub-agents.
6.7 The automated tests shall use no network beyond `127.0.0.1`, no real key and no model, and every test script, including `Run-SmokeTest.ps1` for every provider, shall set `ORCH_ENDPOINTS_FILE` in process scope to a temporary file, so that no test reads the user's profiles file.
6.8 The live check `tests/Test-LiveOllama.ps1` shall take `-Endpoint <profile>` and run only when started by hand or by the ollama-setup acceptance check; no other test or check shall call it.
6.9 The test `tests/Test-OpenAICompatible.ps1` shall have one named check each for 4.14, 4.15, 4.16, 4.17 and 4.18, calling `InitializeUser` with an `EndpointsFile` in a temporary folder and dummy key variables with test-specific names (not `OPENAI_API_KEY` or `ANTHROPIC_API_KEY`) in process scope only, and one check that `Install-Orch.ps1 -WhatIf -Endpoint <name> -EndpointsFile <temp path>` reports the file it would create and changes no user environment variable.
6.10 The test `tests/Test-OpenAICompatible.ps1` shall have a named check for 4.19. It plans with `Plan-Tasks.ps1 -Provider OpenAICompatible` against the fake endpoint, without `-WorkerModel`, and asserts that `tasks.json` has no `settings.model`, `settings.reviewModel` or `settings.effort`. It then runs one task with `-Endpoint` set to a second profile and asserts that the captured request used that profile's `model`. A second plan with `-WorkerModel` must persist that model.

### 7. Docs and skills
**Objective:** As a user, I want to find how to choose and configure a provider.

7.1 The README shall describe `orch providers`, `-Provider OpenAICompatible`, `-Endpoint`, the profiles file, key handling and capability gaps, and its script parameter table shall list `-Endpoint`; its setup item 6 and "Another PC, and after a pull" steps shall cover `Install-Orch.ps1 -Endpoint` and `-EndpointsFile`, the starter profiles file, sharing one profiles file between PCs, and setting the key variables on each PC.
7.2 The note `docs/openai-compatible-notes.md` shall give the profile field reference, Ollama, OpenAI and Anthropic example profiles with keys only as variable names (pointing to `endpoints.example.json`; the OpenAI and Anthropic profiles marked as built from documentation and not tested live), the steps to add a further endpoint by configuration alone, the capability gaps and the limitations, and link `docs/openai-compatible/analysis.md`.
7.3 The skills `orch`, `plan-tasks` and `write-spec` shall tell the agent to list the choices with `orch providers` and to pass `-Endpoint` with `-Provider OpenAICompatible`, instead of offering a fixed list of two providers.
7.4 The skills `auto-develop`, `analyze`, `auto-analyze` and `write-spec-analyze` shall name no orchestrator provider (`-Provider` value) and leave provider choice to `orch`; naming the host assistant's own tools, such as Claude Code's Skill tool, is allowed.
7.5 The note `docs/analysis-mode.md` shall state that OpenAICompatible agents have no skill tool, so they cannot start the analysis entry skills.
7.6 When `tests/Test-AnalysisSkills.ps1` runs, it shall check 7.3 and 7.4 and pass.
7.7 The note `docs/copilot-cli-notes.md` shall say that a Copilot call's `*.events.jsonl` holds canonical events and its raw CLI events are in `*.raw.jsonl`.

### 8. Local Ollama setup (this PC: RTX 5070 Ti 16 GB, 62 GB RAM)
**Objective:** As the user, I want the build to leave this PC ready to run the provider against Ollama.

8.1 If `ollama list` lacks `gpt-oss:20b` or `qwen3-coder:30b`, the ollama-setup module shall pull it with `ollama pull`; it shall pull no other model and remove none.
8.2 If the user's profiles file (4.6, with `ORCH_ENDPOINTS_FILE` unset) does not exist, the ollama-setup module shall create it through the OpenAICompatible `InitializeUser` operation (4.14); if it exists, it shall leave it unchanged and record in its results which example profiles it lacks.
8.3 If `GET /api/ps` shows a loaded context below 32768 tokens, or the user variable `OLLAMA_CONTEXT_LENGTH` is unset, the ollama-setup module shall set the user variable to `65536`, quit the Ollama app and start `ollama serve` as a detached process that outlives the run, and record this in its results.
8.4 The ollama-setup module shall run `tests/Test-LiveOllama.ps1` against `ollama-local` and `ollama-coder` and record each result in `docs/openai-compatible/live-check.md`: date, Ollama version, model, context, elapsed time, and every PASS or FAIL line.
8.5 If a model accepts `reasoning_effort` in the live check, the ollama-setup module shall set that profile's `capabilities.reasoningEffort` and `effortMap` in `endpoints.example.json` to the values that worked; if `ollama-local` fails the live check and `ollama-coder` passes, it shall make `ollama-coder` the `default`.
8.6 The ollama-setup module shall send no request to `api.openai.com` or `api.anthropic.com`, and set no environment variable other than `OLLAMA_CONTEXT_LENGTH`.

## 4. Design

### 4.1 Approach

A provider is one module file, `orchestrator/providers/<Name>.psm1`, that sets
`$script:Definition` (section 4.3) and exports nothing. The registry in `Orchestrator.psm1` imports
each file with `Import-Module -PassThru` and reads `& $module { $script:Definition }`;
scriptblocks stay bound to their module. `Invoke-Agent` keeps its job (stdin prompt, JSON-line
events, heartbeat, nudge) but calls the operations instead of branching. `OpenAICompatible`
resolves to `pwsh -NoProfile -NonInteractive -File orchestrator/providers/OpenAICompatible/Invoke-AgentLoop.ps1`,
which talks to the endpoint and runs the tools. Rejected: an in-process loop (no isolation on
interrupt), Codex CLI or OpenCode (uninstalled dependency, second event schema), Claude Code on
an Anthropic-dialect URL (not OpenAI-compatible, invented cost); see the analysis.

### 4.2 Modules and boundaries

| Module | Responsibility | Paths | Uses | Requirements |
| --- | --- | --- | --- | --- |
| provider-core | Registry, Claude and Copilot modules, canonical events, endpoint plumbing, refactored scripts and their tests | `orchestrator/Orchestrator.psm1`, `orchestrator/providers/Claude.psm1`, `orchestrator/providers/Copilot.psm1`, `orchestrator/Invoke-Orchestrator.ps1`, `orchestrator/Plan-Tasks.ps1`, `orchestrator/Initialize-Project.ps1`, `orchestrator/Orch.psm1`, `orchestrator/Watch-Orchestrator.ps1`, `orchestrator/Watch-Conversations.ps1`, `orchestrator/Watch-AgentTimeline.ps1`, `orchestrator/schemas/tasks.schema.json`, `Install-Orch.ps1`, `tests/fake-claude.ps1`, `tests/Run-SmokeTest.ps1`, `tests/Test-CopilotModelSettings.ps1`, `tests/New-PracticeRepo.ps1`, `tests/Test-ProviderRegistry.ps1`, `tests/providers/Claude.ps1`, `tests/providers/Copilot.ps1`, `tests/baseline/**` | none | 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 2.10, 2.11, 2.12, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 4.1, 4.2, 4.3, 4.4, 4.5, 4.13, 4.19 |
| openai-compatible | The provider, profiles, agent loop, fake endpoint, tests, live check | `orchestrator/providers/OpenAICompatible.psm1`, `orchestrator/providers/OpenAICompatible/**`, `orchestrator/schemas/endpoints.schema.json`, `tests/fake-openai-endpoint.ps1`, `tests/Test-OpenAICompatible.ps1`, `tests/Test-LiveOllama.ps1`, `tests/providers/OpenAICompatible.ps1`; after provider-core, also `tests/Run-SmokeTest.ps1` and `orchestrator/Orchestrator.psm1` for fixes the new provider exposes | provider-core | 4.6, 4.7, 4.8, 4.9, 4.10, 4.11, 4.12, 4.14, 4.15, 4.16, 4.17, 4.18, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 5.10, 5.11, 5.12, 5.13, 5.14, 5.15, 5.16, 5.17, 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7, 6.8, 6.9, 6.10 |
| ollama-setup | Pull models, create the user's profiles file, run the live check on this PC (`workerType: coding`) | `docs/openai-compatible/live-check.md`; after openai-compatible, also `orchestrator/providers/OpenAICompatible/endpoints.example.json` | openai-compatible | 8.1, 8.2, 8.3, 8.4, 8.5, 8.6 |
| docs-and-skills | README, docs note, skills and their test | `README.md`, `docs/openai-compatible-notes.md`, `docs/analysis-mode.md`, `.claude/skills/orch/SKILL.md`, `.claude/skills/plan-tasks/SKILL.md`, `.claude/skills/write-spec/SKILL.md`, `.claude/skills/auto-develop/SKILL.md`, `.claude/skills/analyze/SKILL.md`, `.claude/skills/auto-analyze/SKILL.md`, `.claude/skills/write-spec-analyze/SKILL.md`, `tests/Test-AnalysisSkills.ps1`, `docs/copilot-cli-notes.md` | provider-core | 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7 |

**Existing files changed:**
- `orchestrator/Orchestrator.psm1` – registry; `Get-DefaultSettings`, `Resolve-AgentModel`, `Read-Plan`, `Format-SubAgents`, `Format-ToolUse`, `Get-SubAgentName`, `Invoke-Agent`, `Sync-WithIntegration` lose provider branches; `Resolve-AgentPath` becomes `Resolve-AgentCommand`; `$script:CopilotModel`, `$script:ClaudeDeniedMcpServers` and `$script:OrchestratorSkills` move into the provider modules (the smoke test's deny-list check, `tests/Run-SmokeTest.ps1:31-44`, reads them there).
- `Invoke-Orchestrator.ps1`, `Plan-Tasks.ps1`, `Initialize-Project.ps1`, `Watch-Orchestrator.ps1`, `Install-Orch.ps1` – no `ValidateSet` of providers; registry validation; `-Endpoint` (not on the dashboard); `TestReady`; defaults from `GetDefaults`. `Install-Orch.ps1` also gets `-EndpointsFile` and calls `InitializeUser` (4.13).
- `Watch-Conversations.ps1`, `Watch-AgentTimeline.ps1` – canonical events only.
- `Orch.psm1` – `providers` command, validated provider, endpoint resolution, error text `Add -Provider <name> (orch providers lists them)`.
- `tasks.schema.json` – section 4.3.
- `tests/Run-SmokeTest.ps1`, `tests/New-PracticeRepo.ps1`, `tests/Test-CopilotModelSettings.ps1`, `tests/fake-claude.ps1` – provider-neutral parameters, fixtures, moved constants; `tests/Test-AnalysisSkills.ps1` – new skill checks.
- README, `docs/analysis-mode.md`, `docs/copilot-cli-notes.md`, the seven skills – 7.1 to 7.5, 7.7.

### 4.3 Shared contracts

**Provider definition** (`orchestrator/providers/<Name>.psm1`):

```powershell
$script:Definition = @{
    Name            = 'Example'           # equals the file base name
    UsesEndpoint    = $false              # true: takes -Endpoint and reads an endpoint profile
    Install         = @{ SkillFolder = $null; SettingsFile = $null }   # paths under $HOME, or $null
    GetCapabilities = { param([string]$Endpoint) }                     # -> [hashtable] (keys below)
    Resolve         = { param([string]$Endpoint) }                     # -> [pscustomobject]@{ FilePath = [string]; PrefixArgs = [string[]] }; throws if not found
    GetDefaults     = { param([string]$Endpoint) }                     # -> @{ planner; worker; reviewer; bootstrap = [string] or $null; effort = [string] or $null }
    NewInvocation   = { param([hashtable]$Request) }                   # -> [pscustomobject]@{ Arguments = [string[]]; Prompt = [string] }
    ConvertEvent    = { param([Collections.IDictionary]$StreamEvent, [hashtable]$StreamState) }  # -> 0..n canonical events
    GetNudgePrompt  = { param([string]$SchemaError) }                  # -> [string]
    GetSubAgentText = { param([ValidateSet('worker', 'planner')][string]$Role) }           # -> @{ TOOL; FOREGROUND } or $null
    TestReady       = { param([string]$Endpoint, [string[]]$Models) }  # -> [string[]] problems; @() when ready
    GetEndpoints    = { param() }                                      # -> [pscustomobject[]] Name, BaseUrl, Model, IsDefault; @() if not UsesEndpoint
    InitializeUser  = $null   # or { param([hashtable]$Options) }: per-user setup run by Install-Orch.ps1 (4.13)
}
# InitializeUser $Options: @{ Endpoint = [string] or $null; EndpointsFile = [string] or $null; WhatIf = [bool] }
# -> [pscustomobject]@{ Messages = @([pscustomobject]@{ Status = 'changed'|'unchanged'|'info'|'warning'|'problem'; Text = [string] });
#                       UserVariables = @{ <name> = <value> } }   # applied by Install-Orch.ps1, never by the provider
# Claude and Copilot: InitializeUser = $null. OpenAICompatible: 4.14-4.17.
# $Request keys: Prompt, Schema (file name in orchestrator/schemas), SchemaJson (compact), Model, Effort,
# PermissionMode, Tools, AllowedTools, SubAgents ([bool]), MaxBudgetUsd, ResumeSessionId, Name,
# AdditionalDirectories, Endpoint, WorkDir. Tool names use the orchestrator vocabulary:
# Read, Edit, Write, Glob, Grep, Bash, PowerShell, Task, and rules such as 'Bash(git add *)'.
```

| Capability key | Type | Claude | Copilot | OpenAICompatible |
| --- | --- | --- | --- | --- |
| `NativeStructuredOutput` | bool | true | false | true |
| `SubAgents` | bool | true | true | false |
| `CommandRules` | bool | true | false | true |
| `Cost` | bool | true | false | false |
| `Budget` | bool | true | false | false |
| `Effort` | bool | true | true | profile `capabilities.reasoningEffort` |
| `Resume` | bool | true | true | true |
| `CanonicalEvents` | bool | true | false | true |
| `ProcessName` | string | `claude.exe` | `copilot.exe` | `pwsh.exe` |
| `ResumeOmitsName` | bool | false | true | false |

`Install`: Claude `.claude/skills` and `.claude/settings.json`; Copilot `.copilot/skills` and
`$null`; OpenAICompatible `$null` and `$null`. `GetCapabilities` with an empty `$Endpoint`
returns the static flags without reading any file (OpenAICompatible: `Effort` false), so the
dashboard works without a profiles file.

**Registry and core functions** (`Orchestrator.psm1`):

```powershell
function Get-OrchProviderNames { }                                       # -> [string[]] sorted
function Resolve-OrchProviderName { param([string]$Name) }              # -> registered name; throws per 1.4
function Get-OrchProvider { param([string]$Name) }                      # -> the Definition hashtable
function Get-OrchProviderCapabilities { param([string]$Name, [string]$Endpoint) }
function Resolve-AgentCommand { param([string]$Provider, [string]$AgentPath, [string]$Endpoint) }
# -> [pscustomobject]@{ FilePath; PrefixArgs }. -AgentPath wins (PrefixArgs @()), then ORCH_<NAME>, then Resolve.
# Invoke-Agent: -Provider [string] (default 'Claude', no ValidateSet), new -Endpoint [string] and
# -AgentCommand [pscustomobject]; -AgentPath stays and wins over -AgentCommand.
# Resolve-AgentModel: param([string]$Provider, [string]$Model, [string]$Role = 'worker', [string]$Endpoint)
```

**Canonical events**, one JSON object per line. `timestamp` (ISO 8601) is optional;
`parent_tool_use_id` marks a sub-agent's events; a sub-agent starts with a `tool_use` named
`Agent` whose `input` has `description` and `prompt`. Several `result` events may come; the
last counts. `subtype` of `result`: `success`, `error_max_turns`, `error_output_limit`,
`error_http`, `error_during_execution`; `is_error` is false only for `success`.

```json
{"type":"system","subtype":"init","session_id":"<id>","model":"<model>","tools":["Read","Glob"],"timestamp":"<iso>"}
{"type":"system","subtype":"model_call_start","turn_id":"1","timestamp":"<iso>"}
{"type":"system","subtype":"model_call_end","turn_id":"1","usage":{"prompt_tokens":0,"completion_tokens":0},"timestamp":"<iso>"}
{"type":"system","subtype":"warning","message":"<text>","timestamp":"<iso>"}
{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"<text>"},{"type":"tool_use","id":"<call id>","name":"Read","input":{"file_path":"src/a.ps1"}}]}}
{"type":"user","parent_tool_use_id":null,"message":{"content":[{"type":"tool_result","tool_use_id":"<call id>","content":"<text>","is_error":false}]}}
{"type":"result","subtype":"success","is_error":false,"session_id":"<id>","result":"<final text>","structured_output":null,"total_cost_usd":0,"num_turns":3,"usage":{"prompt_tokens":0,"completion_tokens":0}}
```

Loop tool inputs: `Read{file_path, offset?, limit?}`, `Glob{pattern, path?}`,
`Grep{pattern, path?, glob?}`, `Edit{file_path, old_string, new_string}`,
`Write{file_path, content}`, `PowerShell{command, timeout_sec?}` (default timeout 600 s),
`StructuredOutput{<schema properties>}`. Copilot names map to `view`→`Read`, `glob`→`Glob`,
`rg`→`Grep`, `apply_patch`→`Edit`, `powershell`→`PowerShell`, `task`→`Agent`; other names pass
through.

**Agent loop command line** (built by the OpenAICompatible `NewInvocation`):

```text
pwsh -NoProfile -NonInteractive -File orchestrator/providers/OpenAICompatible/Invoke-AgentLoop.ps1
  --endpoint <profile> --model <id> [--effort <level>] [--tools Read,Glob,Grep,Edit,Write,PowerShell]
  [--allowed-command "<pattern>"]... [--add-dir <dir>]... [--schema-file <path>]
  [--resume <session-id>] [--name orch:<task>[:review|:resolve]]
stdin: the prompt (UTF-8). stdout: canonical events. Exit 0 when a result event was written, else 1.
```

Mapping: `Read, Glob, Grep, Edit, Write` keep their names; `Bash` and `PowerShell` become
`PowerShell`; `Bash(<p>)` and `PowerShell(<p>)` become `PowerShell` plus `--allowed-command <p>`;
`Task` is dropped; an empty list means all six; any other entry throws
`OpenAICompatible cannot map tool rule '<entry>'`. `PermissionMode` and `MaxBudgetUsd` are not passed.

**`structuredOutput` modes** (the result is always checked with `Test-Json`):
- `tool`: `StructuredOutput` is offered with the schema as `parameters`; its call ends the session. If the model ends with text instead, that text is handled as in `prompt`.
- `json_schema`: after the tool loop, one request without `tools`, with `response_format: {"type":"json_schema","json_schema":{"name":"result","strict":true,"schema":<schema>}}` and the user message `Return the result now as JSON that matches the schema.`
- `json_object`: as `json_schema`, with `{"type":"json_object"}` and the schema text in the message.
- `prompt`: as `json_schema`, with no `response_format` and the schema text in the message; a Markdown fence is removed before parsing.

**Endpoint profiles file** (`orchestrator/schemas/endpoints.schema.json`):

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Endpoint profiles for the OpenAICompatible provider",
  "type": "object", "required": ["version", "profiles"], "additionalProperties": false,
  "properties": {
    "version": { "const": 1 },
    "default": { "type": "string" },
    "profiles": {
      "type": "object",
      "propertyNames": { "pattern": "^[a-z0-9][a-z0-9._-]{0,48}$" },
      "additionalProperties": {
        "type": "object", "required": ["baseUrl", "model"], "additionalProperties": false,
        "properties": {
          "baseUrl": { "type": "string", "pattern": "^https?://" },
          "dialect": { "enum": ["chat-completions"] },
          "apiKeyEnv": { "type": ["string", "null"], "pattern": "^[A-Za-z_][A-Za-z0-9_]*$" },
          "authHeader": { "type": "string", "minLength": 1 },
          "authScheme": { "type": "string" },
          "headers": { "type": "object", "additionalProperties": { "type": "string" } },
          "headersFromEnv": { "type": "object", "additionalProperties": { "type": "string", "pattern": "^[A-Za-z_][A-Za-z0-9_]*$" } },
          "model": { "type": "string", "minLength": 1 },
          "reviewModel": { "type": "string", "minLength": 1 },
          "plannerModel": { "type": "string", "minLength": 1 },
          "effort": { "enum": ["none", "minimal", "low", "medium", "high", "xhigh", "max", null] },
          "requestTimeoutSec": { "type": "integer", "minimum": 10 },
          "maxOutputTokens": { "type": "integer", "minimum": 256 },
          "maxTokensParameter": { "enum": ["max_tokens", "max_completion_tokens"] },
          "maxTurns": { "type": "integer", "minimum": 1 },
          "maxToolOutputChars": { "type": "integer", "minimum": 1000 },
          "retries": { "type": "integer", "minimum": 0, "maximum": 5 },
          "extraBody": { "type": "object" },
          "capabilities": {
            "type": "object", "additionalProperties": false,
            "properties": {
              "structuredOutput": { "enum": ["tool", "json_schema", "json_object", "prompt"] },
              "reasoningEffort": { "type": "boolean" },
              "effortMap": { "type": "object", "additionalProperties": { "type": "string" } },
              "listModels": { "type": "boolean" }
            }
          }
        }
      }
    }
  }
}
```

Defaults: `dialect` `chat-completions`, `apiKeyEnv` null (no auth header), `authHeader`
`Authorization`, `authScheme` `Bearer` (header value `<scheme> <key>`, or the key alone when
empty), `reviewModel` and `plannerModel` = `model`, `effort` null, `requestTimeoutSec` 600,
`maxOutputTokens` 8192, `maxTokensParameter` `max_tokens`, `maxTurns` 60,
`maxToolOutputChars` 30000, `retries` 2, `structuredOutput` `tool`, `reasoningEffort` false,
`listModels` true. `GetDefaults` returns `plannerModel`, `model`, `reviewModel`, `model`,
`effort` for planner, worker, reviewer, bootstrap and effort.

**`tasks.json` changes** (`orchestrator/schemas/tasks.schema.json`, top-level properties):

```json
"provider": { "type": "string", "pattern": "^[A-Za-z][A-Za-z0-9]{0,31}$", "description": "Provider the plan was made for (orch providers lists them). Read-Plan checks it against the registry. Missing: Claude." },
"endpoint": { "type": ["string", "null"], "pattern": "^[a-z0-9][a-z0-9._-]{0,48}$", "description": "Endpoint profile name, for providers that use endpoint profiles." }
```

`settings.model` and `settings.reviewModel` descriptions become `Default: the provider's
default (orch providers shows it).`; `settings.maxBudgetUsd` becomes `Spend cap per agent call
in USD, for providers that enforce one. Default: 0 (no cap).`; `settings.effort` becomes
`Omitted/null: the provider's default effort.`

**`project.json`** (no schema file; `endpoint` is new and removed when the provider has no endpoints):

```json
{ "provider": "OpenAICompatible", "endpoint": "ollama-local", "setup": null, "integrationCheck": null }
```

**Smoke-test fixture** (`tests/providers/<Name>.ps1`, dot-sourced by `Run-SmokeTest.ps1` after `$WorkDir` is set):

```powershell
@{
    AgentPath   = $null      # [string]: passed as -AgentPath to every script call when set
    Endpoint    = $null      # [string]: passed as -Endpoint when set
    Environment = @{}        # set before the first call, removed at the end
    Start       = $null      # [scriptblock]: starts fakes
    Stop        = $null      # [scriptblock]: stops them, also on failure
    AfterPlan   = $null      # [scriptblock] param([hashtable]$PlanDoc): may change the plan before the run
    Skip        = @()        # [string[]]: names of generic checks that do not apply (see 2.10); Checks adds an equivalent
    Checks      = { param([hashtable]$Context) [ordered]@{} }   # Context: Repo, WorkDir, PlanFile, StateFile; -> name -> [bool]
}
```

### 4.5 Error handling

- Provider and profile errors stop the script before any agent call, with the messages of
  1.4, 2.11, 4.4, 4.7 and 5.15.
- Loop failures end the session with a `result` event whose `is_error` is true; `Invoke-Agent`
  reports `<subtype>: <result>` as today, so the task pipeline's retry and feedback apply.
- HTTP errors name the status, the endpoint profile and the endpoint's error message; auth
  errors (401, 403) also name `apiKeyEnv`, never its value.
- A missing loop result (crash) gives `OpenAICompatible exited with <code>` plus the stderr tail.

## 5. Build order

1. provider-core first, as a serial chain of tasks, because every link edits
   `orchestrator/Orchestrator.psm1`. Each link owns provider-core's paths, depends on the link
   before it, and has the acceptance check "both smoke tests, `Test-CopilotModelSettings.ps1`
   and `Test-ProviderRegistry.ps1` pass". The links follow the steps of the refactoring plan in
   `docs/openai-compatible/analysis.md`:

   | Link | Plan steps | Requirements |
   | --- | --- | --- |
   | core-registry | 1-4 | 1.1, 1.2, 1.3, 1.6, 2.1, 2.2, 2.3 |
   | core-events | 5 | 3.1, 3.2, 3.3, 3.4, 3.7 |
   | core-capabilities | 6-9 | 2.4, 2.5, 2.6, 2.8, 3.5, 3.6 |
   | core-names-endpoints | 10-11 | 1.4, 1.5, 1.7, 1.8, 2.7, 2.11, 4.1, 4.2, 4.3, 4.4, 4.5, 4.13, 4.19 |
   | core-fixtures | 12 | 2.9, 2.10 |

   core-registry creates `tests/Test-ProviderRegistry.ps1`. Each later link adds the named
   checks of 2.12 for its own requirements, so the list is complete after
   core-names-endpoints. Before changing any code, core-registry saves the captured CLI
   arguments (`FAKE_CAPTURE_ARGS`) and prompt files of both smoke tests under `tests/baseline/`, with temporary paths replaced by placeholders, and commits them. Every link
   compares against them for 2.1.
2. openai-compatible and docs-and-skills in parallel, after the last provider-core link is merged.
3. ollama-setup after openai-compatible. It changes this PC (models, user profiles file, Ollama server), so it runs alone and last.

## 6. Verification

- **Setup command:** none.
- **Test runner and layout:** plain PowerShell scripts in `tests/`; exit code 0 is a pass.
  The fake endpoint and fixtures follow `tests/fake-claude.ps1` and `tests/Run-SmokeTest.ps1`.
- **Per-deliverable check:**
  - provider-core: `pwsh -NoProfile -File tests/Test-ProviderRegistry.ps1; if ($LASTEXITCODE) { exit 1 }; foreach ($p in 'Claude', 'Copilot') { pwsh -NoProfile -File tests/Run-SmokeTest.ps1 -Provider $p; if ($LASTEXITCODE) { exit 1 } }; pwsh -NoProfile -File tests/Test-CopilotModelSettings.ps1; exit $LASTEXITCODE`
  - openai-compatible: `pwsh -NoProfile -File tests/Test-OpenAICompatible.ps1; if ($LASTEXITCODE) { exit 1 }; pwsh -NoProfile -File tests/Run-SmokeTest.ps1 -Provider OpenAICompatible; exit $LASTEXITCODE`
  - docs-and-skills: `pwsh -NoProfile -File tests/Test-AnalysisSkills.ps1; exit $LASTEXITCODE`
  - ollama-setup: `$ok = 0; foreach ($p in 'ollama-local', 'ollama-coder') { pwsh -NoProfile -File tests/Test-LiveOllama.ps1 -Endpoint $p; if ($LASTEXITCODE -eq 0) { $ok++ } }; if (-not (Test-Path docs/openai-compatible/live-check.md)) { 'live-check.md missing'; exit 1 }; if ($ok -lt 1) { 'no Ollama profile passed the live check'; exit 1 }; exit 0`
- **Whole-project check:** `foreach ($t in 'Test-ProviderRegistry', 'Test-OpenAICompatible', 'Test-CopilotModelSettings', 'Test-AnalysisSkills') { pwsh -NoProfile -File "tests/$t.ps1"; if ($LASTEXITCODE) { exit 1 } }; foreach ($p in 'Claude', 'Copilot', 'OpenAICompatible') { pwsh -NoProfile -File tests/Run-SmokeTest.ps1 -Provider $p; if ($LASTEXITCODE) { exit 1 } }`
- **Live check against Ollama on this PC** (`tests/Test-LiveOllama.ps1`; run by ollama-setup, and by hand after that, never by the other checks above):
  1. Ollama answers at `http://localhost:11434`. `ollama list` shows `gpt-oss:20b` and
     `qwen3-coder:30b` once ollama-setup has pulled them (8.1). They suit this PC:
     `gpt-oss:20b` (14 GB) fits fully in the 16 GB GPU, and `qwen3-coder:30b` (19 GB,
     mixture of experts with 3B active parameters) spills its rest into the 62 GB RAM.
     Both were listed on ollama.com on 2026-10-28; they have not yet been tested here.
  2. The loaded context was 4096 tokens on 2026-10-28 (`GET /api/ps`), too small for agent
     prompts. ollama-setup sets `OLLAMA_CONTEXT_LENGTH=65536` (8.3), as Ollama advises at
     least 64000 for agents. By hand, quit the Ollama app, then run
     `$env:OLLAMA_CONTEXT_LENGTH = '65536'; ollama serve`.
  3. Run `pwsh -NoProfile -File .\tests\Test-LiveOllama.ps1 -Endpoint ollama-local` (or
     `ollama-coder`). The script copies that profile from `endpoints.example.json` into a
     temporary endpoints file, with `requestTimeoutSec` at least 900. It points
     `ORCH_ENDPOINTS_FILE` at that file, creates a temporary git repo, and warns when
     `/api/ps` reports a context below 32768. The user's own profiles file is not read.
  4. It runs a worker call that must create `hello.txt` containing `hello from the loop` and
     return a valid worker result, then a reviewer call with `Read, Glob, Grep` only.
  5. Expected: lines `live worker wrote hello.txt PASS`, `live worker result valid PASS` and
     `live reviewer changed no file PASS`, the elapsed time, and exit code 0, within 10 minutes.
     A FAIL line names the step and the log folder. Model quality is a finding, not a code bug.
## 7. Constraints

- **Stack:** PowerShell 7.2+, the repo's only runtime. HTTP through `Invoke-WebRequest`
  (`-SkipHttpErrorCheck`, `-TimeoutSec`, `-NoProxy` for loopback hosts). No new dependency,
  module or binary.
- **Conventions:** module layout of `orchestrator/`; comment style and helpers of
  `orchestrator/Orchestrator.psm1`; test style of `tests/Run-SmokeTest.ps1` (named checks
  printed as PASS/FAIL) and `tests/fake-claude.ps1`; docs style of `docs/copilot-cli-notes.md`.
- **Shared files:** none.

**Always**
- Keep both existing smoke tests passing after every change in provider-core.
- Use dummy key values in tests and scan the test's run folders for them.
- Keep the agent loop's tools inside the working folder and `--add-dir` folders.

**Stop and report blocked**
- A requirement that would need a paid API call, a software install, or a model download other than the two in 8.1.
- A smoke check of the existing providers that cannot pass without changing a gate.

**Never**
- Read or print a real API key, `~/.claude`, `~/.copilot` or credential stores yourself. Scripts under test that read their own files, such as `Install-Orch.ps1 -WhatIf`, are allowed.
- Branch on `OpenAI`, `Anthropic` or `Ollama` in code, or list provider names in a script.
- Run `tests/Test-LiveOllama.ps1` from any test or check other than the ollama-setup acceptance.
- Send any request to `api.openai.com` or `api.anthropic.com`, with or without a key. Settle
  their behaviour from the documentation and mark it untested.
- Edit files outside the module's paths.

## 8. Open questions

None.
