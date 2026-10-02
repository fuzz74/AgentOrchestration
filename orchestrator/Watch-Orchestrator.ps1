#requires -Version 7.2
<#
.SYNOPSIS
    Live dashboard of an orchestrator run: total progress, what every running agent is doing,
    and the latest log lines.

.DESCRIPTION
    Read-only. Run it in a second terminal while Invoke-Orchestrator.ps1 or Plan-Tasks.ps1 runs.
    It reads .orchestrator/tasks.json, state.json, progress.md and the agents' *.events.jsonl
    logs, and redraws every few seconds. Press q or Ctrl+C to quit; the run is not affected.
    A screen taller than the window scrolls with the arrow keys, PgUp/PgDn and Home/End, and on
    Windows also with the mouse wheel and a clickable, draggable scrollbar. The mouse takes over
    text selection while the watcher runs (Shift+drag still selects in Windows Terminal); use
    -NoMouse to keep normal selection.

.EXAMPLE
    ./Watch-Orchestrator.ps1 -Provider Copilot -RepoPath C:\src\myapp
.EXAMPLE
    ./Watch-Orchestrator.ps1 -Provider Copilot -RepoPath C:\src\myapp -Once    # print one snapshot and exit
.EXAMPLE
    ./Watch-Orchestrator.ps1 -Provider Claude -RepoPath C:\src\myapp -NoMouse  # keyboard scrolling only
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Claude', 'Copilot')][string]$Provider,
    [string]$RepoPath = '.',
    [string]$Plan,
    [ValidateRange(1, 60)][int]$RefreshSeconds = 2,
    [ValidateRange(1, 20)][int]$ActivityLines = 10,
    [switch]$Once,
    [switch]$NoMouse
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

function Get-AgentProcesses([string[]]$TaskIds, $State) {
    # Named calls and resumed Copilot sessions recorded in this run's state belong to the plan.
    if (-not $IsWindows) { return @{ Available = $false; Processes = @() } }
    $name = if ($Provider -eq 'Copilot') { 'copilot.exe' } else { 'claude.exe' }
    $known = @($TaskIds) + @('planner', 'bootstrap')
    $resumed = @{}
    if ($Provider -eq 'Copilot' -and $State) {
        foreach ($taskId in $TaskIds) {
            $task = $State.tasks[$taskId]
            if ($task -and $task.status -eq 'running' -and $task.sessionId) { $resumed[$task.sessionId] = $taskId }
        }
    }
    try {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction Stop |
            ForEach-Object {
                $taskId = $null; $role = $null
                if ($_.CommandLine -match '(?i)(?:^|\s)--name[\s=]+"?orch:([a-z0-9][a-z0-9._-]{0,48})(?::(review|resolve))?(?=["\s]|$)') {
                    $taskId = $Matches[1]; $role = $Matches[2]
                }
                elseif ($Provider -eq 'Copilot' -and $_.CommandLine -match '(?i)(?:^|\s)--resume[\s=]+"?([0-9a-f-]{36})(?=["\s]|$)') {
                    $taskId = $resumed[$Matches[1]]
                }
                if (-not $taskId -or $taskId -notin $known) { return }
                [pscustomobject]@{ ProcessId = $_.ProcessId; Name = $_.Name; TaskId = $taskId; Role = $role; StartedAt = $_.CreationDate }
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
    $agentProcesses = Get-AgentProcesses @($plan ? $plan.Tasks.id : @()) $state

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
    & $add "Live $Provider CLI processes for this plan's tasks" 'White'
    if (-not $agentProcesses.Available) { & $add '  Process lookup unavailable' 'DarkYellow' }
    elseif (-not $agentProcesses.Processes.Count) { & $add '  (none detected)' 'DarkGray' }
    else {
        foreach ($process in $agentProcesses.Processes) {
            $role = if ($process.Role) { " ($($process.Role))" } else { '' }
            $age = Format-Span ($now - $process.StartedAt)
            & $add ("  PID {0}  {1}  task {2}{3}  running {4}" -f $process.ProcessId, $process.Name, $process.TaskId, $role, $age) 'Cyan'
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

# Scroll position of the live screen, and the scrollbar geometry of the last draw (for mouse hits).
$scroll = @{ Top = 0; Page = 1; Max = 0; Follow = $false; BarCol = -1; BarRows = 0; ThumbTop = 0; ThumbSize = 0; Drag = $null }

function Write-Screen($Lines, [switch]$Plain) {
    try { $w = [math]::Max(40, [Console]::WindowWidth - 1); $h = [math]::Max(10, [Console]::WindowHeight - 1) }
    catch { $w = 160; $h = 60 }   # no console window (output redirected)
    $Lines = @($Lines)
    $first = 0; $count = $Lines.Count; $footer = $null; $bar = $false
    if (-not $Plain -and $Lines.Count -gt $h) {
        # Longer than the window: show one page, a scrollbar on the right and a footer.
        $count = $h - 1
        $scroll.Page = $count
        $scroll.Max = $Lines.Count - $count
        if ($scroll.Follow) { $scroll.Top = $scroll.Max }
        $scroll.Top = [math]::Min([math]::Max(0, $scroll.Top), $scroll.Max)
        $first = $scroll.Top
        $keys = if ($mouse) { 'wheel, scrollbar, ↑↓ PgUp PgDn Home End' } else { '↑↓ PgUp PgDn Home End' }
        $footer = @{ Color = 'DarkGray'; Text = ("lines {0}-{1} of {2}  ·  {3} to scroll  ·  q to quit" -f ($first + 1), ($first + $count), $Lines.Count, $keys) }
        # The bar sits one column in from the right edge: writing the last column would trigger a wrap.
        $bar = $true
        $scroll.BarCol = $w - 1
        $scroll.BarRows = $count
        $scroll.ThumbSize = [math]::Max(1, [math]::Round($count * $count / $Lines.Count))
        $scroll.ThumbTop = [int][math]::Round(($count - $scroll.ThumbSize) * $scroll.Top / $scroll.Max)
    }
    elseif (-not $Plain) { $scroll.Top = 0; $scroll.Max = 0; $scroll.Page = [math]::Max(1, $h - 1); $scroll.BarCol = -1 }
    $shownLines = @($Lines | Select-Object -Skip $first -First $count) + @($footer | Where-Object { $_ })

    $textWidth = if ($bar) { $w - 1 } else { $w }
    $sb = [Text.StringBuilder]::new()
    if (-not $Plain) { [void]$sb.Append("`e[H") }
    for ($row = 0; $row -lt $shownLines.Count; $row++) {
        $l = $shownLines[$row]
        $text = $l.Text
        if ($text.Length -gt $textWidth) { $text = $text.Substring(0, $textWidth - 1) + '…' }
        [void]$sb.Append($ansi[$l.Color]).Append($text).Append($ansi.Reset)
        if ($bar -and $row -lt $count) {
            $inThumb = $row -ge $scroll.ThumbTop -and $row -lt $scroll.ThumbTop + $scroll.ThumbSize
            [void]$sb.Append(' ' * ($textWidth - $text.Length))
            [void]$sb.Append($(if ($inThumb) { "$($ansi.Gray)█" } else { "$($ansi.DarkGray)░" })).Append($ansi.Reset)
        }
        if (-not $Plain) { [void]$sb.Append("`e[K") }
        [void]$sb.Append("`n")
    }
    if (-not $Plain) { [void]$sb.Append("`e[J") }
    [Console]::Write($sb.ToString())
}

function Set-ScrollTop([int]$Top) {
    $scroll.Top = [math]::Min([math]::Max(0, $Top), $scroll.Max)
    $scroll.Follow = $scroll.Max -gt 0 -and $scroll.Top -ge $scroll.Max   # at the bottom: stay there as the screen grows
}

function Invoke-ScrollKey([ConsoleKey]$Key) {
    # Returns 'quit', 'moved' or $null (not a scroll key).
    switch ($Key) {
        'Q' { return 'quit' }
        { $_ -in 'UpArrow', 'K' } { Set-ScrollTop ($scroll.Top - 1) }
        { $_ -in 'DownArrow', 'J' } { Set-ScrollTop ($scroll.Top + 1) }
        'PageUp' { Set-ScrollTop ($scroll.Top - $scroll.Page) }
        { $_ -in 'PageDown', 'Spacebar' } { Set-ScrollTop ($scroll.Top + $scroll.Page) }
        'Home' { Set-ScrollTop 0 }
        'End' { Set-ScrollTop $scroll.Max }
        default { return $null }
    }
    'moved'
}

function Invoke-ScrollMouse($m) {
    # One console mouse event: the wheel scrolls anywhere; the scrollbar pages on a click and
    # scrolls while its thumb is dragged. Returns 'moved' or $null.
    $row = $m.Y - $m.WindowTop
    if ($m.Wheel -ne 0) { Set-ScrollTop ($scroll.Top - [math]::Sign($m.Wheel) * 3); return 'moved' }
    $leftDown = ($m.Buttons -band 1) -ne 0
    if (-not $leftDown) { $scroll.Drag = $null; return $null }
    if ($null -ne $scroll.Drag) {
        # Dragging the thumb: map its new top row back to a scroll position.
        $room = $scroll.BarRows - $scroll.ThumbSize
        if ($room -le 0) { return $null }
        $thumbTop = [math]::Min([math]::Max(0, $row - $scroll.Drag), $room)
        Set-ScrollTop ([int][math]::Round($thumbTop * $scroll.Max / $room))
        return 'moved'
    }
    $pressed = $m.Flags -eq 0 -or $m.Flags -eq 2   # a press or double click, not a move
    $onBar = $scroll.BarCol -ge 0 -and [math]::Abs($m.X - $scroll.BarCol) -le 1 -and $row -ge 0 -and $row -lt $scroll.BarRows
    if (-not ($pressed -and $onBar)) { return $null }
    if ($row -lt $scroll.ThumbTop) { Set-ScrollTop ($scroll.Top - $scroll.Page) }
    elseif ($row -ge $scroll.ThumbTop + $scroll.ThumbSize) { Set-ScrollTop ($scroll.Top + $scroll.Page) }
    else { $scroll.Drag = $row - $scroll.ThumbTop }
    'moved'
}

function Enable-ConsoleMouse {
    # Switches the console input to mouse events (Windows only). Returns $false where that is
    # not possible, and the watcher then falls back to keys read with [Console]::ReadKey.
    if (-not $IsWindows) { return $false }
    if (-not ('OrchWatch.ConsoleInput' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace OrchWatch {
    public sealed class InputEvent {
        public bool IsKey; public int Key;                                    // key down: virtual-key code
        public int X, Y, WindowTop, Wheel; public uint Buttons, Flags;       // mouse
    }
    public static class ConsoleInput {
        [StructLayout(LayoutKind.Sequential)]
        struct KEY_EVENT_RECORD { public int KeyDown; public ushort RepeatCount, VirtualKeyCode, VirtualScanCode, UnicodeChar; public uint ControlKeyState; }
        [StructLayout(LayoutKind.Sequential)]
        struct MOUSE_EVENT_RECORD { public short X, Y; public uint ButtonState, ControlKeyState, EventFlags; }
        [StructLayout(LayoutKind.Explicit)]
        struct INPUT_RECORD {
            [FieldOffset(0)] public ushort EventType;
            [FieldOffset(4)] public KEY_EVENT_RECORD Key;
            [FieldOffset(4)] public MOUSE_EVENT_RECORD Mouse;
        }
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int n);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr h, out uint mode);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleMode(IntPtr h, uint mode);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint n);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool ReadConsoleInputW(IntPtr h, [Out] INPUT_RECORD[] buffer, uint length, out uint read);

        const uint WindowInput = 0x8, MouseInput = 0x10, QuickEdit = 0x40, ExtendedFlags = 0x80, VirtualTerminalInput = 0x200;
        static IntPtr handle; static uint savedMode; static bool enabled;

        public static bool Enable() {
            handle = GetStdHandle(-10);
            if (handle == IntPtr.Zero || handle == new IntPtr(-1) || !GetConsoleMode(handle, out savedMode)) return false;
            // Mouse records instead of VT sequences, and no QuickEdit selection eating the clicks.
            uint mode = (savedMode | MouseInput | WindowInput | ExtendedFlags) & ~(QuickEdit | VirtualTerminalInput);
            enabled = SetConsoleMode(handle, mode);
            return enabled;
        }
        public static void Restore() { if (enabled) { SetConsoleMode(handle, savedMode); enabled = false; } }

        public static List<InputEvent> Read(int windowTop) {
            var events = new List<InputEvent>();
            uint pending;
            if (!enabled || !GetNumberOfConsoleInputEvents(handle, out pending) || pending == 0) return events;
            var buffer = new INPUT_RECORD[Math.Min(pending, 64u)];
            uint read;
            if (!ReadConsoleInputW(handle, buffer, (uint)buffer.Length, out read)) return events;
            for (int i = 0; i < read; i++) {
                var r = buffer[i];
                if (r.EventType == 1 && r.Key.KeyDown != 0) {
                    events.Add(new InputEvent { IsKey = true, Key = r.Key.VirtualKeyCode });
                } else if (r.EventType == 2) {
                    var m = r.Mouse;
                    int wheel = (m.EventFlags & 0x4) != 0 ? (short)(m.ButtonState >> 16) : 0;
                    events.Add(new InputEvent { X = m.X, Y = m.Y, WindowTop = windowTop, Wheel = wheel, Buttons = m.ButtonState & 0xFFFF, Flags = m.EventFlags });
                }
            }
            return events;
        }
    }
}
'@
    }
    try { [OrchWatch.ConsoleInput]::Enable() } catch { $false }
}

function Read-ScrollInput {
    # Handles all pending input. Returns 'quit', 'moved' or $null (nothing to redraw).
    $result = $null
    if ($mouse) {
        $top = try { [Console]::WindowTop } catch { 0 }
        foreach ($e in [OrchWatch.ConsoleInput]::Read($top)) {
            # Modifier keys (Shift = 16, Ctrl, Alt, Caps Lock) have no ConsoleKey value; skip them.
            if ($e.IsKey -and -not [Enum]::IsDefined([ConsoleKey], $e.Key)) { continue }
            $r = if ($e.IsKey) { Invoke-ScrollKey ([ConsoleKey]$e.Key) } else { Invoke-ScrollMouse $e }
            if ($r -eq 'quit') { return 'quit' }
            if ($r) { $result = $r }
        }
        return $result
    }
    try { while ([Console]::KeyAvailable) {
            $r = Invoke-ScrollKey ([Console]::ReadKey($true).Key)
            if ($r -eq 'quit') { return 'quit' }
            if ($r) { $result = $r }
        } }
    catch { }   # input redirected
    $result
}

#endregion

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
if ($Once) { Write-Screen (New-Screen) -Plain; return }

$mouse = $false
[Console]::Write("`e[?1049h`e[?25l`e[?1007h")   # alternate screen, hide cursor, wheel sends arrow keys (-NoMouse)
try {
    $mouse = -not $NoMouse -and (Enable-ConsoleMouse)
    :refresh while ($true) {
        $screen = New-Screen
        Write-Screen $screen
        # Wait for the next refresh, redrawing at once when a key or the mouse scrolls the view.
        $next = (Get-Date).AddSeconds($RefreshSeconds)
        while ((Get-Date) -lt $next) {
            switch (Read-ScrollInput) {
                'quit' { break refresh }
                'moved' { Write-Screen $screen }
                default { Start-Sleep -Milliseconds 30 }
            }
        }
    }
}
finally {
    if ($mouse) { [OrchWatch.ConsoleInput]::Restore() }
    [Console]::Write("`e[?1007l`e[?25h`e[?1049l")   # restore wheel mode and cursor, back to the normal screen
}
