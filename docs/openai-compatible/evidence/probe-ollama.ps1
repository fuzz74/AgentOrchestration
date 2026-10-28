# Ollama live probe (PowerShell 7). Run: pwsh -File probe-ollama.ps1 -OutDir <dir>
param([string]$OutDir = '.', [string]$Model = 'huihui_ai/gemma-4-abliterated:26b', [string]$Base = 'http://localhost:11434')
$ErrorActionPreference = 'Continue'
function Call($name, $method, $path, $body) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $p = @{ Uri = "$Base$path"; Method = $method; TimeoutSec = 600 }
    if ($body) { $p.Body = ($body | ConvertTo-Json -Depth 20); $p.ContentType = 'application/json' }
    $r = Invoke-RestMethod @p
  } catch { $r = @{ error = $_.Exception.Message; detail = "$($_.ErrorDetails.Message)" } }
  $sw.Stop()
  $o = @{ test = $name; date = (Get-Date -Format 'yyyy-MM-dd'); seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); request = $body; response = $r }
  # NOTE: reasoning/thinking text was trimmed to 300 chars in committed evidence files
  # reasoning/thinking text was later trimmed to 300 chars in the committed evidence files
  $o | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $OutDir "$name.json")
  $o
}
$tool = @{ type = 'function'; function = @{ name = 'read_file'; description = 'Read a text file'; parameters = @{ type = 'object'; properties = @{ path = @{ type = 'string' } }; required = @('path') } } }
$null = Call 'models' GET '/v1/models' $null
$null = Call 'chat' POST '/v1/chat/completions' @{ model = $Model; max_tokens = 1024; messages = @(@{ role = 'user'; content = 'Say hello in five words.' }) }
$t = Call 'tools' POST '/v1/chat/completions' @{ model = $Model; max_tokens = 2048; tools = @($tool); messages = @(@{ role = 'user'; content = 'Use the read_file tool to read notes.txt.' }) }
$m = $t.response.choices[0].message
if ($m.tool_calls) {
  $null = Call 'tool-roundtrip' POST '/v1/chat/completions' @{ model = $Model; max_tokens = 2048; tools = @($tool); messages = @(
    @{ role = 'user'; content = 'Use the read_file tool to read notes.txt.' },
    @{ role = 'assistant'; content = $m.content; tool_calls = $m.tool_calls },
    @{ role = 'tool'; tool_call_id = $m.tool_calls[0].id; content = 'The launch code word is BLUEBIRD.' },
    @{ role = 'user'; content = 'What is the code word? Answer in one sentence.' }) }
}
$schema = @{ type = 'object'; properties = @{ city = @{ type = 'string' }; population_millions = @{ type = 'number' } }; required = @('city', 'population_millions'); additionalProperties = $false }
$null = Call 'json-schema' POST '/v1/chat/completions' @{ model = $Model; max_tokens = 2048; messages = @(@{ role = 'user'; content = 'Give the capital of Norway and its population in millions.' }); response_format = @{ type = 'json_schema'; json_schema = @{ name = 'city'; strict = $true; schema = $schema } } }
$null = Call 'json-object' POST '/v1/chat/completions' @{ model = $Model; max_tokens = 2048; messages = @(@{ role = 'user'; content = 'Reply as JSON with keys city and population_millions for the capital of Norway.' }); response_format = @{ type = 'json_object' } }
$null = Call 'reasoning-effort' POST '/v1/chat/completions' @{ model = $Model; max_tokens = 1024; reasoning_effort = 'low'; messages = @(@{ role = 'user'; content = 'What is 17*23? Answer with the number only.' }) }
$null = Call 'anthropic-messages' POST '/v1/messages' @{ model = $Model; max_tokens = 1024; messages = @(@{ role = 'user'; content = 'Say hello in five words.' }) }
$null = Call 'anthropic-tools' POST '/v1/messages' @{ model = $Model; max_tokens = 2048; tools = @(@{ name = 'read_file'; description = 'Read a text file'; input_schema = @{ type = 'object'; properties = @{ path = @{ type = 'string' } }; required = @('path') } }); messages = @(@{ role = 'user'; content = 'Use the read_file tool to read notes.txt.' }) }
