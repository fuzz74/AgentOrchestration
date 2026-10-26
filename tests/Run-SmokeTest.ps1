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

# Compare the independent runtime and fake-agent deny lists, not just their observed CLI behavior.
$runtimeSkills = [regex]::Match((Get-Content (Join-Path $orch 'Orchestrator.psm1') -Raw),
    '(?m)^\$script:OrchestratorSkills\s*=\s*@\((?<names>[^\r\n]*)\)')
$fakeSkills = [regex]::Match((Get-Content $fake -Raw),
    "(?m)^\s*@\((?<names>'write-spec'[^)]*)\s*\|")
$skillNames = { param($Match) @([regex]::Matches($Match.Groups['names'].Value, "'([^']+)'") |
    ForEach-Object { $_.Groups[1].Value }) }
$expectedSkills = 'write-spec', 'plan-tasks', 'auto-develop', 'orch', 'analyze', 'auto-analyze', 'write-spec-analyze'
if (-not $runtimeSkills.Success -or -not $fakeSkills.Success -or
    ((& $skillNames $runtimeSkills) -join ',') -cne ($expectedSkills -join ',') -or
    ((& $skillNames $fakeSkills) -join ',') -cne ($expectedSkills -join ',')) {
    throw 'Runtime and fake-agent headless skill deny lists must match all seven orchestrator skills.'
}
Write-Host 'Runtime and fake deny lists match all seven skills PASS' -ForegroundColor Green

$env:FAKE_FAIL_ONCE = 'feature-b'
$env:FAKE_SHARED = '1'
$env:FAKE_NO_STRUCTURED = 'contracts'
$env:FAKE_CAPTURE_ARGS = Join-Path $WorkDir 'agent-arguments'
$env:FAKE_CHECK_SKILL_BLOCK = '1'
try {
    & (Join-Path $orch 'Plan-Tasks.ps1') -Provider $Provider -Spec $spec -RepoPath $repo -AgentPath $fake -WorkerType Coding
    # The fake planner lists registry.txt as shared. Every task touches it, so the parallel tasks
    # conflict and the resolver path runs.
    $planFile = Join-Path $repo '.orchestrator/tasks.json'
    $planDoc = Get-Content $planFile -Raw | ConvertFrom-Json -AsHashtable
    $plannerShared = @($planDoc.settings.shared) -join ','
    $reference = Join-Path $WorkDir 'reference library'
    New-Item -ItemType Directory -Path $reference | Out-Null
    $planDoc.settings.additionalDirectories = @('../reference library')
    if ($Provider -eq 'Copilot') {
        if ($planDoc.settings.model -ne 'gpt-6.1-sol' -or $planDoc.settings.reviewModel -ne 'gpt-6.1-sol') { throw 'Copilot plan did not use GPT-6.1 Sol defaults.' }
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
    Import-Module (Join-Path $orch 'Orchestrator.psm1') -Force
    if ($Provider -eq 'Copilot') {
        $review = Invoke-Agent -Provider Copilot -AgentPath $fake -WorkDir $repo -Model 'gpt-6.1-sol' `
            -Prompt ("orchestrator-role: reviewer`n" + ('x' * 50000))
        $longPromptOk = $review.Finished -and $review.Exit -eq 0
    }
    # With no wait between heartbeat lines, the tool calls of the fake planner's sub-agent call give one at once.
    & (Get-Module Orchestrator) { $script:HeartbeatSeconds = 0 }
    $heartbeatLog = Join-Path $WorkDir 'heartbeat.md'
    $null = Invoke-Agent -Provider $Provider -AgentPath $fake -WorkDir $repo -Model 'gpt-6.1-sol' -Tools Read, Glob, Grep `
        -AllowedTools Read, Glob, Grep -SubAgents -Prompt '<!-- orchestrator-role: planner -->' `
        -ProgressFile $heartbeatLog -ActivityLabel '[heartbeat]' -Activity 'heartbeat'
    $heartbeatOk = (Get-Content $heartbeatLog -Raw -ErrorAction SilentlyContinue) -match '\[heartbeat\] \d+ tool calls, last: '
    # claude and copilot are native programs that write UTF-8 whatever the console code page. A .cmd that
    # types a UTF-8 file does the same, unlike the in-process fake-claude.ps1. With the console on code
    # page 437, as on an English Windows, the agent's events and result must still hold ↳, › and ….
    $utf8Ok = $true
    if ($IsWindows) {
        $nativeFake = New-Item -ItemType Directory -Force (Join-Path $WorkDir 'native-claude')
        $utf8Text = 'Survey ↳ path › more…'
        $utf8Events = @(
            @{ type = 'assistant'; session_id = 'utf8'; message = @{ content = @(@{ type = 'text'; text = $utf8Text }) } }
            @{ type = 'result'; subtype = 'success'; is_error = $false; session_id = 'utf8'; total_cost_usd = 0; result = $utf8Text; structured_output = @{ summary = $utf8Text } }
        ) | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }
        [IO.File]::WriteAllText((Join-Path $nativeFake 'events.jsonl'), ($utf8Events -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
        Set-Content (Join-Path $nativeFake 'claude.cmd') '@type "%~dp0events.jsonl"' -Encoding ascii
        [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(437)
        $utf8Log = Join-Path $WorkDir 'utf8.json'
        $utf8Run = Invoke-Agent -Provider Claude -AgentPath (Join-Path $nativeFake 'claude.cmd') -WorkDir $repo -Prompt 'utf8' -LogPath $utf8Log
        $utf8Ok = $utf8Run.Structured.summary -eq $utf8Text -and $utf8Run.Text -eq $utf8Text -and
            (Get-Content "$utf8Log.events.jsonl" -Raw -Encoding utf8).Contains($utf8Text)
    }
}
finally {
    Remove-Item Env:FAKE_FAIL_ONCE, Env:FAKE_SHARED, Env:FAKE_NO_STRUCTURED, Env:FAKE_REQUIRE_MODEL, Env:FAKE_REQUIRE_ADD_DIR, Env:FAKE_CHECK_SKILL_BLOCK -ErrorAction SilentlyContinue
}

$files = git -C $repo ls-tree -r --name-only orch/integration
$state = Get-Content (Join-Path $repo '.orchestrator/state.json') -Raw | ConvertFrom-Json -AsHashtable
$agentCalls = @(Get-ChildItem (Join-Path $WorkDir 'agent-arguments') -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
function Get-AgentFlag($Call, $Flag) {
    $index = [array]::IndexOf([object[]]$Call.arguments, $Flag)
    if ($index -ge 0) { return $Call.arguments[$index + 1] }
    $null
}
$roleCalls = { param($Role) @($agentCalls | Where-Object role -eq $Role) }
$modelFlagsOk = if ($Provider -eq 'Copilot') {
    @(& $roleCalls 'bootstrap' | Where-Object { (Get-AgentFlag $_ '--model') -ne 'gpt-6.1-sol' -or (Get-AgentFlag $_ '--reasoning-effort') -ne 'high' }).Count -eq 0 -and
    @(& $roleCalls 'planner' | Where-Object { (Get-AgentFlag $_ '--name') -eq 'orch:planner' -and
        ((Get-AgentFlag $_ '--model') -ne 'gpt-6.1-sol' -or (Get-AgentFlag $_ '--reasoning-effort') -ne 'high') }).Count -eq 0 -and
    @(& $roleCalls 'worker' | Where-Object { (Get-AgentFlag $_ '--model') -notin 'sonnet', 'opus' -or (Get-AgentFlag $_ '--reasoning-effort') -ne 'high' }).Count -eq 0 -and
    @(& $roleCalls 'reviewer' | Where-Object { (Get-AgentFlag $_ '--name') -like 'orch:*:review' -and
        ((Get-AgentFlag $_ '--model') -ne 'haiku' -or (Get-AgentFlag $_ '--reasoning-effort') -ne 'high') }).Count -eq 0 -and
    @(& $roleCalls 'resolver' | Where-Object { (Get-AgentFlag $_ '--model') -ne 'haiku' -or (Get-AgentFlag $_ '--reasoning-effort') -ne 'high' }).Count -eq 0
} else {
    @(& $roleCalls 'bootstrap' | Where-Object { (Get-AgentFlag $_ '--model') -ne 'sonnet' -or $null -ne (Get-AgentFlag $_ '--effort') }).Count -eq 0 -and
    @(& $roleCalls 'planner' | Where-Object { (Get-AgentFlag $_ '--name') -eq 'orch:planner' -and
        ((Get-AgentFlag $_ '--model') -ne 'opus' -or $null -ne (Get-AgentFlag $_ '--effort')) }).Count -eq 0 -and
    @(& $roleCalls 'worker' | Where-Object { (Get-AgentFlag $_ '--model') -ne 'sonnet' -or $null -ne (Get-AgentFlag $_ '--effort') }).Count -eq 0 -and
    @(& $roleCalls 'reviewer' | Where-Object { (Get-AgentFlag $_ '--model') -ne 'sonnet' -or $null -ne (Get-AgentFlag $_ '--effort') }).Count -eq 0 -and
    @(& $roleCalls 'resolver' | Where-Object { (Get-AgentFlag $_ '--model') -ne 'sonnet' -or $null -ne (Get-AgentFlag $_ '--effort') }).Count -eq 0
}
$planSettings = (Get-Content $planFile -Raw | ConvertFrom-Json).settings
$plannerPrompt = Get-Content (Get-ChildItem (Join-Path $repo '.orchestrator/logs') -Filter 'planner-*-1.json.prompt.md' | Select-Object -First 1) -Raw
$planningRules = (Get-Content (Join-Path $orch 'prompts/planning-rules.md') -Raw).TrimEnd()
$workerPrompt = Get-Content (Get-ChildItem (Join-Path $repo '.orchestrator/logs/contracts') -Recurse -Filter 'attempt-1-worker.json.prompt.md' | Select-Object -First 1) -Raw
$analysisReview = Get-Content (Get-ChildItem (Join-Path $repo '.orchestrator/logs/contracts') -Recurse -Filter 'attempt-1-review-1.json.prompt.md' | Select-Object -First 1) -Raw
$codingWorker = Get-Content (Get-ChildItem (Join-Path $repo '.orchestrator/logs/feature-a') -Recurse -Filter 'attempt-1-worker.json.prompt.md' | Select-Object -First 1) -Raw
$codingReview = Get-Content (Get-ChildItem (Join-Path $repo '.orchestrator/logs/feature-a') -Recurse -Filter 'attempt-1-review-1.json.prompt.md' | Select-Object -First 1) -Raw
$legacyFile = Join-Path $WorkDir 'legacy-plan.json'
$legacyDoc = Get-Content $planFile -Raw | ConvertFrom-Json -AsHashtable
$legacyDoc.settings.Remove('workerType')
foreach ($task in $legacyDoc.tasks) { $task.Remove('workerType') }
$legacyDoc | ConvertTo-Json -Depth 10 | Set-Content $legacyFile
$legacyPlan = Read-Plan -PlanFile $legacyFile -Repo $repo
$legacyCoding = -not (Test-Plan $legacyPlan).Count -and $legacyPlan.Settings.workerType -eq 'coding' -and
    @($legacyPlan.Tasks | Where-Object { $_.workerType -ne 'coding' }).Count -eq 0
$legacyDoc.tasks[0].workerType = 'unknown'
$legacyDoc | ConvertTo-Json -Depth 10 | Set-Content $legacyFile
$invalidRoleRejected = (Test-Plan (Read-Plan -PlanFile $legacyFile -Repo $repo)).Count -gt 0
Remove-Item $legacyFile
$foreground = if ($Provider -eq 'Copilot') { 'the `task` tool, in the foreground (`mode: "sync"`)' } else { 'the Agent tool, in the foreground (`run_in_background: false`)' }
# The fake planner and workers each ask a sub-agent; the watch views mark its activity with its description.
$conversations = & (Join-Path $orch 'Watch-Conversations.ps1') -RepoPath $repo -Task contracts -Last 500 -Once 6>&1 | Out-String
$timeline = & (Join-Path $orch 'Watch-AgentTimeline.ps1') -RepoPath $repo -Task contracts -Last 500 -Once 6>&1 | Out-String
# Without a plan the dashboard shows the latest planner session. It writes to the console, so it runs in its own process.
$dashboardArgs = @('-NoProfile', '-File', (Join-Path $orch 'Watch-Orchestrator.ps1'), '-Provider', $Provider, '-RepoPath', $repo, '-Plan', (Join-Path $repo 'no-plan.json'), '-Once')
$dashboard = & (Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')) @dashboardArgs | Out-String
# The same session cut before its last result, as it looks while a background sub-agent still works.
$plannerEvents = Get-ChildItem (Join-Path $repo '.orchestrator/logs') -Filter 'planner-*-1.json.events.jsonl' | Select-Object -First 1
$unfinished = Join-Path $repo '.orchestrator/logs/planner-unfinished.json.events.jsonl'
Get-Content $plannerEvents.FullName | Select-Object -SkipLast 1 | Set-Content $unfinished
$dashboardUnfinished = & (Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')) @dashboardArgs | Out-String
Remove-Item $unfinished
# orch run from inside a worktree finds the main checkout, a relative -Plan follows cd, and orch watch
# takes the provider the plan records.
$orchCommand = "Import-Module '$(Join-Path $orch 'Orch.psm1')'; Set-Location '$(Join-Path $WorkDir 'demo.worktrees/_integration')'; " +
    "orch status -Plan ../../demo/.orchestrator/tasks.json | Out-String -Width 200; orch watch -Once"
$orchOutput = & (Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')) -NoProfile -Command $orchCommand | Out-String
$checks = [ordered]@{
    'skeleton fixed and amended'        = (git -C $repo rev-list --count main) -eq '1' -and @('skeleton.txt', 'tool.txt' | Where-Object { $_ -notin (git -C $repo ls-tree -r --name-only main) }).Count -eq 0
    'plan uses skeleton commands'       = $planSettings.setup -like '*skeleton.txt*' -and $planSettings.integrationCheck -like '*tool.txt*'
    'plan uses planner shared files'    = $plannerShared -eq 'registry.txt'
    'planner received shared rules'     = $plannerPrompt.Contains($planningRules) -and -not $plannerPrompt.Contains('{{PLANNING_RULES}}')
    'coding bootstrap and default prompts' = $planSettings.workerType -eq 'coding' -and $plannerPrompt.Contains('default worker type for this run is `coding`') -and
        $workerPrompt.Contains('coding agents building') -and $analysisReview.Contains('You review one task from an automated multi-agent build') -and
        $codingWorker.Contains('coding agents building') -and $codingReview.Contains('You review one task from an automated multi-agent build')
    'legacy coding and unknown role rejected' = $legacyCoding -and $invalidRoleRejected
    'prompts explain sub-agents'        = @($plannerPrompt, $workerPrompt | Where-Object { -not ($_ -replace '\s+', ' ').Contains($foreground) -or $_.Contains('{{SUBAGENTS}}') }).Count -eq 0 -and
        $workerPrompt.Contains('not to edit files') -and -not $plannerPrompt.Contains('not to edit files')
    'watch views label sub-agents'      = $conversations.Contains('[contracts/worker#1 ↳ Survey the fake repo][REQUEST]') -and
        $conversations.Contains('[contracts/worker#1 ↳ Survey the fake repo][RESPONSE]') -and
        $timeline -match '\[TOOL START\] ↳ \[Survey the fake repo\] glob' -and $dashboard -match '\[Survey the fake repo\] glob'
    'only the last result ends a session' = $dashboard -match 'planner - finished' -and $dashboardUnfinished -match 'planner - working'
    'integration check ran after merge' = @(Get-ChildItem (Join-Path $repo '.orchestrator/logs') -Filter '*-integration-check.log').Count -eq 4
    # Merges are checked on a detached HEAD; the integration worktree must end back on the branch.
    'integration worktree on its branch' = (git -C (Join-Path $WorkDir 'demo.worktrees/_integration') symbolic-ref --short HEAD) -eq 'orch/integration'
    # Bootstrap, planner, workers, reviewers, resolver and nudge all ran in this first part.
    'headless agents cannot start skills' = -not (Test-Path (Join-Path ([IO.Path]::GetTempPath()) 'fake-claude/skill-block-missing.txt'))
    'agent roles receive configured flags' = $modelFlagsOk -and @(& $roleCalls 'bootstrap').Count -gt 0 -and
        @(& $roleCalls 'planner' | Where-Object { (Get-AgentFlag $_ '--name') -eq 'orch:planner' }).Count -gt 0 -and
        @(& $roleCalls 'worker').Count -gt 0 -and
        @(& $roleCalls 'reviewer' | Where-Object { (Get-AgentFlag $_ '--name') -like 'orch:*:review' }).Count -gt 0 -and
        @(& $roleCalls 'resolver').Count -gt 0
    'orch status from a worktree'       = $orchOutput -match 'orch: repo .*[\\/]demo\r?\n' -and $orchOutput -match 'wire-up\s+done'
    'orch watch uses the plan provider' = $planDoc.provider -ceq $Provider -and $orchOutput -match "provider $Provider \(from the plan\)" -and
        $orchOutput -match "Live $Provider CLI processes"
    'orchestrator exit code 0'          = $exit -eq 0
    'duplicate run rejected'            = $duplicateRejected
    'reference directory passed to agents' = $exit -eq 0
    'reference directory in worker prompt' = (Get-Content (Get-ChildItem (Join-Path $repo '.orchestrator/logs/contracts') -Recurse -Filter 'attempt-1-worker.json.prompt.md' | Select-Object -First 1) -Raw).Contains([IO.Path]::GetFullPath($reference), ($IsWindows ? 'OrdinalIgnoreCase' : 'Ordinal'))
    'long Copilot prompt uses stdin'    = $longPromptOk
    'agents write heartbeat lines'      = $heartbeatOk
    'agent output read as UTF-8'        = $utf8Ok
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
if ($Provider -eq 'Copilot') { $retryPlan.settings.effort = 'xhigh' }
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
$retryWait = & (Join-Path $orch 'Wait-Orchestrator.ps1') -RepoPath $repo -Once *>&1 | Out-String
$retryWaitExit = $LASTEXITCODE
$retryChecks = [ordered]@{
    'quality bug retried beyond three' = $retryState.tasks['quality-only'].status -eq 'done' -and $retryState.tasks['quality-only'].attempts -eq 5
    'five spec rejections stop task'    = $retryState.tasks['spec-only'].status -eq 'failed' -and $retryState.tasks['spec-only'].attempts -eq 5
    'rejection leaves earlier work done' = $retryExit -eq 2 -and $retryState.tasks['contracts'].status -eq 'done'
    'property-named task ids run'      = @('count', 'keys', 'values' | Where-Object { $retryState.tasks[$_].status -ne 'done' }).Count -eq 0
    'wait reports the failed task'     = $retryWaitExit -eq 2 -and $retryWait -match 'No run is active: 1 failed \(spec-only\)' -and $retryWait -match 'spec-only failed:'
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
if ($Provider -eq 'Copilot') {
    $laterCalls = @(Get-ChildItem (Join-Path $WorkDir 'agent-arguments') -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
    foreach ($role in 'worker', 'reviewer') {
        $retryCalls = @($laterCalls | Where-Object {
            $_.role -eq $role -and (Get-AgentFlag $_ '--name') -match '^orch:(quality-only|spec-only|pause-retry)(:review)?$'
        })
        if ($retryCalls.Count -lt 2 -or @($retryCalls | Where-Object { (Get-AgentFlag $_ '--reasoning-effort') -ne 'xhigh' }).Count) {
            throw "$role retries did not preserve settings.effort xhigh."
        }
    }
    $resumedWorker = @($laterCalls | Where-Object {
        $_.role -eq 'worker' -and $_.cwd -like '*pause-retry' -and
        (Get-AgentFlag $_ '--resume') -and (Get-AgentFlag $_ '--reasoning-effort') -eq 'xhigh'
    })
    if (-not $resumedWorker.Count) { throw 'Resumed worker did not retain xhigh effort.' }
    Write-Host 'Copilot retries and resume retain effort PASS' -ForegroundColor Green
}
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

# The same flow through orch. No plan is left, so orch plan takes the provider that the plans above
# saved in project.json; orch run takes it from the new plan. main already holds the fake task files,
# so FAKE_SHARED gives every task a change to commit.
$orchFlow = "Import-Module '$(Join-Path $orch 'Orch.psm1')'; Set-Location '$repo'; " +
    "orch plan .orchestrator/spec-next.md -AgentPath '$fake'; orch run -AgentPath '$fake'; 'orch run exit ' + `$LASTEXITCODE; " +
    "orch wait -Once; 'orch wait exit ' + `$LASTEXITCODE"
$env:FAKE_SHARED = '1'
try { $orchFlowOutput = & (Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')) -NoProfile -Command $orchFlow | Out-String }
finally { Remove-Item Env:FAKE_SHARED }
$orchState = Get-Content (Join-Path $runDir 'state.json') -Raw | ConvertFrom-Json -AsHashtable
$orchChecks = [ordered]@{
    'orch plan takes project.json provider' = $orchFlowOutput -match "provider $Provider \(from project\.json\)"
    'orch run takes the plan provider'     = $orchFlowOutput -match "provider $Provider \(from the plan\)"
    'orch run finished every task'         = $orchFlowOutput -match 'orch run exit 0' -and $orchState.tasks.psbase.Count -eq 4 -and
        @($orchState.tasks.Values | Where-Object { $_.status -ne 'done' }).Count -eq 0
    'orch wait reports all done'           = $orchFlowOutput -match 'No run is active: all 4 tasks are done' -and $orchFlowOutput -match 'orch wait exit 0'
}
$orchChecks.GetEnumerator() | ForEach-Object { Write-Host ("{0,-38} {1}" -f $_.Key, ($_.Value ? 'PASS' : 'FAIL')) -ForegroundColor ($_.Value ? 'Green' : 'Red') }
if ($orchChecks.Values -contains $false) { Write-Host "orch plan and run test FAILED. Repo left at $repo"; exit 1 }

# orch finish stops when main got a commit during the run; -Force then merges and archives.
Set-Content (Join-Path $repo 'moved.txt') 'a change on main during the run'
git -C $repo add moved.txt
git -C $repo commit -q -m 'Change on main during the run'
$archivesBefore = @(Get-ChildItem $runsRoot -Directory).Count
$orchFinish = { param($flags) & (Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')) -NoProfile -Command "Import-Module '$(Join-Path $orch 'Orch.psm1')'; Set-Location '$repo'; orch finish $flags" | Out-String }
$finishStopped = & $orchFinish '-Yes'
$integrationKept = (git -C $repo for-each-ref --format='%(refname:short)' refs/heads/orch/integration) -eq 'orch/integration'
$finishForced = & $orchFinish '-Yes -Force'
$finishChecks = [ordered]@{
    'orch finish stops when main moved' = $finishStopped -match 'got 1 new commit' -and $integrationKept
    'orch finish -Force merges, archives' = $finishForced -match 'Run archived to' -and (git -C $repo log -1 --format=%s main) -eq "Merge branch 'orch/integration'" -and
        @(git -C $repo for-each-ref refs/heads/orch/).Count -eq 0 -and @(Get-ChildItem $runsRoot -Directory).Count -eq $archivesBefore + 1
}
$finishChecks.GetEnumerator() | ForEach-Object { Write-Host ("{0,-38} {1}" -f $_.Key, ($_.Value ? 'PASS' : 'FAIL')) -ForegroundColor ($_.Value ? 'Green' : 'Red') }
if ($finishChecks.Values -contains $false) { Write-Host "orch finish test FAILED. Repo left at $repo"; exit 1 }

# A separate analysis run uses the same fake planner, worker, reviewer and integration path.
$analysisRepo = Join-Path $WorkDir 'analysis-example'
$analysisSpec = Join-Path $WorkDir 'analysis-spec.md'
Set-Content $analysisSpec 'Investigate the question and save the evidence in the repository.'
$bootstrapCalls = @(Get-Content (Join-Path ([IO.Path]::GetTempPath()) 'fake-claude/bootstrap-calls.txt')).Count
$env:FAKE_CHECK_SKILL_BLOCK = '1'
$env:FAKE_NO_CHANGE_ONCE = 'contracts'
try {
    & (Join-Path $orch 'Plan-Tasks.ps1') -Provider $Provider -Spec $analysisSpec -RepoPath $analysisRepo -AgentPath $fake -WorkerType Analysis
    $analysisPlanFile = Join-Path $analysisRepo '.orchestrator/tasks.json'
    $analysisPlan = Get-Content $analysisPlanFile -Raw | ConvertFrom-Json -AsHashtable
    $analysisProject = Get-Content (Join-Path $analysisRepo '.orchestrator/project.json') -Raw | ConvertFrom-Json -AsHashtable
    $baselineFiles = @(git -C $analysisRepo ls-tree -r --name-only main)
    $analysisPlannerPrompt = Get-Content (Get-ChildItem (Join-Path $analysisRepo '.orchestrator/logs') -Filter 'planner-*-1.json.prompt.md' | Select-Object -First 1) -Raw
    $analysisPlan.settings.shared = @()
    $analysisPlan | ConvertTo-Json -Depth 10 | Set-Content $analysisPlanFile
    & (Join-Path $orch 'Invoke-Orchestrator.ps1') -Provider $Provider -RepoPath $analysisRepo -AgentPath $fake -MaxParallel 2 -PollSeconds 1
    $analysisExit = $LASTEXITCODE
    $analysisState = Get-Content (Join-Path $analysisRepo '.orchestrator/state.json') -Raw | ConvertFrom-Json -AsHashtable
    $noChangeRetry = Get-Content (Get-ChildItem (Join-Path $analysisRepo '.orchestrator/logs/contracts') -Recurse -Filter 'attempt-2-worker.json.prompt.md' | Select-Object -First 1) -Raw
    $analysisWorker = Get-Content (Get-ChildItem (Join-Path $analysisRepo '.orchestrator/logs/contracts') -Recurse -Filter 'attempt-1-worker.json.prompt.md' | Select-Object -First 1) -Raw
    $analysisReviewer = Get-Content (Get-ChildItem (Join-Path $analysisRepo '.orchestrator/logs/contracts') -Recurse -Filter 'attempt-2-review-1.json.prompt.md' | Select-Object -First 1) -Raw
    $toolWorker = Get-Content (Get-ChildItem (Join-Path $analysisRepo '.orchestrator/logs/feature-a') -Recurse -Filter 'attempt-1-worker.json.prompt.md' | Select-Object -First 1) -Raw
    $toolReviewer = Get-Content (Get-ChildItem (Join-Path $analysisRepo '.orchestrator/logs/feature-a') -Recurse -Filter 'attempt-1-review-1.json.prompt.md' | Select-Object -First 1) -Raw
    $integrationFiles = @(git -C $analysisRepo ls-tree -r --name-only orch/integration)
    $analysisChecks = [ordered]@{
        'analysis baseline has only README' = (git -C $analysisRepo rev-list --count main) -eq '1' -and
            ($baselineFiles -join ',') -eq 'README.md' -and (Get-Content (Join-Path $analysisRepo 'README.md') -Raw) -match 'project deliverables'
        'analysis skips bootstrap and commands' = @(Get-Content (Join-Path ([IO.Path]::GetTempPath()) 'fake-claude/bootstrap-calls.txt')).Count -eq $bootstrapCalls -and
            $analysisProject.Contains('setup') -and $null -eq $analysisProject.setup -and
            $analysisProject.Contains('integrationCheck') -and $null -eq $analysisProject.integrationCheck -and
            $null -eq $analysisPlan.settings.setup -and $null -eq $analysisPlan.settings.integrationCheck
        'mixed worker and reviewer routing' = $analysisPlan.settings.workerType -eq 'analysis' -and
            $analysisPlannerPrompt.Contains('default worker type for this run is `analysis`') -and
            $analysisWorker.Contains('analysis agents investigating') -and $analysisReviewer.Contains('review one analysis task') -and
            $toolWorker.Contains('coding agents building') -and $toolReviewer.Contains('You review one task from an automated multi-agent build')
        'analysis integrates committed result' = $analysisExit -eq 0 -and
            @($analysisState.tasks.Values | Where-Object { $_.status -ne 'done' }).Count -eq 0 -and
            @('contracts/contracts.txt', 'a/feature-a.txt', 'b/feature-b.txt', 'app/wire-up.txt' |
                Where-Object { $_ -notin $integrationFiles }).Count -eq 0 -and
            @(git -C $analysisRepo log --format=%s orch/integration | Where-Object { $_ -match 'contracts|feature-a' }).Count -gt 0
        'analysis headless skills denied' = -not (Test-Path (Join-Path ([IO.Path]::GetTempPath()) 'fake-claude/skill-block-missing.txt'))
        'analysis no-change retry gives repo feedback' = $analysisState.tasks['contracts'].attempts -eq 2 -and
            $noChangeRetry.Contains('Save the requested result in your owned repo paths') -and
            -not $noChangeRetry.Contains('Create the project skeleton')
    }
    $analysisChecks.GetEnumerator() | ForEach-Object { Write-Host ("{0,-38} {1}" -f $_.Key, ($_.Value ? 'PASS' : 'FAIL')) -ForegroundColor ($_.Value ? 'Green' : 'Red') }
    if ($analysisChecks.Values -contains $false) { throw "Analysis smoke test FAILED. Repo left at $analysisRepo" }
    $existingHead = (git -C $analysisRepo rev-parse HEAD).Trim()
    $existingTree = (git -C $analysisRepo rev-parse 'HEAD^{tree}').Trim()
    $existingStatus = @(git -C $analysisRepo status --porcelain=v1 --untracked-files=all) -join "`n"
    $existingIndex = @(git -C $analysisRepo ls-files --stage) -join "`n"
    $existingReadme = Get-Content (Join-Path $analysisRepo 'README.md') -Raw
    $existingConfig = Get-Content (Join-Path $analysisRepo '.orchestrator/project.json') -Raw
    & (Join-Path $orch 'Initialize-Project.ps1') -Provider $Provider -Spec $analysisSpec -RepoPath $analysisRepo `
        -AgentPath (Join-Path $WorkDir 'missing-agent') -WorkerType Analysis
    $existingNoOp = (git -C $analysisRepo rev-parse HEAD).Trim() -eq $existingHead -and
        (git -C $analysisRepo rev-parse 'HEAD^{tree}').Trim() -eq $existingTree -and
        (@(git -C $analysisRepo status --porcelain=v1 --untracked-files=all) -join "`n") -ceq $existingStatus -and
        (@(git -C $analysisRepo ls-files --stage) -join "`n") -ceq $existingIndex -and
        (Get-Content (Join-Path $analysisRepo 'README.md') -Raw) -ceq $existingReadme -and
        (Get-Content (Join-Path $analysisRepo '.orchestrator/project.json') -Raw) -eq $existingConfig
    Write-Host ("{0,-38} {1}" -f 'existing committed repo is unchanged', ($existingNoOp ? 'PASS' : 'FAIL')) -ForegroundColor ($existingNoOp ? 'Green' : 'Red')
    if (-not $existingNoOp) { throw 'Initialization changed an existing committed repo.' }
    git -C $analysisRepo merge -q --no-ff --no-edit orch/integration
    if ($LASTEXITCODE -ne 0) { throw 'Analysis integration could not merge into main.' }
    & (Join-Path $orch 'Complete-Orchestrator.ps1') -RepoPath $analysisRepo
    $analysisArchived = @(Get-ChildItem "$analysisRepo.runs" -Directory).Count -eq 1 -and
        -not (Test-Path "$analysisRepo.worktrees") -and @(git -C $analysisRepo for-each-ref refs/heads/orch/).Count -eq 0 -and
        (git -C $analysisRepo ls-tree -r --name-only main) -contains 'contracts/contracts.txt'
    Write-Host ("{0,-38} {1}" -f 'analysis uses merge and finish lifecycle', ($analysisArchived ? 'PASS' : 'FAIL')) -ForegroundColor ($analysisArchived ? 'Green' : 'Red')
    if (-not $analysisArchived) { throw 'Analysis merge or finish lifecycle failed.' }

    $preservedRepo = Join-Path $WorkDir 'existing-example'
    New-Item -ItemType Directory -Force (Join-Path $preservedRepo '.orchestrator') | Out-Null
    git -C $preservedRepo init -q -b main
    Set-Content (Join-Path $preservedRepo 'README.md') 'Original README'
    Set-Content (Join-Path $preservedRepo 'staged.txt') 'Staged user content'
    Set-Content (Join-Path $preservedRepo 'untracked.txt') 'Untracked user content'
    git -C $preservedRepo add -- staged.txt
    $configFile = Join-Path $preservedRepo '.orchestrator/project.json'
    $config = '{"setup":"echo existing setup","integrationCheck":"echo existing check","custom":{"keep":true}}'
    Set-Content $configFile $config
    $indexBefore = (git -C $preservedRepo ls-files --stage -- staged.txt) -join "`n"
    & (Join-Path $orch 'Initialize-Project.ps1') -Provider $Provider -Spec $analysisSpec -RepoPath $preservedRepo -AgentPath (Join-Path $WorkDir 'missing-agent') -WorkerType Analysis
    $baselineTree = @(git -C $preservedRepo ls-tree -r --name-only HEAD)
    $baselineHead = (git -C $preservedRepo rev-parse HEAD).Trim()
    $afterConfig = (Get-Content $configFile -Raw).TrimEnd()
    & (Join-Path $orch 'Initialize-Project.ps1') -Provider $Provider -Spec $analysisSpec -RepoPath $preservedRepo -AgentPath (Join-Path $WorkDir 'missing-agent') -WorkerType Analysis
    $preservedChecks = [ordered]@{
        'pre-existing README and index untouched' = (Get-Content (Join-Path $preservedRepo 'README.md') -Raw).Trim() -eq 'Original README' -and
            $baselineTree.Count -eq 0 -and ((git -C $preservedRepo ls-files --stage -- staged.txt) -join "`n") -eq $indexBefore
        'staged and untracked files retained' = (Test-Path (Join-Path $preservedRepo 'staged.txt')) -and
            (Test-Path (Join-Path $preservedRepo 'untracked.txt')) -and
            @('staged.txt', 'untracked.txt' | Where-Object { $_ -notin (git -C $preservedRepo ls-tree -r --name-only HEAD) }).Count -eq 2
        'no-commit configuration preserved' = $afterConfig -eq $config -and
            ((Get-Content $configFile -Raw | ConvertFrom-Json).custom.keep) -and
            (git -C $preservedRepo rev-parse HEAD).Trim() -eq $baselineHead
    }
    $preservedChecks.GetEnumerator() | ForEach-Object { Write-Host ("{0,-38} {1}" -f $_.Key, ($_.Value ? 'PASS' : 'FAIL')) -ForegroundColor ($_.Value ? 'Green' : 'Red') }
    if ($preservedChecks.Values -contains $false) { throw "Analysis preservation test FAILED. Repo left at $preservedRepo" }
    & (Join-Path $orch 'Plan-Tasks.ps1') -Provider $Provider -Spec $analysisSpec -RepoPath $preservedRepo -AgentPath $fake -WorkerType Analysis `
        -Setup 'echo override setup' -IntegrationCheck 'echo override check'
    $overridePlan = Get-Content (Join-Path $preservedRepo '.orchestrator/tasks.json') -Raw | ConvertFrom-Json
    $persistedConfig = Get-Content $configFile -Raw | ConvertFrom-Json
    $callerOk = $overridePlan.settings.workerType -eq 'analysis' -and
        $overridePlan.settings.setup -eq 'echo override setup' -and $overridePlan.settings.integrationCheck -eq 'echo override check' -and
        $persistedConfig.setup -eq 'echo existing setup' -and $persistedConfig.integrationCheck -eq 'echo existing check' -and
        $persistedConfig.custom.keep -and (git -C $preservedRepo rev-parse HEAD).Trim() -eq $baselineHead -and
        ((git -C $preservedRepo ls-files --stage -- staged.txt) -join "`n") -eq $indexBefore
    Write-Host ("{0,-38} {1}" -f 'caller forwards role; overrides plan only', ($callerOk ? 'PASS' : 'FAIL')) -ForegroundColor ($callerOk ? 'Green' : 'Red')
    if (-not $callerOk) { throw 'Analysis planning caller did not preserve project config or baseline.' }

    $stagedReadmeRepo = Join-Path $WorkDir 'staged-readme-example'
    New-Item -ItemType Directory -Path $stagedReadmeRepo | Out-Null
    git -C $stagedReadmeRepo init -q -b main
    Set-Content (Join-Path $stagedReadmeRepo 'README.md') 'Staged README'
    git -C $stagedReadmeRepo add -- README.md
    Remove-Item (Join-Path $stagedReadmeRepo 'README.md')
    $stagedReadmeIndex = (git -C $stagedReadmeRepo ls-files --stage -- README.md) -join "`n"
    & (Join-Path $orch 'Initialize-Project.ps1') -Provider $Provider -Spec $analysisSpec -RepoPath $stagedReadmeRepo -WorkerType Analysis -AgentPath (Join-Path $WorkDir 'missing-agent')
    $stagedReadmeOk = -not (Test-Path (Join-Path $stagedReadmeRepo 'README.md')) -and
        @((git -C $stagedReadmeRepo ls-tree -r --name-only HEAD)).Count -eq 0 -and
        ((git -C $stagedReadmeRepo ls-files --stage -- README.md) -join "`n") -eq $stagedReadmeIndex
    Write-Host ("{0,-38} {1}" -f 'staged-only README remains untouched', ($stagedReadmeOk ? 'PASS' : 'FAIL')) -ForegroundColor ($stagedReadmeOk ? 'Green' : 'Red')
    if (-not $stagedReadmeOk) { throw 'Staged-only README was changed.' }
}
finally {
    Remove-Item Env:FAKE_CHECK_SKILL_BLOCK, Env:FAKE_NO_CHANGE_ONCE -ErrorAction SilentlyContinue
    $gitIdentity.Keys | ForEach-Object { Remove-Item "Env:$_" }
}
& (Join-Path $orch 'Clear-Orchestrator.ps1') -RepoPath $repo -All
Remove-Item $WorkDir -Recurse -Force
Write-Host 'Smoke test passed.' -ForegroundColor Green
