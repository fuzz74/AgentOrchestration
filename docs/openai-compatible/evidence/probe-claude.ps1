# Bounded Claude Code probe against Ollama /v1/messages. Run: pwsh -File probe-claude.ps1 -OutFile <file> [-Prompt ...]
# Run 1 (before the quoting fix) passed only the first word of the prompt to -p; see endpoint-findings.md.
param([string]$OutFile = 'claude-probe-raw.jsonl', [string]$Model = 'huihui_ai/gemma-4-abliterated:26b',
  [string]$Prompt = "Use the Glob tool with pattern '*' to list files in the current directory. Then reply with one sentence stating how many files you found.")
$dir = Join-Path $env:TEMP ("claude-probe-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $dir | Out-Null
Get-ChildItem Env: | Where-Object { $_.Name -eq 'CLAUDECODE' -or $_.Name -like 'CLAUDE_CODE_*' } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
$env:ANTHROPIC_BASE_URL = 'http://localhost:11434'
$env:ANTHROPIC_AUTH_TOKEN = 'ollama'
Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
Push-Location $dir
$sw = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process claude -ArgumentList @('-p', ('"' + $Prompt + '"'), '--model', $Model, '--output-format', 'stream-json', '--verbose', '--tools', 'Read,Glob,Grep', '--allowedTools', 'Read,Glob,Grep') -NoNewWindow -PassThru -RedirectStandardOutput $OutFile -RedirectStandardError "$OutFile.err"
if (-not $p.WaitForExit(600000)) { $p.Kill($true); 'TIMEOUT after 600 s' | Add-Content "$OutFile.err" }
$sw.Stop(); Pop-Location
"exit=$($p.ExitCode) seconds=$([math]::Round($sw.Elapsed.TotalSeconds, 1))"
Remove-Item $dir -Recurse -Force
