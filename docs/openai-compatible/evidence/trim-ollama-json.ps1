# Trim reasoning/thinking strings to 300 chars in the Ollama evidence JSON files. Run in the evidence folder.
function Cut($o) {
  foreach ($p in @($o.PSObject.Properties)) {
    $v = $p.Value
    if ($v -is [string] -and $p.Name -in 'reasoning', 'thinking' -and $v.Length -gt 300) { $p.Value = $v.Substring(0, 300) + '...[trimmed]' }
    elseif ($v -is [pscustomobject]) { Cut $v }
    elseif ($v -is [array]) { foreach ($i in $v) { if ($i -is [pscustomobject]) { Cut $i } } }
  }
}
Get-ChildItem *.json | Where-Object Name -notlike 'stream-*' | ForEach-Object {
  $o = Get-Content $_ -Raw | ConvertFrom-Json -Depth 30; Cut $o; $o | ConvertTo-Json -Depth 30 | Set-Content $_
}
