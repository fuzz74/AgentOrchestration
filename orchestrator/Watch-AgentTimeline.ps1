#requires -Version 7.2
<#
.SYNOPSIS
    Follow the steps of an orchestrator run as a read-only teaching timeline.
.DESCRIPTION
    Combines orchestrator progress, saved agent prompts and selected JSONL events.
    Shows agent updates and tool outcomes, not private reasoning or raw tool output.
    Entries from an agent's sub-agents start with ↳ [description].
.EXAMPLE
    ./Watch-AgentTimeline.ps1 -RepoPath C:\src\myapp
.EXAMPLE
    ./Watch-AgentTimeline.ps1 -RepoPath C:\src\myapp -Task runtime-process -Once
#>
[CmdletBinding()]
param(
    [string]$RepoPath = '.',
    [string]$Task,
    [ValidateRange(1, 500)][int]$Last = 40,
    [ValidateRange(1, 60)][int]$RefreshSeconds = 2,
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Orchestrator.psm1') -Force
$paths = Get-OrchPaths -RepoPath $RepoPath
$offsets = @{}
$prompts = @{}
$toolStarts = @{}
$modelStarts = @{}
$subAgents = @{}   # events file -> its sub-agents' names
$progressCount = 0

function Get-AgentFiles {
    if (-not (Test-Path $paths.LogDir)) { return @() }
    @(Get-ChildItem $paths.LogDir -Recurse -File -Filter '*.events.jsonl' |
        Where-Object { -not $Task -or ([IO.Path]::GetRelativePath($paths.LogDir, $_.FullName).Split([IO.Path]::DirectorySeparatorChar)[0] -eq $Task) } |
        Sort-Object FullName)
}

function Get-AgentLabel([string]$Path) {
    $relative = [IO.Path]::GetRelativePath($paths.LogDir, $Path)
    $parts = $relative.Split([IO.Path]::DirectorySeparatorChar)
    $taskName = if ($parts.Length -gt 1) { $parts[0] } elseif ($parts[0] -match '^(planner|bootstrap)') { $Matches[1] } else { 'orchestrator' }
    $filename = [IO.Path]::GetFileName($Path)
    $role = if ($filename -match 'review') { 'review' } elseif ($filename -match 'worker') { 'worker' } elseif ($filename -match 'resolver') { 'resolver' } else { 'agent' }
    $attempt = if ($filename -match '^attempt-(\d+)') { "#$($Matches[1])" } else { '' }
    "$taskName/$role$attempt"
}

function New-TimelineEntry($Time, [string]$Source, [string]$Kind, [string]$Text) {
    [pscustomobject]@{ Time = $Time; Source = $Source; Kind = $Kind; Text = $Text }
}

function Get-ShortText([string]$Text) {
    $singleLine = ($Text -replace '\s+', ' ').Trim()
    if ($singleLine.Length -gt 160) { return $singleLine.Substring(0, 157) + '...' }
    $singleLine
}

function Convert-AgentEvent($Event, [string]$Label, [string]$File, [Collections.IDictionary]$Names) {
    $when = [datetimeoffset]::MinValue
    if ($Event.timestamp) { try { $when = [datetimeoffset]$Event.timestamp } catch { } }
    $sub = Get-SubAgentName $Event $Names
    $tag = if ($sub) { "↳ [$sub] " } else { '' }
    switch ($Event.type) {
        'model.call_start' {
            $key = "$File|$($Event.data.turnId)"
            if ($Event.data.turnId) { $modelStarts[$key] = $when }
            return New-TimelineEntry $when $Label 'MODEL' "${tag}Model call started"
        }
        'model.call_finished' {
            $key = "$File|$($Event.data.turnId)"
            $duration = ''
            if ($modelStarts.ContainsKey($key)) {
                $duration = " in $([math]::Round(($when - $modelStarts[$key]).TotalSeconds, 1))s"
                $modelStarts.Remove($key)
            }
            return New-TimelineEntry $when $Label 'MODEL' "${tag}Model call finished$duration"
        }
        'assistant.message' {
            if ($Event.data.phase -eq 'commentary' -and $Event.data.content) {
                return New-TimelineEntry $when $Label 'UPDATE' ($tag + (Get-ShortText $Event.data.content))
            }
            # A sub-agent's answer is news for the agent, not the agent's own result.
            if ($Event.data.phase -eq 'final_answer' -and $Event.data.content -and $sub) {
                return New-TimelineEntry $when $Label 'UPDATE' ($tag + (Get-ShortText $Event.data.content))
            }
            if ($Event.data.phase -eq 'final_answer' -and $Event.data.content) {
                $result = $null
                try { $result = $Event.data.content | ConvertFrom-Json -AsHashtable } catch { }
                if ($result -is [System.Collections.IDictionary]) {
                    if ($result.Contains('spec_verdict')) {
                        return New-TimelineEntry $when $Label 'REVIEW' "spec: $($result.spec_verdict), quality: $($result.quality_verdict)"
                    }
                    if ($result.Contains('status')) {
                        return New-TimelineEntry $when $Label 'RESULT' "agent reported $($result.status)"
                    }
                }
                return New-TimelineEntry $when $Label 'RESULT' (Get-ShortText $Event.data.content)
            }
        }
        'tool.execution_start' {
            $toolName = $Event.data.toolName ?? 'tool'
            $key = "$File|$($Event.data.toolCallId)"
            if ($Event.data.toolCallId) { $toolStarts[$key] = @{ Time = $when; Name = $toolName } }
            $detail = $Event.data.arguments.description ?? $Event.data.toolTitle ?? ''
            return New-TimelineEntry $when $Label 'TOOL START' ($tag + (Get-ShortText "$toolName $detail"))
        }
        'tool.execution_complete' {
            $key = "$File|$($Event.data.toolCallId)"
            $duration = ''
            $toolName = 'tool'
            if ($toolStarts.ContainsKey($key)) {
                $toolName = $toolStarts[$key].Name
                $duration = " in $([math]::Round(($when - $toolStarts[$key].Time).TotalSeconds, 1))s"
                $toolStarts.Remove($key)
            }
            $outcome = if ($Event.data.success -eq $true) { 'succeeded' } else { 'failed' }
            return New-TimelineEntry $when $Label 'TOOL END' "$tag$toolName $outcome$duration (output omitted)"
        }
        'assistant' {
            foreach ($block in @($Event.message.content)) {
                if ($block.type -eq 'tool_use') {
                    $toolName = $block.name ?? 'tool'
                    if ($block.id) { $toolStarts["$File|$($block.id)"] = @{ Time = $when; Name = $toolName } }
                    $detail = if ($toolName -match '^(Task|Agent)$') { " $($block.input.description)" }
                    New-TimelineEntry $when $Label 'TOOL START' ($tag + (Get-ShortText "$toolName$detail"))
                }
                elseif ($block.type -eq 'text' -and $block.text) {
                    New-TimelineEntry $when $Label 'UPDATE' ($tag + (Get-ShortText $block.text))
                }
            }
            return
        }
        'user' {
            foreach ($block in @($Event.message.content)) {
                if ($block.type -ne 'tool_result') { continue }
                $key = "$File|$($block.tool_use_id)"
                $toolName = 'tool'; $duration = ''
                if ($toolStarts.ContainsKey($key)) {
                    $toolName = $toolStarts[$key].Name
                    if ($when -ne [datetimeoffset]::MinValue -and $toolStarts[$key].Time -ne [datetimeoffset]::MinValue) {
                        $duration = " in $([math]::Round(($when - $toolStarts[$key].Time).TotalSeconds, 1))s"
                    }
                    $toolStarts.Remove($key)
                }
                $outcome = if ($block.is_error) { 'failed' } else { 'completed' }
                New-TimelineEntry $when $Label 'TOOL END' "$tag$toolName $outcome$duration (output omitted)"
            }
            return
        }
        'result' {
            if (-not $Event.Contains('structured_output')) { return }
            $result = $Event.structured_output
            if ($result -is [System.Collections.IDictionary] -and $result.Contains('spec_verdict')) {
                return New-TimelineEntry $when $Label 'REVIEW' "spec: $($result.spec_verdict), quality: $($result.quality_verdict)"
            }
            if ($result -is [System.Collections.IDictionary] -and $result.Contains('status')) {
                return New-TimelineEntry $when $Label 'RESULT' "agent reported $($result.status)"
            }
            return New-TimelineEntry $when $Label 'RESULT' $(if ($Event.is_error) { 'Agent failed' } else { 'Agent completed' })
        }
    }
}

function Read-AgentFile([IO.FileInfo]$File) {
    $promptPath = $File.FullName -replace '\.events\.jsonl$', '.prompt.md'
    $label = Get-AgentLabel $File.FullName
    if (-not $prompts.ContainsKey($promptPath) -and (Test-Path $promptPath)) {
        $prompts[$promptPath] = $true
        New-TimelineEntry ([datetimeoffset](Get-Item $promptPath).LastWriteTimeUtc) $label 'PROMPT' 'Orchestrator saved the instructions sent to this agent.'
    }
    $position = [long]($offsets[$File.FullName] ?? 0L)
    try { $stream = [IO.FileStream]::new($File.FullName, 'Open', 'Read', 'ReadWrite, Delete') }
    catch { return }
    try {
        if ($stream.Length -lt $position) { $position = 0; $subAgents.Remove($File.FullName) }
        $length = [int]($stream.Length - $position)
        if ($length -eq 0) { return }
        $buffer = [byte[]]::new($length)
        [void]$stream.Seek($position, 'Begin')
        $read = 0
        while ($read -lt $length) {
            $count = $stream.Read($buffer, $read, $length - $read)
            if ($count -eq 0) { break }
            $read += $count
        }
        if ($read -eq 0) { return }
        $end = [Array]::LastIndexOf($buffer, [byte]10, $read - 1)
        if ($end -lt 0) { return }
        $offsets[$File.FullName] = $position + $end + 1
        if (-not $subAgents.ContainsKey($File.FullName)) { $subAgents[$File.FullName] = @{} }
        foreach ($line in [Text.Encoding]::UTF8.GetString($buffer, 0, $end + 1).Split("`n")) {
            if (-not $line.TrimStart().StartsWith('{')) { continue }
            try {
                $event = $line | ConvertFrom-Json -AsHashtable
                if (-not $event.timestamp) { $event.timestamp = $File.LastWriteTimeUtc }
                $item = Convert-AgentEvent $event $label $File.FullName $subAgents[$File.FullName]
                if ($item) { $item }
            }
            catch { continue }
        }
    }
    finally { $stream.Dispose() }
}

function Read-OrchestratorProgress {
    if (-not (Test-Path $paths.ProgressFile)) { return }
    $lines = @(Get-Content $paths.ProgressFile -ErrorAction SilentlyContinue)
    if ($lines.Count -lt $script:progressCount) { $script:progressCount = 0 }
    foreach ($line in ($lines | Select-Object -Skip $script:progressCount)) {
        if ($line -notmatch '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)  (.*)$') { continue }
        $when = [datetimeoffset]([datetime]$Matches[1])
        $message = $Matches[2]
        $source = 'orchestrator'
        if ($message -match '^\[([^\]]+)\] (.*)$') {
            $source = $Matches[1]
            $message = $Matches[2]
        }
        if ($Task -and $source -notin $Task, 'orchestrator') { continue }
        $stage = switch -Regex ($message) {
            '^Run started:' { 'Run started'; break }
            '^Run finished:' { 'Run finished'; break }
            '^started \(' { 'Task started'; break }
            '^attempt .*worker started' { 'Worker started'; break }
            '^acceptance:' { 'Acceptance check started'; break }
            '^review started' { 'Review started'; break }
            '^review rejected' { 'Review rejected'; break }
            '^DONE:' { 'Task completed'; break }
            '^FAILED:' { 'Task failed'; break }
            default { $null }
        }
        if ($stage) { New-TimelineEntry $when $source 'ORCH' $stage }
    }
    $script:progressCount = $lines.Count
}

function Get-NewTimeline {
    @(Read-OrchestratorProgress) + @(Get-AgentFiles | ForEach-Object { Read-AgentFile $_ }) |
        Where-Object { $_ } | Sort-Object Time
}

function Format-TimelineEntry($Entry) {
    '[{0}][{1}][{2}] {3}' -f $Entry.Time.ToLocalTime().ToString('HH:mm:ss'), $Entry.Source, $Entry.Kind, $Entry.Text
}

$history = [Collections.Generic.List[object]]::new()
foreach ($entry in @(Get-NewTimeline | Select-Object -Last $Last)) { $history.Add($entry) }
if ($Once) {
    Write-Host "Agent timeline: $($paths.Repo)$(if ($Task) { " / $Task" })"
    foreach ($entry in $history) { Write-Host (Format-TimelineEntry $entry) }
    return
}
if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { throw 'Interactive terminal required; use -Once for redirected I/O.' }

$top = 0
$follow = $true
$quit = $false
[Console]::Write("`e[?1049h`e[?25l`e[?1007h")
try {
    while (-not $quit) {
        foreach ($entry in @(Get-NewTimeline)) { $history.Add($entry) }
        $height = [math]::Max(4, [Console]::WindowHeight - 1)
        $width = [math]::Max(20, [Console]::WindowWidth - 1)
        $page = $height - 3
        $max = [math]::Max(0, $history.Count - $page)
        if ($follow) { $top = $max }
        $top = [math]::Min($max, $top)
        $output = [Text.StringBuilder]::new("`e[H")
        $title = "Agent timeline: $($paths.Repo)$(if ($Task) { " / $Task" })"
        $legend = 'ORCH decisions | PROMPT instructions | MODEL call | UPDATE commentary | TOOL action | REVIEW/RESULT outcome | ↳ [name] sub-agent'
        [void]$output.Append($title.Substring(0, [math]::Min($width, $title.Length))).Append("`e[K`n")
        [void]$output.Append($legend.Substring(0, [math]::Min($width, $legend.Length))).Append("`e[K`n")
        foreach ($entry in ($history | Select-Object -Skip $top -First $page)) {
            $line = Format-TimelineEntry $entry
            [void]$output.Append($line.Substring(0, [math]::Min($width, $line.Length))).Append("`e[K`n")
        }
        $footer = "Up/Down, PgUp/PgDn, Home/End: scroll  |  Q: quit  |  $(if ($follow) { 'following' } else { 'paused' })"
        [void]$output.Append($footer.Substring(0, [math]::Min($width, $footer.Length))).Append("`e[K`n`e[J")
        [Console]::Write($output.ToString())
        $next = (Get-Date).AddSeconds($RefreshSeconds)
        while ((Get-Date) -lt $next -and -not $quit) {
            if ([Console]::KeyAvailable) {
                switch ([Console]::ReadKey($true).Key) {
                    'Q' { $quit = $true }
                    'UpArrow' { $follow = $false; $top = [math]::Max(0, $top - 1); $next = Get-Date }
                    'DownArrow' { $top = [math]::Min($max, $top + 1); $follow = $top -eq $max; $next = Get-Date }
                    'PageUp' { $follow = $false; $top = [math]::Max(0, $top - $page); $next = Get-Date }
                    'PageDown' { $top = [math]::Min($max, $top + $page); $follow = $top -eq $max; $next = Get-Date }
                    'Home' { $follow = $false; $top = 0; $next = Get-Date }
                    'End' { $follow = $true; $top = $max; $next = Get-Date }
                }
            }
            else { [Threading.Thread]::Sleep(30) }
        }
    }
}
finally { [Console]::Write("`e[?1007l`e[?25h`e[?1049l") }