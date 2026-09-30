#requires -Version 7.2
<#
.SYNOPSIS
    Live dashboard of an orchestrator run: total progress, what every running agent is doing,
    and the latest log lines.

.DESCRIPTION
    Read-only. Run it in a second terminal while Invoke-Orchestrator.ps1 or Plan-Tasks.ps1 runs.
    It reads .orchestrator/tasks.json, state.json, progress.md and the agents' *.events.jsonl
    logs, and redraws every few seconds. Press Ctrl+C to quit; the run is not affected.

.EXAMPLE
    ./Watch-Orchestrator.ps1 -Provider Copilot -RepoPath C:\src\myapp
.EXAMPLE
    ./Watch-Orchestrator.ps1 -Provider Copilot -RepoPath C:\src\myapp -Once    # print one snapshot and exit
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Claude', 'Copilot')][string]$Provider,
    [string]$RepoPath = '.',
    [string]$Plan,
    [ValidateRange(1, 60)][int]$RefreshSeconds = 2,
    [ValidateRange(1, 20)][int]$ActivityLines = 10,
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Orchestrator.psm1') -Force
$paths = Get-OrchPaths -RepoPath $RepoPath -PlanFile $Plan
$repoName = Split-Path $paths.Repo -Leaf

$feeds = @{}        # events file -> what has been read from it so far
$costs = @{}        # result file -> total_cost_usd
$reviews = @{}      # review events file + size -> parsed verdict
$planCache = @{ Stamp = $null; Plan = $null; Waves = @{} }
$lastState = [ordered]@{ tasks = [ordered]@{} }

#region Reading

function Update-Feed([string]$File, [string]$WorkDir) {
    # Reads the lines appended since the last call; only whole lines, so a line being written waits.
    $f = $feeds[$File]
    if (-not $f) {
        $f = @{ Pos = 0L; Calls = 0; Recent = [Collections.Generic.List[string]]::new(); Done = $false; LastAt = (Get-Item $File).LastWriteTime }
        $feeds[$File] = $f
    }
    try { $fs = [IO.FileStream]::new($File, 'Open', 'Read', 'ReadWrite, Delete') } catch { return $f }
    try {
        if ($fs.Length -lt $f.Pos) { $f.Pos = 0L; $f.Calls = 0; $f.Recent.Clear(); $f.Done = $false }
        $len = [int]($fs.Length - $f.Pos)
        if ($len -le 0) { return $f }
        $buf = [byte[]]::new($len)
        [void]$fs.Seek($f.Pos, 'Begin')
        $read = 0
        while ($read -lt $len) { $n = $fs.Read($buf, $read, $len - $read); if ($n -le 0) { break }; $read += $n }
    }
    finally { $fs.Dispose() }
    $end = [Array]::LastIndexOf($buf, [byte]10, $read - 1)
    if ($end -lt 0) { return $f }
    $f.Pos += $end + 1
    # Windows updates LastWriteTime lazily while the writer keeps the file open; track growth instead.
    $f.LastAt = Get-Date
    foreach ($line in [Text.Encoding]::UTF8.GetString($buf, 0, $end + 1).Split("`n")) {
        if (-not $line.TrimStart().StartsWith('{')) { continue }
        try { $ev = $line | ConvertFrom-Json -AsHashtable } catch { continue }
        if ($ev.type -eq 'result') { $f.Done = $true; continue }
        if ($ev.type -eq 'tool.execution_start') {
            $f.Calls++; $f.Recent.Add("$($ev.data.toolName) $($ev.data.arguments.path ?? '')".Trim())
            continue
        }
        if ($ev.type -eq 'assistant.message' -and $ev.data.phase -eq 'final_answer') {
            $f.Recent.Add('» ' + (("$($ev.data.content)".Trim() -split "`r?`n")[0]))
            continue
        }
        if ($ev.type -ne 'assistant') { continue }
        foreach ($b in @($ev.message.content)) {
            if ($b -isnot [Collections.IDictionary]) { continue }
            if ($b.type -eq 'tool_use') { $f.Calls++; $f.Recent.Add((Format-ToolUse $b $WorkDir)) }
            elseif ($b.type -eq 'text' -and "$($b.text)".Trim()) {
                $f.Recent.Add('» ' + (("$($b.text)".Trim() -split "`r?`n")[0]))
            }
        }
    }
    while ($f.Recent.Count -gt $ActivityLines) { $f.Recent.RemoveAt(0) }
    $f
}

function Get-ResultCost([IO.FileInfo]$File) {
    $key = "$($File.FullName)|$($File.Length)"
    if (-not $costs.ContainsKey($key)) {
        $c = 0.0
        try { $c = [double]((Get-Content $File.FullName -Raw | ConvertFrom-Json).total_cost_usd ?? 0) } catch { }
        $costs[$key] = $c
    }
    $costs[$key]
}

function Get-LatestLogDir([string]$Id) {
    $root = Join-Path $paths.LogDir $Id
    if (-not (Test-Path $root)) { return $null }
    Get-ChildItem $root -Directory | Sort-Object Name | Select-Object -Last 1
}

function Get-ReviewFeedback([string]$Id) {
    $root = Join-Path $paths.LogDir $Id
    if (-not (Test-Path $root)) { return $null }
    $files = Get-ChildItem $root -Recurse -File -Filter 'attempt-*-review-*.json.events.jsonl' |
        Sort-Object LastWriteTime -Descending
    foreach ($file in $files) {
        $key = "$($file.FullName)|$($file.Length)"
        if ($reviews.ContainsKey($key)) { return $reviews[$key] }
        $final = Get-Content $file.FullName -Tail 80 | ForEach-Object {
            try { $_ | ConvertFrom-Json -AsHashtable } catch { $null }
        } | Where-Object { $_.type -eq 'assistant.message' -and $_.data.phase -eq 'final_answer' } |
            Select-Object -Last 1
        if (-not $final) { continue }
        try {
            $content = $final.data.content.Trim() -replace '^```(?:json)?\s*', '' -replace '\s*```$', ''
            $verdict = $content | ConvertFrom-Json -AsHashtable
            if (-not $verdict.ContainsKey('issues')) { continue }
            $feedback = if ($verdict.spec_verdict -eq 'pass' -and $verdict.quality_verdict -eq 'pass') { $null }
                        else { $verdict }
            $reviews[$key] = $feedback
            return $feedback
        }
        catch { continue }
    }
    $null
}

function Get-AgentView([string]$Id) {
    # What a running task is doing now, from the newest files in its latest log folder.
    $dir = Get-LatestLogDir $Id
    $view = @{ Phase = 'starting'; Kind = $null; Feed = $null; Idle = $null; Cost = 0.0 }
    if (-not $dir) { return $view }
    $files = @(Get-ChildItem $dir.FullName -File | Sort-Object LastWriteTime)
    foreach ($r in ($files | Where-Object { $_.Extension -eq '.json' })) { $view.Cost += Get-ResultCost $r }
    $newest = $files | Select-Object -Last 1
    $events = $files | Where-Object { $_.Name -like '*.events.jsonl' } | Select-Object -Last 1
    if ($newest) {
        $n = if ($newest.Name -match '^attempt-(\d+)') { $Matches[1] } else { $null }
        $view.Phase = switch -Regex ($newest.Name) {
            '^setup\.log$' { 'setup command' }
            '-acceptance\.log$' { "acceptance check (attempt $n)" }
            '-worker\.json' { "worker (attempt $n)" }
            '-review-\d+\.json' { "review (attempt $n)" }
            '-resolver\.json' { "resolving merge conflicts (attempt $n)" }
            default { $newest.Name }
        }
        $view.Kind = switch -Regex ($newest.Name) { '-worker\.json' { 'worker' } '-review-' { 'reviewer' } '-resolver' { 'resolver' } }
        if ($newest.Extension -eq '.json') { $view.Phase += ' - finished, checking'; $view.Kind = $null }
        $view.Idle = (Get-Date) - $newest.LastWriteTime
    }
    # After the pipeline, the main loop merges and runs the integration check (logs in the log root).
    $check = Get-ChildItem $paths.LogDir -File -Filter "$Id-integration-*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1
    if ($check -and (-not $newest -or $check.LastWriteTime -gt $newest.LastWriteTime)) {
        $view.Phase = 'merged; running the integration check'
        $view.Kind = $null
        $view.Idle = (Get-Date) - $check.LastWriteTime
    }
    if ($events) {
        $view.Feed = Update-Feed $events.FullName (Join-Path $paths.WorktreeRoot $Id)
        if ($view.Kind -and $view.Feed.LastAt -gt $newest.LastWriteTime) { $view.Idle = (Get-Date) - $view.Feed.LastAt }
    }
    if ($view.Feed -and $view.Feed.Done) { $view.Kind = $null }
    $view
}

function Get-PlanInfo {
    if (-not (Test-Path $paths.PlanFile)) { $planCache.Plan = $null; return $null }
    $stamp = (Get-Item $paths.PlanFile).LastWriteTimeUtc
    if ($planCache.Stamp -ne $stamp) {
        try {
            $planCache.Plan = Read-Plan -PlanFile $paths.PlanFile -Repo $paths.Repo
            $planCache.Waves = Get-Waves $planCache.Plan.Tasks
            $planCache.Stamp = $stamp
        }
        catch { }   # being rewritten; keep the previous plan
    }
    $planCache.Plan
}

function Get-StateSafe {
    try { $script:lastState = Read-State $paths } catch { }   # mid-write; keep the previous state
    $script:lastState
}

function Get-AgentProcesses {
    if (-not $IsWindows) { return @{ Available = $false; Processes = @() } }
    $name = if ($Provider -eq 'Copilot') { 'copilot.exe' } else { 'claude.exe' }
    try {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -match '(?i)--output-format(?:=|\s+)' } |
            ForEach-Object {
                $taskId = if ($_.CommandLine -match '(?i)(?:^|\s)--name\s+"?orch:([a-z0-9][a-z0-9._-]{0,48})(?::(?:review|resolve))?(?=["\s]|$)') { $Matches[1] } else { $null }
                [pscustomobject]@{ ProcessId = $_.ProcessId; Name = $_.Name; TaskId = $taskId; StartedAt = $_.CreationDate }
            } | Sort-Object ProcessId)
        return @{ Available = $true; Processes = $processes }
    }
    catch { return @{ Available = $false; Processes = @() } }
}

function Get-ProgressLines {
    if (-not (Test-Path $paths.ProgressFile)) { return @() }
    @(Get-Content $paths.ProgressFile -Tail 400 -ErrorAction SilentlyContinue)
}

#endregion

#region Formatting

function Format-Span([TimeSpan]$t) {
    if ($null -eq $t) { return '' }
    if ($t.TotalHours -ge 1) { return '{0}h{1:00}m' -f [int][math]::Floor($t.TotalHours), $t.Minutes }
    if ($t.TotalMinutes -ge 1) { return '{0}m{1:00}s' -f [int][math]::Floor($t.TotalMinutes), $t.Seconds }
    '{0}s' -f [int][math]::Max(0, $t.TotalSeconds)
}

function Get-LogTime([string]$Line) {
    if ($Line -match '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)') { return [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null) }
    $null
}

function Format-WrappedFeedback([string]$Text, [string]$Prefix, [int]$Width) {
    $indent = ' ' * $Prefix.Length
    $remaining = $Text.Trim()
    while ($remaining) {
        $room = [math]::Max(1, $Width - $Prefix.Length)
        if ($remaining.Length -le $room) { "$Prefix$remaining"; break }
        $cut = $remaining.LastIndexOf(' ', $room)
        if ($cut -le 0) { $cut = $room }
        "$Prefix$($remaining.Substring(0, $cut))"
        $remaining = $remaining.Substring($cut).TrimStart()
        $Prefix = $indent
    }
}

$ansi = @{
    White = "`e[97m"; Gray = "`e[37m"; DarkGray = "`e[90m"; Green = "`e[32m"; Cyan = "`e[36m"
    Red = "`e[91m"; Yellow = "`e[93m"; DarkYellow = "`e[33m"; Reset = "`e[0m"
}

$statusLook = @{
    done    = @{ Icon = '✔'; Color = 'Green' }
    running = @{ Icon = '▶'; Color = 'Cyan' }
    pending = @{ Icon = '·'; Color = 'DarkGray' }
    failed  = @{ Icon = '✖'; Color = 'Red' }
    blocked = @{ Icon = '⊘'; Color = 'DarkYellow' }
}

#endregion

#region Building the screen

function New-Screen {
    $lines = [Collections.Generic.List[object]]::new()
    $add = { param($text, $color = 'Gray') $lines.Add(@{ Text = "$text"; Color = $color }) }
    $now = Get-Date
    $plan = Get-PlanInfo
    $state = Get-StateSafe
    $log = Get-ProgressLines
    $agentProcesses = Get-AgentProcesses

    $iStart = -1; $iEnd = -1; $iPlan = -1
    for ($i = 0; $i -lt $log.Count; $i++) {
        if ($log[$i] -match '  Run started:') { $iStart = $i }
        elseif ($log[$i] -match '  Run finished:') { $iEnd = $i }
        elseif ($log[$i] -match '  Planning from |\[bootstrap\] Creating') { $iPlan = $i }
    }
    $runState = if ($iStart -ge 0 -and $iEnd -gt $iStart) { 'finished' }
                elseif ($iStart -ge 0) { 'running' }
                elseif ($iPlan -ge 0 -and -not $plan) { 'planning' }
                else { 'not started' }

    & $add ("{0} - orchestrator {1}{2}" -f $repoName, $runState, (' ' * 4) + $now.ToString('HH:mm:ss')) 'White'
    if ($iStart -ge 0) {
        $started = Get-LogTime $log[$iStart]
        $until = if ($runState -eq 'finished') { Get-LogTime $log[$iEnd] } else { $now }
        & $add ("Run started {0}, elapsed {1}" -f $started.ToString('HH:mm:ss'), (Format-Span ($until - $started))) 'DarkGray'
    }
    & $add ''
    & $add "Live $Provider CLI processes (system-wide; task name is not repo-verified)" 'White'
    if (-not $agentProcesses.Available) { & $add '  Process lookup unavailable' 'DarkYellow' }
    elseif (-not $agentProcesses.Processes.Count) { & $add '  (none detected)' 'DarkGray' }
    else {
        foreach ($process in $agentProcesses.Processes) {
            $task = if ($process.TaskId) { "  task $($process.TaskId)" } else { '  task unknown' }
            & $add ("  PID {0}  {1}{2}" -f $process.ProcessId, $process.Name, $task) 'Cyan'
        }
    }

    if (-not $plan) {
        & $add ''
        & $add "No plan yet ($($paths.PlanFile))." 'DarkYellow'
        $agent = Get-ChildItem $paths.LogDir -Recurse -File -Filter '*.events.jsonl' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '[\\/](planner-|bootstrap-)' } | Sort-Object LastWriteTime | Select-Object -Last 1
        if ($agent) {
            $f = Update-Feed $agent.FullName $paths.Repo
            $who = if ($agent.FullName -match 'planner-') { 'planner' } else { 'bootstrap (project skeleton)' }
            $status = if ($f.Done) { 'finished' } else { 'working' }
            & $add ''
            & $add ("▶ {0} - {1} · {2} tool calls · last activity {3} ago" -f $who, $status, $f.Calls, (Format-Span ($now - $f.LastAt))) 'Cyan'
            foreach ($r in $f.Recent) { & $add "    $r" }
        }
    }
    else {
        $tasks = $plan.Tasks
        $status = @{}
        foreach ($t in $tasks) { $status[$t.id] = Get-TaskDisplayStatus $t $plan $state }
        $count = { param($s) @($tasks | Where-Object { $status[$_.id] -eq $s }).Count }
        $total = $tasks.Count
        $done = & $count 'done'
        $width = 30
        $filled = if ($total) { [int][math]::Round($width * $done / $total) } else { 0 }
        $pct = if ($total) { [int][math]::Round(100 * $done / $total) } else { 0 }
        & $add ''
        & $add ("[{0}{1}] {2}/{3} done ({4}%)" -f ('█' * $filled), ('░' * ($width - $filled)), $done, $total, $pct) 'White'
        & $add ''

        $views = @{}
        $cost = 0.0
        foreach ($t in $tasks) {
            $s = $state.tasks[$t.id]
            if ($s) { $cost += [double]$s.costUsd }
            if ($status[$t.id] -eq 'running') { $views[$t.id] = Get-AgentView $t.id; $cost += $views[$t.id].Cost }
        }
        & $add ("{0} running · {1} pending · {2} failed · {3} blocked · cost ≈ {4:N2} USD" -f
            (& $count 'running'), (& $count 'pending'), (& $count 'failed'), (& $count 'blocked'), $cost)
        $agents = @($views.Keys | Sort-Object | Where-Object { $views[$_].Kind } | ForEach-Object { "$($views[$_].Kind) $_" })
        $between = @($views.Keys | Where-Object { -not $views[$_].Kind }).Count
        $max = if ($iStart -ge 0 -and $log[$iStart] -match 'max (\d+) in parallel') { " (max $($Matches[1]) tasks in parallel)" } else { '' }
        $who = if ($agents.Count) { ': ' + ($agents -join ', ') } else { '' }
        $gap = if ($between) { " · $between task(s) between agents (setup, checks, merge)" } else { '' }
        $agentColor = if ($agents.Count) { 'Cyan' } else { 'DarkGray' }
        & $add ("Agents working: {0}{1}{2}{3}" -f $agents.Count, $max, $who, $gap) $agentColor

        & $add ''
        & $add 'Running agents' 'White'
        $running = @($tasks | Where-Object { $status[$_.id] -eq 'running' })
        if (-not $running.Count) { & $add '  (none)' 'DarkGray' }
        foreach ($t in $running) {
            $v = $views[$t.id]
            $s = $state.tasks[$t.id]
            $startedAt = if ($s.startedAt) { [datetime]$s.startedAt } else { [datetime]::MinValue }
            $matched = @($agentProcesses.Processes | Where-Object {
                $_.TaskId -eq $t.id -and $_.StartedAt -ge $startedAt.AddSeconds(-5)
            })
            $pids = if ($matched.Count) { " · PID $(($matched.ProcessId -join ', '))" } else { '' }
            $since = if ($s.startedAt) { Format-Span ($now - [datetime]$s.startedAt) } else { '' }
            $calls = if ($v.Feed) { " · $($v.Feed.Calls) tool calls" } else { '' }
            $idle = if ($null -ne $v.Idle) { " · last activity $(Format-Span $v.Idle) ago" } else { '' }
            $warn = if ($null -ne $v.Idle -and $v.Idle.TotalMinutes -ge 5) { 'Yellow' } else { 'Cyan' }
            & $add ("▶ {0} - {1}{2}{3}{4} · running {5}" -f $t.id, $v.Phase, $pids, $calls, $idle, $since) $warn
            if ($v.Feed) { foreach ($r in $v.Feed.Recent) { & $add "    $r" } }
        }

        $feedback = @($tasks | Where-Object { $status[$_.id] -in 'running', 'failed' } |
            ForEach-Object { $review = Get-ReviewFeedback $_.id; if ($review) { [pscustomobject]@{ Id = $_.id; Review = $review } } })
        if ($feedback.Count) {
            & $add ''
            & $add 'Latest review feedback' 'White'
            try { $width = [math]::Max(40, [Console]::WindowWidth - 1); $short = [Console]::WindowHeight -lt 35 }
            catch { $width = 160; $short = $false }
            foreach ($item in $feedback) {
                $review = $item.Review
                & $add ("  {0}: spec {1}, quality {2}" -f $item.Id, $review.spec_verdict, $review.quality_verdict) 'Yellow'
                foreach ($line in (Format-WrappedFeedback $review.summary '    ' $width)) { & $add $line 'Yellow' }
                $issues = @($review.issues)
                foreach ($issue in ($issues | Select-Object -First $(if ($short) { 1 } else { $issues.Count }))) {
                    foreach ($line in (Format-WrappedFeedback $issue.description '    - ' $width)) { & $add $line 'Yellow' }
                }
                if ($short -and $issues.Count -gt 1) { & $add "    + $($issues.Count - 1) more issue(s) in the review log" 'DarkYellow' }
            }
        }

        & $add ''
        & $add 'Tasks' 'White'
        $idWidth = [math]::Min(24, ($tasks | ForEach-Object { $_.id.Length } | Measure-Object -Maximum).Maximum)
        foreach ($t in ($tasks | Sort-Object { $planCache.Waves[$_.id] }, id)) {
            $st = $status[$t.id]; $s = $state.tasks[$t.id]; $look = $statusLook[$st]
            $detail = switch ($st) {
                'done' { '{0:N2} USD, {1} attempt(s)' -f [double]$s.costUsd, $s.attempts }
                'running' { $views[$t.id].Phase }
                'failed' { (("$($s.error)" -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1) }
                'blocked' { 'a dependency failed' }
                default {
                    $open = @($t.deps | Where-Object { $status[$_] -ne 'done' })
                    if ($open.Count) { "waiting for $($open -join ', ')" } else { 'ready' }
                }
            }
            & $add ("{0} {1} W{2}  {3}  {4}" -f $look.Icon, $t.id.PadRight($idWidth), $planCache.Waves[$t.id], $t.title, "- $detail") $look.Color
        }
    }

    & $add ''
    & $add 'Recent log' 'White'
    foreach ($l in ($log | Select-Object -Last 8)) {
        $color = if ($l -match 'FAILED|error') { 'Red' } elseif ($l -match 'DONE|passed') { 'Green' } else { 'DarkGray' }
        & $add ($l -replace '^\d{4}-\d\d-\d\d ', '') $color
    }
    $lines
}

function Write-Screen($Lines, [switch]$Plain) {
    try { $w = [math]::Max(40, [Console]::WindowWidth - 1); $h = [math]::Max(10, [Console]::WindowHeight - 1) }
    catch { $w = 160; $h = 60 }   # no console window (output redirected)
    $sb = [Text.StringBuilder]::new()
    if (-not $Plain) { [void]$sb.Append("`e[H") }
    $shown = 0
    foreach ($l in $Lines) {
        if (-not $Plain -and $shown -ge $h) { break }
        $text = $l.Text
        if ($text.Length -gt $w) { $text = $text.Substring(0, $w - 1) + '…' }
        [void]$sb.Append($ansi[$l.Color]).Append($text).Append($ansi.Reset)
        if (-not $Plain) { [void]$sb.Append("`e[K") }
        [void]$sb.Append("`n")
        $shown++
    }
    if (-not $Plain) { [void]$sb.Append("`e[J") }
    [Console]::Write($sb.ToString())
}

#endregion

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
if ($Once) { Write-Screen (New-Screen) -Plain; return }

[Console]::Write("`e[?1049h`e[?25l")   # alternate screen, hide cursor
try {
    while ($true) {
        Write-Screen (New-Screen)
        Start-Sleep -Seconds $RefreshSeconds
    }
}
finally {
    [Console]::Write("`e[?25h`e[?1049l")   # show cursor, back to the normal screen
}
