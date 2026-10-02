#requires -Version 7.2
<#
.SYNOPSIS
    Runs a task graph (.orchestrator/tasks.json) with parallel Claude or Copilot workers.

.DESCRIPTION
    Each ready task (all deps merged, no file-ownership overlap with running tasks) gets a
    git worktree on branch orch/task/<id>, cut from the integration branch. A worker agent
    implements it; the orchestrator commits, checks file ownership, merges the latest
    integration branch in, runs the acceptance command and a review agent, and retries with
    feedback on failure. Approved tasks are merged into the integration branch, which
    unblocks their dependents. The run is restartable: state lives in .orchestrator/state.json.

.EXAMPLE
    ./Invoke-Orchestrator.ps1 -Provider Copilot -RepoPath C:\src\myapp -MaxParallel 3
.EXAMPLE
    ./Invoke-Orchestrator.ps1 -Provider Copilot -RepoPath C:\src\myapp -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Claude', 'Copilot')][string]$Provider,
    [string]$RepoPath = '.',
    [string]$Plan,
    [ValidateRange(1, 32)][int]$MaxParallel = 3,
    [string]$AgentPath,
    [switch]$DryRun,
    [switch]$RetryFailed,
    [ValidateRange(1, 300)][int]$PollSeconds = 5
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'Orchestrator.psm1'
Import-Module $modulePath -Force

$paths = Get-OrchPaths -RepoPath $RepoPath -PlanFile $Plan
$planObj = Read-Plan -PlanFile $paths.PlanFile -Repo $paths.Repo
$problems = Test-Plan $planObj
if ($problems.Count) {
    Write-Host "The plan has problems:" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
$settings = $planObj.Settings
$byId = [ordered]@{}; foreach ($t in $planObj.Tasks) { $byId[$t.id] = $t }
$waves = Get-Waves $planObj.Tasks
$dependents = Get-DependentCounts $planObj.Tasks

if ($DryRun) {
    Write-Host "Plan: $($paths.PlanFile)  ($($planObj.Tasks.Count) tasks, integration branch $($planObj.IntegrationBranch))"
    foreach ($w in ($waves.Values | Sort-Object -Unique)) {
        Write-Host "`nWave $w" -ForegroundColor Cyan
        foreach ($t in ($planObj.Tasks | Where-Object { $waves[$_.id] -eq $w })) {
            $deps = if ($t.deps.Count) { " <- $($t.deps -join ', ')" } else { '' }
            Write-Host ("  {0,-24} {1}{2}" -f $t.id, $t.title, $deps)
            Write-Host ("  {0,-24} owns: {1}" -f '', ($(if ($t.owns.Count) { $t.owns -join ', ' } else { '(whole repo - runs alone)' }))) -ForegroundColor DarkGray
        }
    }
    $conflicts = foreach ($a in $planObj.Tasks) { foreach ($b in $planObj.Tasks) {
            if ($a.id -lt $b.id -and $waves[$a.id] -eq $waves[$b.id] -and (Test-OwnsOverlap $a.owns $b.owns)) { "$($a.id) / $($b.id)" } } }
    if ($conflicts) { Write-Host "`nSame-wave tasks with overlapping owns (will run one after the other): $($conflicts -join '; ')" -ForegroundColor Yellow }
    exit 0
}

$agent = Resolve-AgentPath -Provider $Provider -AgentPath $AgentPath
try {
    $runLock = [IO.File]::Open((Join-Path $paths.RunDir 'run.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
}
catch [IO.IOException] {
    throw "Another orchestrator run may already be active for $($paths.Repo). Check its terminal before retrying."
}
try {
Initialize-RunDir $paths
Initialize-Integration $paths $planObj
$state = Read-State $paths

foreach ($t in $planObj.Tasks) {
    if (-not $state.tasks[$t.id]) { $state.tasks[$t.id] = New-TaskState }
    $s = $state.tasks[$t.id]
    if ($s.status -eq 'running') {
        $worktree = Join-Path $paths.WorktreeRoot $t.id
        $branch = "orch/task/$($t.id)"
        if ((Test-Path $worktree) -and (Invoke-Git $worktree @('branch', '--show-current')).Output -eq $branch) {
            $s.mode = if ($s.mode -eq 'sync') { 'sync' } else { 'resume' }
        }
        $s.status = 'pending'
    }
    if ($RetryFailed -and $s.status -eq 'failed') {
        $worktree = Join-Path $paths.WorktreeRoot $t.id
        $branch = "orch/task/$($t.id)"
        $canSync = $s.error -like 'Pipeline error:*' -and (Test-Path $worktree) -and
            (Invoke-Git $worktree @('branch', '--show-current')).Output -eq $branch -and
            -not (Invoke-Git $worktree @('status', '--porcelain')).Output -and
            (Get-TaskChanges $worktree $planObj.IntegrationBranch).Count -gt 0
        $s.status = 'pending'; $s.mode = if ($canSync) { 'sync' } else { 'fresh' }
        $s.error = $null
        if (-not $canSync) { $s.sessionId = $null }
    }
}
Save-State $paths $state

$log = { param($m) Write-OrchLog $paths.ProgressFile $m }
& $log "Run started: $($planObj.Tasks.Count) tasks, max $MaxParallel in parallel, integration branch $($planObj.IntegrationBranch)"
& $log "${Provider}: $agent"

$streaming = (Get-Command Start-ThreadJob).Parameters.ContainsKey('StreamingHost')
$jobs = @{}

function Get-DepContext($task) {
    if (-not $task.deps.Count) { return 'None. This task has no dependencies.' }
    ($task.deps | ForEach-Object {
        $d = $state.tasks[$_]
        "### $_ - $($byId[$_].title)`n$($d.summary)`n`nNotes: $(if ($d.notes) { $d.notes } else { '(none)' })"
    }) -join "`n`n"
}

function Start-Task($task) {
    $s = $state.tasks[$task.id]
    $wtPath = Join-Path $paths.WorktreeRoot $task.id
    if ($s.mode -in 'sync', 'resume') {
        if (-not (Test-Path $wtPath)) { throw "Cannot resume $($task.id): worktree $wtPath is missing." }
        $wt = [pscustomobject]@{ Path = $wtPath; Branch = "orch/task/$($task.id)" }
    }
    else {
        $s.mode = 'fresh'
        $wt = New-TaskWorktree $paths $task.id $planObj.IntegrationBranch
    }
    $ctx = @{
        Id = $task.id; Title = $task.title; Prompt = $task.prompt; Owns = @($task.owns); Shared = @($settings.shared)
        Acceptance = $task.acceptance; Model = (Resolve-AgentModel -Provider $Provider -Model ($task.model ?? $settings.model)); ReviewModel = (Resolve-AgentModel -Provider $Provider -Model $settings.reviewModel)
        Effort = $settings.effort; PermissionMode = $settings.permissionMode; AllowedTools = @($settings.allowedTools)
        MaxAttempts = [int]$settings.maxAttempts; MaxBudgetUsd = [double]$settings.maxBudgetUsd; Review = [bool]$settings.review
        Ignore = @($settings.ignore); EnforceOwns = [bool]$settings.enforceOwns; CommandTimeoutSec = [int]$settings.commandTimeoutSec; Setup = $settings.setup
        Worktree = $wt.Path; Branch = $wt.Branch; IntegrationBranch = $planObj.IntegrationBranch
        SpecText = $planObj.SpecText; DepContext = (Get-DepContext $task); Provider = $Provider; AgentPath = $agent
        LogDir = (Join-Path $paths.LogDir (Join-Path $task.id (Get-Date -Format 'yyyyMMdd-HHmmss')))
        ProgressFile = $paths.ProgressFile; StopFile = $paths.StopFile; Mode = $s.mode; SessionId = $s.sessionId
        Feedback = $s.feedback; SpecRejections = [int]$s.specRejections
        PreviousSummary = $s.summary; PreviousNotes = $s.notes
    }
    $s.status = 'running'; $s.startedAt = (Get-Date).ToString('o'); $s.error = $null
    $jobArgs = @{
        Name         = "orch-$($task.id)"
        ThrottleLimit = $MaxParallel + 1
        ScriptBlock  = { param($mod, $c) Import-Module $mod; Invoke-TaskPipeline -Ctx $c }
        ArgumentList = @($modulePath, $ctx)
    }
    if ($streaming) { $jobArgs.StreamingHost = $Host }
    $jobs[$task.id] = Start-ThreadJob @jobArgs
    & $log "[$($task.id)] started ($($s.mode)) in $($wt.Path)"
}

function Get-FirstLines([string]$text) { (($text -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 2) -join ' ' }

function Complete-Task($id, $res) {
    $s = $state.tasks[$id]; $task = $byId[$id]
    $s.costUsd = [math]::Round([double]$s.costUsd + [double]$res.Cost, 4)
    $s.attempts = [int]$s.attempts + [int]$res.Attempts
    if ($res.SessionId) { $s.sessionId = $res.SessionId }
    if ($res.Summary) { $s.summary = $res.Summary }
    if ($res.Notes) { $s.notes = $res.Notes }
    if ($res.Paused) {
        $s.status = 'pending'; $s.mode = $res.Mode; $s.feedback = $res.Feedback
        $s.specRejections = $res.SpecRejections
        & $log "[$id] paused after current session; worktree kept for resume"
        return
    }
    $s.feedback = $null; $s.specRejections = 0
    if (-not $res.Success) {
        $s.status = 'failed'; $s.error = $res.Error; $s.finishedAt = (Get-Date).ToString('o')
        & $log "[$id] FAILED: $(Get-FirstLines $res.Error)"
        return
    }
    # Merge into the integration branch (single writer: only this loop touches it).
    $int = $paths.IntegrationWorktree
    $before = (Invoke-Git $int @('rev-parse', 'HEAD')).Output
    $m = Invoke-Git $int @('merge', '--no-ff', '--no-edit', '-m', "Merge task ${id}: $($task.title)", "orch/task/$id")
    if ($m.Exit -ne 0) {
        [void](Invoke-Git $int @('merge', '--abort'))
        $s.syncRuns = [int]$s.syncRuns + 1
        if ($s.syncRuns -gt 3) {
            $s.status = 'failed'; $s.error = "Merge into $($planObj.IntegrationBranch) kept conflicting."
            & $log "[$id] FAILED: merge kept conflicting"; return
        }
        $s.status = 'pending'; $s.mode = 'sync'
        & $log "[$id] merge conflict with newer integration work; re-queued to sync"
        return
    }
    if ($settings.integrationCheck) {
        # Run setup first: the integration worktree has no installed dependencies, and a merge may add some.
        $chk = $null
        if ($settings.setup) {
            $chk = Invoke-ShellCommand $int $settings.setup (Join-Path $paths.LogDir "$id-integration-setup.log") ([int]$settings.commandTimeoutSec)
        }
        if (-not $chk -or $chk.Ok) {
            $chk = Invoke-ShellCommand $int $settings.integrationCheck (Join-Path $paths.LogDir "$id-integration-check.log") ([int]$settings.commandTimeoutSec)
        }
        if (-not $chk.Ok) {
            [void](Invoke-Git $int @('reset', '--hard', $before))
            $s.status = 'failed'; $s.error = "Integration check failed after merging; merge undone.`n$($chk.Tail)"
            & $log "[$id] FAILED: integration check failed after merge (merge undone)"; return
        }
    }
    $s.status = 'done'; $s.mode = 'fresh'; $s.finishedAt = (Get-Date).ToString('o')
    $s.mergedSha = (Invoke-Git $int @('rev-parse', 'HEAD')).Output
    & $log "[$id] DONE and merged ($([math]::Round([double]$s.costUsd, 2)) USD, $($s.attempts) attempt(s))"
}

$interrupted = $true
$stopRequested = $false
try {
    while ($true) {
        foreach ($id in @($jobs.Keys)) {
            $job = $jobs[$id]
            if ($job.State -notin 'Completed', 'Failed', 'Stopped') { continue }
            # With StreamingHost the job's Write-Host lines were already shown live; drop the replay.
            $out = if ($streaming) { Receive-Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErr 6>$null }
                   else { Receive-Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErr }
            Remove-Job $job -Force; $jobs.Remove($id)
            $res = @($out | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Success') }) | Select-Object -Last 1
            if (-not $res) { $res = @{ Success = $false; Error = "Pipeline crashed: $($jobErr | Out-String)"; Cost = 0; Attempts = 0 } }
            Complete-Task $id $res
            Save-State $paths $state
        }

        if (Test-Path $paths.StopFile) {
            if (-not $stopRequested) { & $log 'Graceful stop requested; waiting for active sessions to finish' }
            $stopRequested = $true
        }
        if ($stopRequested -and $jobs.Count -eq 0) { break }

        $ready = $planObj.Tasks | Where-Object {
            $state.tasks[$_.id].status -eq 'pending' -and
            @($_.deps | Where-Object { $state.tasks[$_].status -ne 'done' }).Count -eq 0
        } | Sort-Object @{ Expression = { $state.tasks[$_.id].mode -eq 'sync' }; Descending = $true },
                        @{ Expression = { $dependents[$_.id] }; Descending = $true }
        foreach ($t in $ready) {
            if (Test-Path $paths.StopFile) { $stopRequested = $true; break }
            if ($jobs.Count -ge $MaxParallel) { break }
            $clash = $jobs.Keys | Where-Object { Test-OwnsOverlap $t.owns $byId[$_].owns } | Select-Object -First 1
            if ($clash) { continue }
            Start-Task $t
            Save-State $paths $state
        }

        if ($jobs.Count -eq 0) { break }
        $null = Wait-Job -Job @($jobs.Values) -Any -Timeout $PollSeconds
    }
    $interrupted = $false
}
finally {
    if ($interrupted -and $jobs.Count) {
        Write-Warning "Interrupted. Stopping $($jobs.Count) task(s); they restart from scratch on the next run. Check for leftover $Provider processes."
        $jobs.Values | Stop-Job -ErrorAction SilentlyContinue
        $jobs.Values | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    Save-State $paths $state
    if ($stopRequested -and -not $interrupted) { Remove-Item $paths.StopFile -Force -ErrorAction SilentlyContinue }
}

# Summary
$rows = foreach ($t in $planObj.Tasks) {
    $s = $state.tasks[$t.id]
    [pscustomobject]@{
        Task     = $t.id
        Status   = Get-TaskDisplayStatus $t $planObj $state
        Attempts = $s.attempts
        CostUsd  = [math]::Round([double]$s.costUsd, 2)
        Note     = if ($s.error) { Get-FirstLines $s.error } else { $s.summary }
    }
}
$rows | Format-Table -AutoSize -Wrap
$total = ($rows | Measure-Object CostUsd -Sum).Sum
& $log ("Run finished: {0} done, {1} failed, {2} blocked, {3:N2} USD" -f
    @($rows | Where-Object Status -eq 'done').Count, @($rows | Where-Object Status -eq 'failed').Count,
    @($rows | Where-Object Status -eq 'blocked').Count, $total)
if (@($rows | Where-Object Status -ne 'done').Count -eq 0) {
    Write-Host "All tasks merged into $($planObj.IntegrationBranch). Review it, then merge it into your base branch, e.g.:" -ForegroundColor Green
    Write-Host "  git -C `"$($paths.Repo)`" merge --no-ff $($planObj.IntegrationBranch)"
    exit 0
}
if ($stopRequested) {
    Write-Host 'Stopped gracefully. Rerun the same Invoke-Orchestrator command to resume pending tasks (without -RetryFailed).' -ForegroundColor Yellow
    exit 0
}
Write-Host "Fix or edit the failed tasks, then rerun with -RetryFailed. Logs: $($paths.LogDir)" -ForegroundColor Yellow
exit 2
}
finally {
    $runLock.Dispose()
}
