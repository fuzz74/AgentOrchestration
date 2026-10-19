#requires -Version 7.2
<#
.SYNOPSIS
    Waits until a task of the run fails or the run ends, then shows the tasks.
.DESCRIPTION
    For a chat that started a run and wants to hear about it, or for a terminal. It returns once a
    task fails that had not failed when the wait began, or once no run is active, and shows each
    failed task's error and the task table. The exit code says which:
      0  no run is active, and every task is done
      1  the repo or the plan is invalid
      2  no run is active, and a task failed or is blocked
      3  a task failed, and the run is still going: wait again to hear more
      4  no run is active, and tasks are still pending: the run was stopped, or never started
      5  the run is still going, with nothing new (-Once, or -TimeoutMinutes passed)
    A run is active while Invoke-Orchestrator.ps1 holds .orchestrator\run.lock. Right after
    starting a run, pass -StartSeconds to give it time to take the lock.
.EXAMPLE
    ./Wait-Orchestrator.ps1 -RepoPath C:\src\myapp -StartSeconds 60
#>
[CmdletBinding()]
param(
    [string]$RepoPath = '.',
    [string]$Plan,
    [ValidateRange(0, 3600)][int]$StartSeconds = 0,
    [ValidateRange(0, 10080)][int]$TimeoutMinutes = 0,
    [switch]$Once,
    [ValidateRange(1, 300)][int]$PollSeconds = 5
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Orchestrator.psm1') -Force

$paths = Get-OrchPaths -RepoPath $RepoPath -PlanFile $Plan
$planObj = Read-Plan -PlanFile $paths.PlanFile -Repo $paths.Repo
$problems = Test-Plan $planObj
if ($problems.Count) {
    Write-Host 'Plan problems:' -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

function Test-RunActive {
    try { $lock = Open-RunLock $paths; if ($lock) { $lock.Dispose() }; $false } catch { $true }
}

function Read-RunState {
    # The orchestrator replaces state.json while it runs, so a read can miss it for a moment.
    for ($try = 1; ; $try++) {
        try { return Read-State $paths }
        catch { if ($try -ge 5) { throw }; Start-Sleep -Milliseconds 200 }
    }
}

function Get-Marks($state) {
    # A task whose mark changed while it is failed has failed since the wait began: every
    # finished attempt adds to its attempts.
    $marks = [Collections.Generic.Dictionary[string, string]]::new()
    foreach ($t in $planObj.Tasks) {
        $s = $state.tasks[$t.id]
        $marks[$t.id] = if ($s) { "$($s.status)|$($s.attempts)|$($s.finishedAt)" } else { 'pending' }
    }
    , $marks
}

function Show-Failure($state, [string[]]$ids) {
    foreach ($id in $ids) {
        Write-Host "$id failed:" -ForegroundColor Red
        $lines = @("$($state.tasks[$id].error)" -split "`r?`n" | Where-Object { $_.Trim() })
        $lines | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
        if ($lines.Count -gt 20) { Write-Host "  ... ($($lines.Count - 20) more lines in state.json)" }
        Write-Host "  Logs: $(Join-Path $paths.LogDir $id)" -ForegroundColor DarkGray
    }
}

function Show-Table {
    $showArgs = @{ RepoPath = $paths.Repo }
    if ($Plan) { $showArgs.Plan = $paths.PlanFile }
    # Through Write-Host, like the lines around it, so the table keeps its place among them.
    Write-Host (& (Join-Path $PSScriptRoot 'Show-Tasks.ps1') @showArgs | Out-String).TrimEnd()
}

$start = Get-Date
$startMarks = Get-Marks (Read-RunState)
$seenRun = $false
while ($true) {
    $active = Test-RunActive
    $state = Read-RunState
    $marks = Get-Marks $state
    $failed = @($planObj.Tasks | Where-Object { $state.tasks[$_.id].status -eq 'failed' -and $marks[$_.id] -ne $startMarks[$_.id] } |
        ForEach-Object { $_.id })
    # A run writes state.json as soon as it holds the lock, so a run that began and ended between two
    # looks still counts as seen.
    $seenRun = $seenRun -or $active -or ((Test-Path $paths.StateFile) -and (Get-Item $paths.StateFile).LastWriteTime -gt $start)
    if ($active -and $failed.Count) {
        Write-Host "$($failed -join ', ') failed. The run is still going with the tasks that don't depend on it." -ForegroundColor Yellow
        Show-Failure $state $failed
        Show-Table
        exit 3
    }
    if (-not $active -and ($seenRun -or $Once -or ((Get-Date) - $start).TotalSeconds -ge $StartSeconds)) { break }
    if ($active -and ($Once -or ($TimeoutMinutes -and ((Get-Date) - $start).TotalMinutes -ge $TimeoutMinutes))) {
        $waited = if ($Once) { '' } else { " after $TimeoutMinutes minute(s)" }
        Write-Host "The run is still going$waited, and no task has failed since the wait began."
        Show-Table
        exit 5
    }
    Start-Sleep -Seconds $PollSeconds
}

$status = @{}
foreach ($t in $planObj.Tasks) { $status[$t.id] = Get-TaskDisplayStatus $t $planObj $state }
$byStatus = { param($s) @($planObj.Tasks | Where-Object { $status[$_.id] -eq $s } | ForEach-Object { $_.id }) }
$done = & $byStatus 'done'; $failedNow = & $byStatus 'failed'; $blocked = & $byStatus 'blocked'
$total = @($planObj.Tasks).Count
# Pending, or still marked running by a run that was killed.
$pending = @($planObj.Tasks | Where-Object { $status[$_.id] -notin 'done', 'failed', 'blocked' } | ForEach-Object { $_.id })
$ended = if ($seenRun) { 'The run ended' } else { 'No run is active' }
if ($done.Count -eq $total) {
    Write-Host "${ended}: all $total tasks are done." -ForegroundColor Green
    Show-Table
    exit 0
}
if ($failedNow.Count -or $blocked.Count) {
    $parts = @("$($failedNow.Count) failed ($($failedNow -join ', '))")
    if ($blocked.Count) { $parts += "$($blocked.Count) blocked ($($blocked -join ', '))" }
    $parts += "$($done.Count) done"
    if ($pending.Count) { $parts += "$($pending.Count) pending" }
    Write-Host "${ended}: $($parts -join ', ')." -ForegroundColor Red
    Show-Failure $state $failedNow
    Show-Table
    exit 2
}
$why = if ($seenRun) { 'It was stopped, or ended early. Run it again to go on.' } else { 'Start it with Invoke-Orchestrator.ps1 or orch run.' }
Write-Host "${ended}, and $($pending.Count) of $total tasks are not done yet. $why" -ForegroundColor Yellow
Show-Table
exit 4
