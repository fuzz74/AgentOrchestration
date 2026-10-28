# Trim a claude stream-json run: drop thinking_tokens noise, shorten init and thinking text. Run: pwsh -File trim-claude-run.ps1 -In raw.jsonl -Out trimmed.jsonl
param([string]$In, [string]$Out)
$n = 0
Get-Content $In | ForEach-Object {
  $e = $_ | ConvertFrom-Json -Depth 30
  if ($e.type -eq 'system' -and $e.subtype -eq 'thinking_tokens') { $n++; return }
  if ($e.type -eq 'system' -and $e.subtype -eq 'init') { $e = [pscustomobject]@{ type = 'system'; subtype = 'init'; model = $e.model; tools = $e.tools; permissionMode = $e.permissionMode; session_id = $e.session_id; claude_code_version = $e.claude_code_version; note = 'cwd, slash_commands, skills, plugins omitted' } }
  if ($e.type -eq 'assistant') { foreach ($c in $e.message.content) { if ($c.type -eq 'thinking') { $c.thinking = "[omitted: $("$($c.thinking)".Length) chars]"; $c.signature = $null } }; $e.message.usage = $null }
  $e | ConvertTo-Json -Depth 30 -Compress
} | Set-Content $Out
"thinking_tokens events dropped: $n" | Add-Content $Out
