# Streaming probe: reads SSE lines from Ollama /v1/chat/completions. Run: pwsh -File probe-stream.ps1 -OutDir <dir>
param([string]$OutDir = '.', [string]$Model = 'huihui_ai/gemma-4-abliterated:26b', [string]$Base = 'http://localhost:11434')
$tool = @{ type = 'function'; function = @{ name = 'read_file'; description = 'Read a text file'; parameters = @{ type = 'object'; properties = @{ path = @{ type = 'string' } }; required = @('path') } } }
function Stream($name, $body) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $c = [Net.Http.HttpClient]::new(); $c.Timeout = [TimeSpan]::FromMinutes(10)
  $req = [Net.Http.HttpRequestMessage]::new('POST', "$Base/v1/chat/completions")
  $req.Content = [Net.Http.StringContent]::new(($body | ConvertTo-Json -Depth 20), [Text.Encoding]::UTF8, 'application/json')
  $resp = $c.SendAsync($req, 'ResponseHeadersRead').GetAwaiter().GetResult()
  $rd = [IO.StreamReader]::new($resp.Content.ReadAsStream())
  $lines = [Collections.Generic.List[string]]::new(); $first = $null
  while (($l = $rd.ReadLine()) -ne $null) { if ($l) { $lines.Add($l); if (-not $first) { $first = $sw.Elapsed.TotalSeconds } } }
  $sw.Stop()
  $o = @{ test = $name; date = (Get-Date -Format 'yyyy-MM-dd'); seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); first_chunk_seconds = [math]::Round($first, 1); content_type = "$($resp.Content.Headers.ContentType)"; chunk_count = $lines.Count; first_chunks = @($lines | Select-Object -First 3); last_chunks = @($lines | Select-Object -Last 3); all_tool_chunks = @($lines | Where-Object { $_ -match 'tool_calls' }) }
  $o | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutDir "$name.json")
}
Stream 'stream-chat' @{ model = $Model; max_tokens = 1024; stream = $true; stream_options = @{ include_usage = $true }; messages = @(@{ role = 'user'; content = 'Say hello in five words.' }) }
Stream 'stream-tools' @{ model = $Model; max_tokens = 2048; stream = $true; stream_options = @{ include_usage = $true }; tools = @($tool); messages = @(@{ role = 'user'; content = 'Use the read_file tool to read notes.txt.' }) }
