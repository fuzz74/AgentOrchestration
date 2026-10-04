#requires -Version 7.2
<#
.SYNOPSIS
    End-to-end test of bootstrap -> plan -> schedule -> gate -> merge using fake-claude.ps1
    (no tokens spent). Plans into a folder that does not exist yet, so the project skeleton is
    created first (its first attempt fails the clean-checkout check). Then plans 4 tasks (one
    diamond: contracts -> a, b -> wire-up), makes feature-b fail its first attempt, and checks
    everything lands on orch/integration. After the retry and pause checks it finishes the run:
    an unfinished run blocks, Complete-Orchestrator.ps1 archives a finished and merged one, and
    Plan-Tasks.ps1 archives the next finished run by itself.
#>
param(
    [Parameter(Mandatory)][ValidateSet('Claude', 'Copilot')][string]$Provider,
    [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) "orch-smoke-$(Get-Random)")
)

$ErrorActionPreference = 'Stop'
$orch = Join-Path $PSScriptRoot '..\orchestrator'
$fake = Join-Path $PSScriptRoot 'fake-claude.ps1'
Remove-Item (Join-Path ([IO.Path]::GetTempPath()) 'fake-claude') -Recurse -Force -ErrorAction SilentlyContinue

# The repo folder does not exist yet: Plan-Tasks.ps1 creates it through Initialize-Project.ps1.
$repo = Join-Path $WorkDir 'demo'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$spec = Join-Path $WorkDir 'spec.md'
Set-Content $spec "Build A and B on top of shared contracts, then wire them together."
$gitIdentity = @{ GIT_AUTHOR_NAME = 'Smoke Test'; GIT_AUTHOR_EMAIL = 'smoke@example.com'
                  GIT_COMMITTER_NAME = 'Smoke Test'; GIT_COMMITTER_EMAIL = 'smoke@example.com' }
$gitIdentity.GetEnumerator() | ForEach-Object { Set-Item "Env:$($_.Key)" $_.Value }

$env:FAKE_FAIL_ONCE = 'feature-b'
$env:FAKE_SHARED = '1'
$env:FAKE_NO_STRUCTURED = 'contracts'
if ($Provider -eq 'Copilot') { $env:FAKE_REQUIRE_MODEL = 'gpt-6-sol' }
try {
    & (Join-Path $orch 'Plan-Tasks.ps1') -Provider $Provider -Spec $spec -RepoPath $repo -AgentPath $fake
    # The fake planner lists registry.txt as shared. Every task touches it, so the parallel tasks
    # conflict and the resolver path runs.
    $planFile = Join-Path $repo '.orchestrator/tasks.json'
    $planDoc = Get-Content $planFile -Raw | ConvertFrom-Json -AsHashtable
    $plannerShared = @($planDoc.settings.shared) -join ','
    $reference = Join-Path $WorkDir 'reference library'
    New-Item -ItemType Directory -Path $reference | Out-Null
    $planDoc.settings.additionalDirectories = @('../reference library')
    if ($Provider -eq 'Copilot') {
        if ($planDoc.settings.model -ne 'gpt-6-sol' -or $planDoc.settings.reviewModel -ne 'gpt-6-sol') { throw 'Copilot plan did not pin GPT-6 Sol.' }
        $planDoc.settings.model = 'sonnet'
        $planDoc.settings.reviewModel = 'haiku'
        $planDoc.tasks[0].model = 'opus'
    }
    $planDoc | ConvertTo-Json -Depth 10 | Set-Content $planFile
    $lockPath = Join-Path $repo '.orchestrator/run.lock'
    $heldLock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    $duplicateRejected = $false
    try {
        try {
            & (Join-Path $orch 'Invoke-Orchestrator.ps1') -Provider $Provider -RepoPath $repo -AgentPath $fake
        }
        catch {
            if ($_.Exception.Message -notlike 'Another orchestrator run may already be active*') { throw }
            $duplicateRejected = $true
        }
    }
    finally { $heldLock.Dispose() }
    if (-not $duplicateRejected) { throw 'Concurrent orchestrator invocation was not rejected.' }
    $env:FAKE_REQUIRE_ADD_DIR = [IO.Path]::GetFullPath($reference)
    & (Join-Path $orch 'Invoke-Orchestrator.ps1') -Provider $Provider -RepoPath $repo -AgentPath $fake -MaxParallel 2 -PollSeconds 1
    $exit = $LASTEXITCODE
    Remove-Item Env:FAKE_REQUIRE_ADD_DIR
    $releasedLock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    $releasedLock.Dispose()
    $longPromptOk = $true
    if ($Provider -eq 'Copilot') {
        Import-Module (Join-Path $orch 'Orchestrator.psm1') -Force
        $review = Invoke-Agent -Provider Copilot -AgentPath $fake -WorkDir $repo -Model 'gpt-6-sol' `
            -Prompt ("orchestrator-role: reviewer`n" + ('x' * 50000))
        $longPromptOk = $review.Finished -and $review.Exit -eq 0
    }
}
finally {
    Remove-Item Env:FAKE_FAIL_ONCE, Env:FAKE_SHARED, Env:FAKE_NO_STRUCTURED, Env:FAKE_REQUIRE_MODEL, Env:FAKE_REQUIRE_ADD_DIR -ErrorAction SilentlyContinue
    $gitIdentity.Keys | ForEach-Object { Remove-Item "Env:$_" }
}

$files = git -C $repo ls-tree -r --name-only orch/integration
$state = Get-Content (Join-Path $repo '.orchestrator/state.json') -Raw | ConvertFrom-Json -AsHashtable
$planSettings = (Get-Content $planFile -Raw | ConvertFrom-Json).settings
$plannerPrompt = Get-Content (Get-ChildItem (Join-Path $repo '.orchestrator/logs') -Filter 'planner-*-1.json.prompt.md' | Select-Object -First 1) -Raw
$planningRules = (Get-Content (Join-Path $orch 'prompts/planning-rules.md') -Raw).TrimEnd()
$checks = [ordered]@{
    'skeleton fixed and amended'        = (git -C $repo rev-list --count main) -eq '1' -and @('skeleton.txt', 'tool.txt' | Where-Object { $_ -notin (git -C $repo ls-tree -r --name-only main) }).Count -eq 0
    'plan uses skeleton commands'       = $planSettings.setup -like '*skeleton.txt*' -and $planSettings.integrationCheck -like '*tool.txt*'
    'plan uses planner shared files'    = $plannerShared -eq 'registry.txt'
    'planner received shared rules'     = $plannerPrompt.Contains($planningRules) -and -not $plannerPrompt.Contains('{{PLANNING_RULES}}')
    'integration check ran after merge' = @(Get-ChildItem (Join-Path $repo '.orchestrator/logs') -Filter '*-integration-check.log').Count -eq 4
    'orchestrator exit code 0'          = $exit -eq 0
    'duplicate run rejected'            = $duplicateRejected
    'reference directory passed to agents' = $exit -eq 0
    'reference directory in worker prompt' = (Get-Content (Get-ChildItem (Join-Path $repo '.orchestrator/logs/contracts') -Recurse -Filter 'attempt-1-worker.json.prompt.md' | Select-Object -First 1) -Raw).Contains($env:FAKE_REQUIRE_ADD_DIR ?? [IO.Path]::GetFullPath($reference))
    'long Copilot prompt uses stdin'    = $longPromptOk
    'all tasks done'                    = @($state.tasks.Values | Where-Object { $_.status -ne 'done' }).Count -eq 0
    'all four files on orch/integration' = @('contracts/contracts.txt', 'a/feature-a.txt', 'b/feature-b.txt', 'app/wire-up.txt' | Where-Object { $_ -notin $files }).Count -eq 0
    'owns violation not merged'         = 'outside-owns.txt' -notin $files
    'feature-b needed a retry'          = $state.tasks['feature-b'].attempts -eq 2
    'shared file kept every task'       = @('contracts', 'feature-a', 'feature-b', 'wire-up' | Where-Object { $_ -notin (git -C $repo show orch/integration:registry.txt) }).Count -eq 0
    'missing result recovered by nudge' = $state.tasks['contracts'].attempts -eq 1 -and $state.tasks['contracts'].summary -like 'Result after nudge*'
    'conflict was resolved'             = (Get-Content (Join-Path $repo '.orchestrator/progress.md') -Raw) -match 'starting resolver|re-queued to sync'
    'wire-up saw its deps'              = (Get-Content (Get-ChildItem (Join-Path $repo '.orchestrator/logs/wire-up') -Recurse -Filter 'attempt-1-worker.json.prompt.md' | Select-Object -First 1) -Raw) -match 'See a/feature-a.txt'
}
$checks.GetEnumerator() | ForEach-Object { Write-Host ("{0,-38} {1}" -f $_.Key, ($_.Value ? 'PASS' : 'FAIL')) -ForegroundColor ($_.Value ? 'Green' : 'Red') }
& (Join-Path $orch 'Show-Tasks.ps1') -RepoPath $repo
if ($checks.Values -contains $false) { Write-Host "Smoke test FAILED. Repo left at $repo"; exit 1 }

$retryPlan = Get-Content $planFile -Raw | ConvertFrom-Json -AsHashtable
foreach ($id in 'quality-only', 'spec-only') {
    $retryPlan.tasks += @{
        id = $id; title = "Check $id retry policy"; deps = @('contracts'); owns = @("$id/**")
        acceptance = "if (-not (Test-Path '$id/$id.txt')) { exit 1 }"
        prompt = "Build $id."
    }
}
# Task ids that are also hashtable property names must not confuse the scheduler's bookkeeping.
foreach ($id in 'count', 'keys', 'values') {
    $retryPlan.tasks += @{
        id = $id; title = "Task called $id"; deps = @('contracts'); owns = @("$id/**")
        acceptance = "if (-not (Test-Path '$id/$id.txt')) { exit 1 }"; prompt = "Build $id."
    }
}
$retryPlan | ConvertTo-Json -Depth 10 | Set-Content $planFile
& (Join-Path $orch 'Invoke-Orchestrator.ps1') -Provider $Provider -RepoPath $repo -AgentPath $fake -MaxParallel 2 -PollSeconds 1
$retryExit = $LASTEXITCODE
$retryState = Get-Content (Join-Path $repo '.orchestrator/state.json') -Raw | ConvertFrom-Json -AsHashtable
$retryChecks = [ordered]@{
    'quality bug retried beyond three' = $retryState.tasks['quality-only'].status -eq 'done' -and $retryState.tasks['quality-only'].attempts -eq 5
    'five spec rejections stop task'    = $retryState.tasks['spec-only'].status -eq 'failed' -and $retryState.tasks['spec-only'].attempts -eq 5
    'rejection leaves earlier work done' = $retryExit -eq 2 -and $retryState.tasks['contracts'].status -eq 'done'
    'property-named task ids run'      = @('count', 'keys', 'values' | Where-Object { $retryState.tasks[$_].status -ne 'done' }).Count -eq 0
}
$retryChecks.GetEnumerator() | ForEach-Object { Write-Host ("{0,-38} {1}" -f $_.Key, ($_.Value ? 'PASS' : 'FAIL')) -ForegroundColor ($_.Value ? 'Green' : 'Red') }
if ($retryChecks.Values -contains $false) { Write-Host "Retry test FAILED. Repo left at $repo"; exit 1 }
$newDependency = Get-Content $planFile -Raw | ConvertFrom-Json -AsHashtable
$newDependency.tasks += @{
    id = 'retry-dep'; title = 'New dependency for failed task'; deps = @('contracts'); owns = @('retry-dep/**')
    acceptance = "if (-not (Test-Path 'retry-dep/retry-dep.txt')) { exit 1 }"; prompt = 'Build retry-dep.'
}
$newDependency.tasks | Where-Object id -eq 'spec-only' | ForEach-Object { $_.deps += 'retry-dep' }
$newDependency | ConvertTo-Json -Depth 10 | Set-Content $planFile
$failedWorktree = Join-Path $WorkDir 'demo.worktrees/spec-only'
$originalCommit = (git -C $failedWorktree rev-parse HEAD).Trim()
$uncommitted = Join-Path $failedWorktree 'uncommitted.txt'
Set-Content $uncommitted 'Do not discard this file.'
$dirtyRejected = $false
try {
    & (Join-Path $orch 'Invoke-Orchestrator.ps1') -Provider $Provider -RepoPath $repo -AgentPath $fake -RetryFailed -MaxParallel 2 -PollSeconds 1
}
catch { $dirtyRejected = $_.Exception.Message -like '*has uncommitted changes*' }
finally { Remove-Item $uncommitted }
if (-not $dirtyRejected -or (git -C $failedWorktree rev-parse HEAD).Trim() -ne $originalCommit) {
    throw 'Dirty failed worktree was not protected.'
}
& (Join-Path $orch 'Invoke-Orchestrator.ps1') -Provider $Provider -RepoPath $repo -AgentPath $fake -RetryFailed -MaxParallel 2 -PollSeconds 1
$preservedCommit = (git -C $failedWorktree rev-parse HEAD).Trim()
git -C $repo merge-base --is-ancestor $originalCommit $preservedCommit
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $failedWorktree 'retry-dep/retry-dep.txt'))) {
    throw 'Ordinary retry did not preserve the failed branch and sync its new dependency.'
}
& (Join-Path $orch 'Invoke-Orchestrator.ps1') -Provider $Provider -RepoPath $repo -AgentPath $fake -RetryFailed -FreshFailed -MaxParallel 2 -PollSeconds 1
$archives = @(git -C $repo for-each-ref --format='%(refname:short)' refs/heads/orch/archive/spec-only)
if ($archives.Count -ne 1 -or (git -C $repo rev-parse $archives[0]).Trim() -ne $preservedCommit) {
    throw 'Fresh retry did not archive the previous failed branch.'
}
Write-Host 'Dirty, preserved and archived retry paths PASS' -ForegroundColor Green
$pausePlan = Get-Content $planFile -Raw | ConvertFrom-Json -AsHashtable
foreach ($id in 'pause-point', 'after-pause') {
    $pausePlan.tasks += @{
        id = $id; title = "Check $id"; deps = @(if ($id -eq 'pause-point') { 'contracts' } else { 'pause-point' }); owns = @("$id/**")
        acceptance = "if (-not (Test-Path '$id/$id.txt')) { exit 1 }"
        prompt = "Build $id."
    }
}
$pausePlan | ConvertTo-Json -Depth 10 | Set-Content $planFile
$env:FAKE_STOP_TASK = 'pause-point'; $env:FAKE_STOP_REPO = $repo
try {
    & (Join-Path $orch 'Invoke-Orchestrator.ps1') -Provider $Provider -RepoPath $repo -AgentPath $fake -MaxParallel 2 -PollSeconds 1
    $pauseExit = $LASTEXITCODE
}
finally { Remove-Item Env:FAKE_STOP_TASK, Env:FAKE_STOP_REPO -ErrorAction SilentlyContinue }
$pauseState = Get-Content (Join-Path $repo '.orchestrator/state.json') -Raw | ConvertFrom-Json -AsHashtable
$pauseChecks = [ordered]@{
    'graceful stop exits successfully' = $pauseExit -eq 0
    'worker commit kept for resume'    = $pauseState.tasks['pause-point'].status -eq 'pending' -and $pauseState.tasks['pause-point'].mode -eq 'sync' -and
        (git -C $repo ls-tree -r --name-only orch/task/pause-point) -contains 'pause-point/pause-point.txt'
    'dependent has not started'        = $pauseState.tasks['after-pause'].status -eq 'pending' -and $pauseState.tasks['after-pause'].attempts -eq 0
    'stop signal cleared on exit'      = -not (Test-Path (Join-Path $repo '.orchestrator/stop-requested'))
}
$pauseChecks.GetEnumerator() | ForEach-Object { Write-Host ("{0,-38} {1}" -f $_.Key, ($_.Value ? 'PASS' : 'FAIL')) -ForegroundColor ($_.Value ? 'Green' : 'Red') }
if ($pauseChecks.Values -contains $false) { Write-Host "Pause test FAILED. Repo left at $repo"; exit 1 }
& (Join-Path $orch 'Invoke-Orchestrator.ps1') -Provider $Provider -RepoPath $repo -AgentPath $fake -MaxParallel 2 -PollSeconds 1
$resumeState = Get-Content (Join-Path $repo '.orchestrator/state.json') -Raw | ConvertFrom-Json -AsHashtable
$resumeOk = $resumeState.tasks['pause-point'].status -eq 'done' -and $resumeState.tasks['pause-point'].attempts -eq 1 -and
    $resumeState.tasks['after-pause'].status -eq 'done' -and $resumeState.tasks['spec-only'].status -eq 'failed'
Write-Host ("{0,-38} {1}" -f 'resume merges and unblocks dependent', ($resumeOk ? 'PASS' : 'FAIL')) -ForegroundColor ($resumeOk ? 'Green' : 'Red')
if (-not $resumeOk) { Write-Host "Resume test FAILED. Repo left at $repo"; exit 1 }
$reviewPlan = Get-Content $planFile -Raw | ConvertFrom-Json -AsHashtable
$reviewPlan.tasks += @{
    id = 'pause-retry'; title = 'Pause after review rejection'; deps = @('contracts'); owns = @('pause-retry/**')
    acceptance = "if (-not (Test-Path 'pause-retry/pause-retry.txt')) { exit 1 }"; prompt = 'Build pause-retry.'
}
$reviewPlan | ConvertTo-Json -Depth 10 | Set-Content $planFile
$env:FAKE_STOP_REPO = $repo
try {
    & (Join-Path $orch 'Invoke-Orchestrator.ps1') -Provider $Provider -RepoPath $repo -AgentPath $fake -MaxParallel 2 -PollSeconds 1
    $reviewPauseExit = $LASTEXITCODE
}
finally { Remove-Item Env:FAKE_STOP_REPO -ErrorAction SilentlyContinue }
$reviewPauseState = Get-Content (Join-Path $repo '.orchestrator/state.json') -Raw | ConvertFrom-Json -AsHashtable
$reviewPaused = $reviewPauseExit -eq 0 -and $reviewPauseState.tasks['pause-retry'].mode -eq 'resume' -and
    $reviewPauseState.tasks['pause-retry'].status -eq 'pending' -and $reviewPauseState.tasks['pause-retry'].feedback -match 'Bug remains'
Write-Host ("{0,-38} {1}" -f 'review retry paused with feedback', ($reviewPaused ? 'PASS' : 'FAIL')) -ForegroundColor ($reviewPaused ? 'Green' : 'Red')
if (-not $reviewPaused) { Write-Host "Review pause test FAILED. Repo left at $repo"; exit 1 }
& (Join-Path $orch 'Invoke-Orchestrator.ps1') -Provider $Provider -RepoPath $repo -AgentPath $fake -MaxParallel 2 -PollSeconds 1
$reviewResumeState = Get-Content (Join-Path $repo '.orchestrator/state.json') -Raw | ConvertFrom-Json -AsHashtable
$reviewResumed = $reviewResumeState.tasks['pause-retry'].status -eq 'done' -and $reviewResumeState.tasks['pause-retry'].attempts -eq 2
Write-Host ("{0,-38} {1}" -f 'review retry resumes same branch', ($reviewResumed ? 'PASS' : 'FAIL')) -ForegroundColor ($reviewResumed ? 'Green' : 'Red')
if (-not $reviewResumed) { Write-Host "Review resume test FAILED. Repo left at $repo"; exit 1 }
& (Join-Path $orch 'Request-OrchestratorStop.ps1') -RepoPath $repo
& (Join-Path $orch 'Request-OrchestratorStop.ps1') -RepoPath $repo -Cancel
$cancelled = -not (Test-Path (Join-Path $repo '.orchestrator/stop-requested'))
Write-Host ("{0,-38} {1}" -f 'unused stop request can be cancelled', ($cancelled ? 'PASS' : 'FAIL')) -ForegroundColor ($cancelled ? 'Green' : 'Red')
if (-not $cancelled) { Write-Host "Cancel test FAILED. Repo left at $repo"; exit 1 }

# Finishing the run. spec-only is still failed, so the run is unfinished: nothing may archive it yet.
$complete = Join-Path $orch 'Complete-Orchestrator.ps1'
$planTasks = Join-Path $orch 'Plan-Tasks.ps1'
$runDir = Join-Path $repo '.orchestrator'
$runsRoot = "$repo.runs"
function Test-Rejected([scriptblock]$Action, [string]$Like) {
    try { $null = & $Action; $false } catch { $_.Exception.Message -like $Like }
}
$heldLock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $activeBlocks = (Test-Rejected { & $complete -RepoPath $repo -Force } '*run is active*') -and
        (Test-Rejected { & (Join-Path $orch 'Clear-Orchestrator.ps1') -RepoPath $repo } '*run is active*')
}
finally { $heldLock.Dispose() }
$unfinishedBlocksComplete = Test-Rejected { & $complete -RepoPath $repo } '*is not finished*spec-only*'
$unfinishedBlocksPlan = Test-Rejected { & $planTasks -Provider $Provider -Spec $spec -RepoPath $repo -AgentPath $fake } '*is not finished*-Force*'
# Without the failed task every task is done, but orch/integration is not merged into main yet.
$finishedPlan = Get-Content $planFile -Raw | ConvertFrom-Json -AsHashtable
$finishedPlan.tasks = @($finishedPlan.tasks | Where-Object { $_.id -ne 'spec-only' })
$finishedPlan | ConvertTo-Json -Depth 10 | Set-Content $planFile
$unmergedBlocks = Test-Rejected { & $complete -RepoPath $repo } '*that main lacks*'
git -C $repo merge -q --no-ff --no-edit orch/integration
if ($LASTEXITCODE -ne 0) { throw 'Could not merge orch/integration into main.' }
# A new file in a worktree that is not committed would be deleted with the worktree.
$stray = Join-Path $WorkDir 'demo.worktrees/_integration/uncommitted.txt'
Set-Content $stray 'Do not discard this file.'
$uncommittedBlocks = (Test-Rejected { & $complete -RepoPath $repo } '*uncommitted changes*uncommitted.txt*') -and (Test-Path $stray)
Remove-Item $stray
& $complete -RepoPath $repo -WhatIf
$whatIfChangedNothing = (Test-Path (Join-Path $runDir 'state.json')) -and -not (Test-Path $runsRoot) -and
    (Test-Path $failedWorktree) -and @(git -C $repo for-each-ref refs/heads/orch/).Count -gt 0
& $complete -RepoPath $repo
$archives = @(Get-ChildItem $runsRoot -Directory | Sort-Object Name)
$archived = Join-Path $archives[0].FullName '.orchestrator'
$completeChecks = [ordered]@{
    'active run blocks complete and clear' = $activeBlocks
    'unfinished run blocks completing' = $unfinishedBlocksComplete
    'unfinished run blocks planning'   = $unfinishedBlocksPlan
    'unmerged integration blocks'      = $unmergedBlocks
    'uncommitted worktree change blocks' = $uncommittedBlocks
    '-WhatIf changes nothing'          = $whatIfChangedNothing
    'only project.json left'           = (@(Get-ChildItem $runDir -Force).Name -join ',') -eq 'project.json'
    'archive holds the run'            = $archives.Count -eq 1 -and @('tasks.json', 'state.json', 'progress.md', 'spec.md', 'project.json', 'run.lock', 'logs/contracts', 'branches.txt' |
        Where-Object { -not (Test-Path (Join-Path $archived $_)) }).Count -eq 0
    'worktrees and branches gone'      = -not (Test-Path "$repo.worktrees") -and @(git -C $repo worktree list).Count -eq 1 -and
        @(git -C $repo for-each-ref refs/heads/orch/).Count -eq 0
}
$completeChecks.GetEnumerator() | ForEach-Object { Write-Host ("{0,-38} {1}" -f $_.Key, ($_.Value ? 'PASS' : 'FAIL')) -ForegroundColor ($_.Value ? 'Green' : 'Red') }
if ($completeChecks.Values -contains $false) { Write-Host "Complete test FAILED. Repo left at $repo"; exit 1 }

# The next plan reuses the task ids of the archived run. They must run again, not count as done.
$env:FAKE_SHARED = '1'
try {
    & $planTasks -Provider $Provider -Spec $spec -RepoPath $repo -AgentPath $fake
    & (Join-Path $orch 'Invoke-Orchestrator.ps1') -Provider $Provider -RepoPath $repo -AgentPath $fake -MaxParallel 2 -PollSeconds 1
    $secondExit = $LASTEXITCODE
}
finally { Remove-Item Env:FAKE_SHARED }
$secondState = Get-Content (Join-Path $runDir 'state.json') -Raw | ConvertFrom-Json -AsHashtable
git -C $repo merge -q --no-ff --no-edit orch/integration
if ($LASTEXITCODE -ne 0) { throw 'Could not merge the second orch/integration into main.' }
# Planning on that finished run archives it without -Force and keeps a spec that lies in .orchestrator.
$nextSpec = Join-Path $runDir 'spec-next.md'
Set-Content $nextSpec 'Build the next part.'
& $planTasks -Provider $Provider -Spec $nextSpec -RepoPath $repo -AgentPath $fake
$archives = @(Get-ChildItem $runsRoot -Directory | Sort-Object Name)
$nextPlan = Get-Content $planFile -Raw | ConvertFrom-Json
$oldStateLeft = Test-Path (Join-Path $runDir 'state.json')
$neverRunStops = Test-Rejected { & $planTasks -Provider $Provider -Spec $nextSpec -RepoPath $repo -AgentPath $fake } '*exists. Use -Force*'
$unfinishedNeedsForce = Test-Rejected { & $complete -RepoPath $repo -Keep spec-next.md } '*is not finished*'
& $complete -RepoPath $repo -Keep spec-next.md -Force
$forcedArchives = @(Get-ChildItem $runsRoot -Directory | Sort-Object Name)
$planChecks = [ordered]@{
    'reused task ids ran again'        = $secondExit -eq 0 -and $secondState.tasks.psbase.Count -eq 4 -and
        @($secondState.tasks.Values | Where-Object { $_.status -ne 'done' -or $_.attempts -lt 1 }).Count -eq 0
    'planning archived the finished run' = $archives.Count -eq 2 -and (Test-Path (Join-Path $archives[1].FullName '.orchestrator/state.json')) -and
        @(git -C $repo for-each-ref refs/heads/orch/).Count -eq 0
    'new plan has no old state'        = $nextPlan.tasks.Count -eq 4 -and -not $oldStateLeft
    'planning kept spec and commands'  = $nextPlan.spec -eq '.orchestrator/spec-next.md' -and $nextPlan.settings.setup -like '*skeleton.txt*'
    'plan that never ran needs -Force' = $neverRunStops -and $unfinishedNeedsForce
    '-Force archives, -Keep keeps'     = $forcedArchives.Count -eq 3 -and (Test-Path (Join-Path $forcedArchives[2].FullName '.orchestrator/tasks.json')) -and
        (@(Get-ChildItem $runDir -Force | Sort-Object Name).Name -join ',') -eq 'project.json,spec-next.md'
}
$planChecks.GetEnumerator() | ForEach-Object { Write-Host ("{0,-38} {1}" -f $_.Key, ($_.Value ? 'PASS' : 'FAIL')) -ForegroundColor ($_.Value ? 'Green' : 'Red') }
if ($planChecks.Values -contains $false) { Write-Host "Archive-on-plan test FAILED. Repo left at $repo"; exit 1 }
& (Join-Path $orch 'Clear-Orchestrator.ps1') -RepoPath $repo -All
Remove-Item $WorkDir -Recurse -Force
Write-Host 'Smoke test passed.' -ForegroundColor Green
