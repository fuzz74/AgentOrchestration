# Endpoint findings: Ollama, OpenAI, Anthropic and tool-loop harnesses

Evidence date: 2026-10-28. Raw probe scripts and trimmed responses are in
[`evidence/`](evidence/). Reasoning text in the evidence files is cut to 300 characters.
No API key was used. The only token sent anywhere was the dummy `ollama`.

## Summary

- Ollama 0.40.12 at `http://localhost:11434` serves an OpenAI-compatible API and an
  Anthropic-compatible `/v1/messages` API. Both were tested live with
  `huihui_ai/gemma-4-abliterated:26b`.
- Tool calling worked on every attempt (6 of 6: OpenAI non-stream and
  stream, Anthropic non-stream, Claude Code runs 1, 2 and 3). A tool-result round trip
  (`role: tool`, `tool_call_id`) gave the right final answer. This is a small sample, not a
  reliability measurement. Streamed tool calls arrive whole in one chunk, not as deltas.
- `response_format` `json_schema` (strict) and `json_object` both returned valid JSON that
  matched the schema. Whether Ollama enforces the schema by grammar was not isolated.
- The model is a reasoning model. Output has a separate `reasoning` field (OpenAI dialect)
  or a `thinking` block (Anthropic dialect). `max_tokens: 20` is too low. 1024 or more
  worked. Reasoning tokens are counted in `usage.completion_tokens`.
- Claude Code 2.1.312 runs end to end against Ollama (`ANTHROPIC_BASE_URL`, dummy token).
  It calls tools, and returns a normal-looking `result` event (`session_id`, `is_error:
  false`, `total_cost_usd`). But `total_cost_usd` is a made-up price (about 0.014 USD for a
  local model). A quick two-turn run took 2.5 to 10 s.
- OpenAI and Anthropic both document Chat Completions compatible access. Anthropic's layer
  ignores `response_format`, `strict` and `reasoning_effort`, and says it is for testing,
  not production. OpenAI recommends the Responses API for new work.
- Harness candidates: Codex CLI and OpenCode both document custom OpenAI-compatible
  providers and a headless JSON mode. Neither is installed, so neither was tested.
  Copilot CLI is not installed on this PC, so approach D is untested.

## Ollama (live)

All tests: date 2026-10-28, Ollama 0.40.12 (`ollama --version`, `GET /api/version`),
Windows 11, PowerShell 7, `Invoke-RestMethod` unless noted. Model:
`huihui_ai/gemma-4-abliterated:26b` (17 GB). Also installed, not used:
`huihui_ai/gemma-4-abliterated:31b-v2` (19 GB). Scripts: `evidence/probe-ollama.ps1`,
`evidence/probe-stream.ps1`. Each test used a single run, so the times are one sample.

| Test | Request shape | Observed response fields | Time | Evidence |
| --- | --- | --- | --- | --- |
| `GET /v1/models` | none | `object: list`, `data[]` with `id`, `object`, `created`, `owned_by`. Both installed models listed. | 2.1 s | `models.json` |
| `POST /v1/chat/completions` | `model`, `max_tokens: 1024`, one user message | `id`, `object`, `created`, `model`, `system_fingerprint: fp_ollama`, `choices[0].message.{role,content,reasoning}`, `finish_reason: stop`, `usage`. Content was correct; 617 completion tokens were mostly reasoning. | 9.3 s | `chat.json` |
| With `tools` (`read_file`) | `tools[]` OpenAI function format, user asks to read `notes.txt`, `max_tokens: 2048` | `message.content: ""`, `message.tool_calls[0] = {id: "call_...", index, type: function, function: {name: read_file, arguments: "{\"path\":\"notes.txt\"}"}}` (arguments is a JSON string), `finish_reason: tool_calls`. | 2.7 s | `tools.json` |
| Tool-result round trip | the above plus assistant message with `tool_calls` and `{role: tool, tool_call_id, content}`, then a user question | Final `content: "The code word is BLUEBIRD."`, `finish_reason: stop`. `cached_tokens: 64` of 128 prompt tokens (prefix cache). | 3.1 s | `tool-roundtrip.json` |
| `response_format` `json_schema` | `{type: json_schema, json_schema: {name, strict: true, schema}}` | `content` was valid JSON matching the schema (`city`, `population_millions`). The value 5.5 is the population of Norway, not Oslo; the prompt was ambiguous. No error. | 9.4 s | `json-schema.json` |
| `response_format` `json_object` | `{type: json_object}` | Valid JSON with the requested keys. Not needed as a fallback, since `json_schema` worked. | 6.1 s | `json-object.json` |
| `reasoning_effort: low` | extra field on chat request | Accepted, no error. `content: "391"` correct. The effect of the value on reasoning length was not measured (one sample, no `high` comparison). | 3.9 s | `reasoning-effort.json` |
| Streaming, no tools | `stream: true`, `stream_options.include_usage: true` | `Content-Type: text/event-stream`. 394 `data:` lines ending with `data: [DONE]`. Deltas carry `reasoning` first, then `content`. A final chunk with `choices: []` carries `usage` and an Ollama-specific `timings` object. First chunk after 2.5 s. | 7.2 s | `stream-chat.json` (via `HttpClient`) |
| Streaming with tools | as above plus `tools` | 4 chunks. One delta has the complete `tool_calls[0]` (name and full arguments, `index: 0`), then `finish_reason: tool_calls`, then the usage chunk. Tool calls are not streamed token by token. | 2.3 s | `stream-tools.json` |
| Anthropic `POST /v1/messages` | `model`, `max_tokens: 1024`, `messages`, no auth header | `type: message`, `content[]` with a `thinking` block then a `text` block, `stop_reason: end_turn`, `usage.{input_tokens,output_tokens,cache_read_input_tokens}`. Ollama needs no auth header. | 6.5 s | `anthropic-messages.json` |
| `/v1/messages` with tools | `tools[]` with `input_schema` | `content[]` has `thinking` and `tool_use` blocks (`id: call_...`, `name`, `input` as an object), `stop_reason: tool_use`. | 2.7 s | `anthropic-tools.json` |

### `usage` fields

- OpenAI dialect: `prompt_tokens`, `completion_tokens`, `total_tokens`,
  `prompt_tokens_details.cached_tokens`. No `completion_tokens_details`, so reasoning tokens
  are not reported separately. The streaming usage chunk adds `timings`
  (`prompt_per_second`, `predicted_per_second`; about 101 tokens/s generation in
  `stream-chat.json`).
- Anthropic dialect: `input_tokens`, `output_tokens`, `cache_read_input_tokens`.
- No cost field in either dialect.

### Observations that matter for a harness

- Reasoning is returned in `message.reasoning` (not `reasoning_content`). A client must not
  treat an empty `content` with `finish_reason: length` as an answer. Probe 2026-10-28 with
  `max_tokens` 1024 to 2048 never hit the limit; the planning-time probe with `max_tokens: 20` did.
- Tool call `id` values are short (`call_xqdsx2d3`) and unique per call. Arguments are a
  string in the OpenAI dialect, an object in the Anthropic dialect.
- The tool test used one trivial tool and one explicit instruction. It says nothing about
  multi-tool choice, large tool outputs or long loops (see Untested claims).

### Claude Code against Ollama (bounded probe)

Script: `evidence/probe-claude.ps1`. Claude Code 2.1.312. Three runs, within the limit.
Setup: new empty folder under `$env:TEMP`, `ANTHROPIC_BASE_URL=http://localhost:11434`,
`ANTHROPIC_AUTH_TOKEN=ollama`, `CLAUDECODE` and `CLAUDE_CODE_*` removed from the process
environment, `-p`, `--model huihui_ai/gemma-4-abliterated:26b`,
`--output-format stream-json --verbose`, `--tools Read,Glob,Grep`,
`--allowedTools Read,Glob,Grep`. Timeout 600 s (never reached).

| Run | Prompt reaching the model | Result | Wall time |
| --- | --- | --- | --- |
| 1 | Only the word "Use". My script passed the prompt unquoted via `Start-Process`, so `-p` took the first word. | `Glob {"pattern":"*"}` called, result "No files found", then a final answer asking what to use. `success`, `is_error: false`. | 10 s |
| 2 | Same bug, different prompt. | Same behavior: `Glob` called, vague final answer. `success`. Output not kept. | 7 s |
| 3 | Full prompt, after quoting fix: call `Glob` with `**/*`, then answer `COUNT=<n>`. | `Glob {"pattern":"**/*"}` called with the exact pattern, final result `COUNT=0` (correct, folder empty). `success`, `is_error: false`, `num_turns: 2`, `duration_ms: 1660`. | 2.5 s |

Runs 1 and 2 are invalid as tests of instruction following. They are kept because they show
the CLI still works end to end. Run 3 is the valid probe.

Findings:

- **Works end to end.** The init event lists only `Glob,Grep,Read` and the local model name.
  Tool call and tool result events appear in the normal `assistant`/`user` shape.
- **The `result` event looks normal**: `type: result`, `subtype: success`, `is_error: false`,
  `session_id` (UUID), `num_turns`, `duration_ms`, `usage`, `total_cost_usd`
  (0.0141712 in run 3), `stop_reason: end_turn`, `terminal_reason: completed`
  (`evidence/claude-run3.trimmed.jsonl`).
- **Cost is fabricated.** `modelUsage` for the model shows `costBasis: "unknown"`,
  `contextWindow: 200000` and `maxOutputTokens: 32000` (run 1 file; defaults, not the
  local model's real limits). stderr shows
  `[claude-code:unrecognized_model]`. Any budget check on `total_cost_usd` is meaningless here.
- **Noise**: run 1 produced 335 `system/thinking_tokens` events (dropped from the trimmed
  evidence). stderr also warns that claude.ai connectors are disabled because an auth source
  is set.
- Prompts are large: about 3.2k input tokens plus 3.4k cache-read tokens for a two-turn
  run (run 1 usage). Local prefix caching made this cheap in time.
- Resume (`--resume`), `--json-schema`, `--max-budget-usd` and edit tools against Ollama
  were not tested (probe limit: read-only tools, 3 runs).

## OpenAI

Sources fetched 2026-10-28 with `Invoke-WebRequest`. `platform.openai.com` API reference
pages returned 403 to a script, so the same content was read from `developers.openai.com`.

| Topic | Finding | Source |
| --- | --- | --- |
| Base URL | `https://api.openai.com/v1` | live 401 below; <https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create> |
| Auth | `Authorization: Bearer <key>`. Unauthenticated `GET /v1/models` on 2026-10-28 returned HTTP 401 `{"error":{"message":"Missing bearer authentication in header","type":"invalid_request_error",...}}`. `POST /v1/chat/completions` without a key returned 401 with a message naming Bearer auth. | live, no key |
| Model naming | Plain model ids sent in `model`; listed by `GET /v1/models`. Not enumerated here (needs a key). | same API reference |
| Chat Completions vs Responses | "While Chat Completions remains supported, Responses is recommended for all new projects." Both exist. | <https://developers.openai.com/api/docs/guides/migrate-to-responses> |
| Tool calling | `tools[]` of functions in Chat Completions; Responses adds built-in tools and `previous_response_id`. | migrate guide above |
| Structured output | `response_format: {type: json_schema, json_schema: {name, strict: true, schema}}`. | <https://platform.openai.com/docs/guides/structured-outputs> (fetched, 200) |
| Streaming | `stream: true` with SSE. `stream_options` has `include_usage` and `include_obfuscation`. | API reference above |
| Reasoning effort | Chat Completions `reasoning_effort`, documented values `none, minimal, low, medium, high, xhigh, max`. Not all models accept all values. Responses uses `reasoning: {effort}`. | API reference; <https://platform.openai.com/docs/guides/reasoning> |
| Usage and cost | `usage.{prompt_tokens, completion_tokens, total_tokens}`, `completion_tokens_details.reasoning_tokens` (among others), `prompt_tokens_details.cached_tokens`. No dollar cost field. | API reference |
| Limitations | Reasoning tokens count in completion tokens, billing and context limits. | API reference |

Not verified live (needs a key): which models accept which `reasoning_effort` value, the
exact error shape for invalid parameters, and rate limits.

## Anthropic

Source: <https://docs.claude.com/en/api/openai-sdk> (fetched 2026-10-28, redirects to the
Claude Platform Docs page "OpenAI SDK compatibility").

| Topic | Finding |
| --- | --- |
| Base URL | `https://api.anthropic.com/v1/` with an OpenAI SDK. Chat Completions only; the page documents no Responses API support. |
| Auth | The Claude API key goes where the OpenAI key goes (`Authorization`; "authorization: Fully supported" in the header table). Keys not scoped to a workspace also need an `anthropic-workspace-id` header. Live check without a key on 2026-10-28: `POST /v1/chat/completions` returned 401 `{"error":{"code":"authentication_error","message":"Invalid Anthropic API Key","type":"invalid_request_error",...}}` (OpenAI error shape). Native `GET /v1/models` returned 401 `x-api-key header is required`. |
| Model naming | Claude model names, for example `claude-opus-5-5` in the page's example. |
| Status | "primarily intended to test and compare model capabilities, and is not considered a long-term or production-ready solution for most use cases". |
| Tool calling | `tools`, `tool_choice`, `parallel_tool_calls`, `tool_calls` and `role: tool` with `tool_call_id` are supported. `strict` is ignored, so tool JSON is not guaranteed to follow the schema. Forced tool use (`required`, named function) errors on Claude Opus 5.5, Sonnet 5.5, Fable 5.1 and Mythos 5.1. |
| Structured output | `response_format` is ignored. Use the native API for structured outputs. |
| Streaming | `stream` and `stream_options` fully supported. |
| Reasoning | `reasoning_effort` is ignored. Thinking is enabled with `extra_body: {"thinking": {...}}`, but "the OpenAI SDK doesn't return Claude's thinking". |
| Usage | `usage.prompt_tokens`, `completion_tokens`, `total_tokens` supported. `prompt_tokens_details` and `completion_tokens_details` are "always empty". No cost field. `system_fingerprint`, `service_tier` always empty. |
| Other limits | `n` must be 1. `temperature` capped at 1, and on Claude 4.7+ models only the default is accepted. System and developer messages are hoisted and joined into one system prompt. No prompt caching through this layer. Most unsupported fields are silently ignored, not rejected. Rate-limit headers are returned. |
| Native alternative | The native Messages API gives the full feature set (thinking, caching, strict structured output). It is the alternative, not the focus. |

Not verified live (needs a key): all behavior beyond the auth error shape.

## Harness candidates

"Tested here" means run on this PC on 2026-10-28. Nothing was installed.

| Capability | A: built-in loop | B1: Codex CLI `codex exec --json` | B2: OpenCode `opencode run` | C: Claude Code via `ANTHROPIC_BASE_URL` | D: Copilot CLI BYOK |
| --- | --- | --- | --- | --- | --- |
| Headless run | Own code; trivial | Yes: `codex exec "<prompt>"`; final message on stdout (docs) | Yes: `opencode run [message..]` (docs) | Yes: `claude -p`. **Tested.** | Docs: BYOK works in the CLI; headless flags not checked. Untested |
| Tool control (read-only vs edit) | Full control, own sandbox rules | `--sandbox` read-only (default) / workspace-write / danger-full-access (docs) | `--auto` auto-approves permissions; per-agent permission config exists (docs; details not read) | `--tools`, `--allowedTools`. **Tested** read-only set | Not checked |
| JSON event stream | Own format | `--json` gives JSONL: `thread.started`, `turn.*`, `item.*`, `error` (docs) | `--format json` raw JSON events (docs) | `--output-format stream-json`. **Tested**; events normal | Not checked |
| Structured result | Own | `--output-schema <file>` and `-o <file>` (docs) | Not found in the CLI docs read | `--json-schema` flag exists (`claude --help`); not tested against Ollama | Not checked |
| Session resume | Own state | `codex exec resume --last` / `<SESSION_ID>` (docs) | `--continue`, `--session <id>`, `--fork` (docs) | `--resume <session-id>` (`claude --help`); not tested against Ollama | Not checked |
| Sub-agents | Must build | "Subagents" page exists in the Codex docs nav; not read | "--agent" option; sub-agent behavior not read | Built in; not tested against Ollama | Not checked |
| OpenAI-compatible `base_url` | Own client; any dialect | `[model_providers.<id>]` with `base_url`, `env_key`, `wire_api = "responses"` shown in docs; the docs list `ollama` and `lmstudio` as built-in provider ids | Custom provider with `npm: "@ai-sdk/openai-compatible"` and `options.baseURL`; Ollama listed as provider | Anthropic dialect only: Ollama `/v1/messages` **tested**; OpenAI endpoints would need a translating proxy (untested) | Docs: `providers.json` with `type: openai` and `baseUrl` (works for Ollama, vLLM); Ollama auto-discovery at `127.0.0.1:11434`. Requires tool calling and streaming |
| Windows | PowerShell, native | Docs show a Windows installer and a "Windows sandbox" page; not run | Not checked on Windows | **Tested** on Windows 11 | Not installed (see below) |
| Install footprint | None | New binary (installer or npm; docs) | New binary or npm package | Already installed (2.1.312) | `copilot` not found on PATH on this PC |
| Tested on this PC | Not built (Ollama API itself tested) | No | No | Yes, 3 runs | No |

Notes:

- A: the Ollama facts above (tool calls, round trip, structured output, streaming) show the
  endpoint can drive a custom loop. They do not show that a PowerShell loop is good.
- B1 caveat from docs: Codex requires a git repository to run
  (<https://developers.openai.com/codex/noninteractive>). The docs examples for custom
  providers use `wire_api = "responses"`. Whether Codex can use plain Chat Completions
  (needed if an endpoint lacks `/v1/responses`) was not verified. Ollama documents
  `/v1/responses` support (<https://docs.ollama.com/api/openai-compatibility>), but this was
  not tested live.
- B1 caveat: Codex ignores `model_providers` in project `.codex/config.toml` and reads it only
  from the user-level config (<https://developers.openai.com/codex/config-advanced>). This affects per-run profiles.
- C: Ollama's own page documents Claude Code use and lists `tool_choice`, prompt caching,
  citations, PDF and batches as unsupported
  (<https://docs.ollama.com/api/anthropic-compatibility>). Cost reporting is invented (see above).
- D: `copilot` was not on PATH (`copilot --version` printed an install hint), so its help
  was not read. Claims come only from
  <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-byok-models>.
- Sources: Codex <https://developers.openai.com/codex/noninteractive>; OpenCode
  <https://opencode.ai/docs/cli/> and <https://opencode.ai/docs/providers/>.

## Untested claims

| Claim | Why untested |
| --- | --- |
| Reliability of local tool calling over many turns, many tools, or large tool outputs | Only single-tool, single-call probes were run, plus 3 Claude Code runs |
| Claude Code editing tools, `--resume`, `--json-schema`, `--max-budget-usd`, sub-agents against Ollama | Spec limits the probe to 3 runs with `Read,Glob,Grep` |
| Claude Code quality on real tasks with this model | Runs 1 and 2 had a prompt-quoting bug in my script; run 3 was a trivial task |
| Ollama enforces `json_schema` by grammar (versus the model just complying) | Only schema-conforming outputs were seen; no adversarial schema was tried |
| `reasoning_effort` changes reasoning length | Accepted without error; no comparison between levels |
| The 31b-v2 model | Not used; the 26b was preferred for speed |
| Parallel tool calls, `tool_choice`, multi-modal input on Ollama | Not probed |
| Ollama `/v1/responses` | Documented, not probed (Chat Completions was the focus) |
| Any OpenAI or Anthropic API behavior beyond the unauthenticated 401 shape | Needs a paid key; out of scope |
| OpenAI model names and per-model `reasoning_effort` support | Needs a key; docs page does not list them |
| `platform.openai.com/docs/api-reference/*` pages | 403 to scripted requests; same content read from `developers.openai.com` instead |
| Codex CLI and OpenCode behavior (headless run, JSON events, custom provider, Windows) | Not installed; install is out of scope. Doc claims only |
| Codex support for `wire_api = "chat"` and OpenCode `--format json` event schema | Not found or not read in the docs fetched |
| Copilot CLI BYOK and headless behavior | `copilot` is not installed on this PC (VS Code shim only prints an install hint); docs read only |
| Sub-agent support in Codex and OpenCode | Pages not read |
| Anthropic compatibility endpoint behavior with a real model | Needs a key |
