#requires -Version 7.2
# Fake-agent checks of the arguments sent through the public planning and running entry points.
$ErrorActionPreference = 'Stop'
$orch = Join-Path $PSScriptRoot '..\orchestrator'
$fake = Join-Path $PSScriptRoot 'fake-claude.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) "orch-model-settings-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $root | Out-Null
$env:GIT_AUTHOR_NAME = 'Model Settings Test'
$env:GIT_AUTHOR_EMAIL = 'model-settings@example.com'
$env:GIT_COMMITTER_NAME = 'Model Settings Test'
$env:GIT_COMMITTER_EMAIL = 'model-settings@example.com'
Import-Module (Join-Path $orch 'Orchestrator.psm1') -Force

function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -cne $Expected) { throw "$Label`: expected '$Expected', got '$Actual'." }
}
function Get-Flag($Call, [string]$Flag) {
    $index = [array]::IndexOf([object[]]$Call.arguments, $Flag)
    if ($index -ge 0) { return $Call.arguments[$index + 1] }
    $null
}
function Get-Calls([string]$Directory, [string]$Role) {
    @(Get-ChildItem $Directory -Filter '*.json' | ForEach-Object {
        $call = Get-Content $_.FullName -Raw | ConvertFrom-Json
        if ($call.role -eq $Role) { $call }
    })
}
function Assert-Role([string]$Directory, [string]$Role, [string]$Model, $Effort, [string]$Provider) {
    $calls = @(Get-Calls $Directory $Role)
    if (-not $calls.Count) { throw "No $Role calls were captured in $Directory." }
    foreach ($call in $calls) {
        Assert-Equal (Get-Flag $call '--model') $Model "$Role model"
        $flag = if ($Provider -eq 'Copilot') { '--reasoning-effort' } else { '--effort' }
        Assert-Equal (Get-Flag $call $flag) $Effort "$Role effort"
        if ($Provider -eq 'Claude' -and (Get-Flag $call '--reasoning-effort')) { throw "$Role received a Copilot effort flag." }
    }
}
function New-Baseline([string]$Name) {
    $repo = Join-Path $root $Name
    New-Item -ItemType Directory -Path $repo | Out-Null
    & git -C $repo init -q -b main
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    Set-Content (Join-Path $repo 'README.md') 'Example project'
    & git -C $repo add README.md
    & git -C $repo commit -qm 'Example baseline'
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
    $repo
}
function Write-Plan([string]$Repo, [string]$Provider, [hashtable]$Settings, [switch]$TwoTasks, [string]$TaskModel) {
    $tasks = @(@{
        id = 'contracts'; title = 'Contracts'; prompt = 'Write contracts.'
        deps = @(); owns = @('contracts/**')
        acceptance = "if (-not (Test-Path 'contracts/contracts.txt')) { exit 1 }"
    })
    if ($TaskModel) { $tasks[0].model = $TaskModel }
    if ($TwoTasks) {
        $tasks += @{
            id = 'feature-a'; title = 'Feature A'; prompt = 'Build A.'
            deps = @('contracts'); owns = @('a/**')
            acceptance = "if (-not (Test-Path 'a/feature-a.txt')) { exit 1 }"
        }
    }
    $run = Join-Path $Repo '.orchestrator'
    New-Item -ItemType Directory -Force -Path $run | Out-Null
    $plan = Join-Path $run 'tasks.json'
    @{ version = 1; provider = $Provider; settings = $Settings; tasks = $tasks } |
        ConvertTo-Json -Depth 10 | Set-Content $plan
    $plan
}
function Run-Case([string]$Name, [string]$PlanProvider, [string]$RuntimeProvider,
                  [hashtable]$Settings, [string]$WorkerModel, [string]$ReviewModel,
                  $Effort, [string]$TaskModel, [switch]$TwoTasks) {
    $repo = New-Baseline $Name
    $plan = Write-Plan $repo $PlanProvider $Settings -TaskModel $TaskModel -TwoTasks:$TwoTasks
    $loaded = Read-Plan -PlanFile $plan -Repo $repo -Provider $RuntimeProvider
    if ((Test-Plan $loaded).Count) { throw "Invalid $Name plan: $((Test-Plan $loaded) -join ', ')" }
    $capture = Join-Path $root "$Name-args"
    $env:FAKE_CAPTURE_ARGS = $capture
    & (Join-Path $orch 'Invoke-Orchestrator.ps1') -Provider $RuntimeProvider -RepoPath $repo -AgentPath $fake -MaxParallel 1 -PollSeconds 1
    if ($LASTEXITCODE -ne 0) { throw "$Name run failed (exit $LASTEXITCODE)." }
    $workers = @(Get-Calls $capture 'worker')
    if ($TwoTasks) {
        $contract = @($workers | Where-Object { $_.cwd -like '*contracts' })
        $feature = @($workers | Where-Object { $_.cwd -like '*feature-a' })
        if ($contract.Count -ne 1 -or $feature.Count -ne 1) { throw 'Worker calls for both task overrides were not captured.' }
        Assert-Equal (Get-Flag $contract[0] '--model') $TaskModel 'per-task worker model'
        Assert-Equal (Get-Flag $feature[0] '--model') $WorkerModel 'settings worker model'
    }
    else { Assert-Role $capture 'worker' $WorkerModel $Effort $RuntimeProvider }
    Assert-Role $capture 'reviewer' $ReviewModel $Effort $RuntimeProvider
    foreach ($call in $workers) {
        $flag = if ($RuntimeProvider -eq 'Copilot') { '--reasoning-effort' } else { '--effort' }
        Assert-Equal (Get-Flag $call $flag) $Effort 'worker effort'
    }
    Write-Host "$Name PASS"
}

$completed = $false
try {
    $spec = Join-Path $root 'spec.md'
    Set-Content $spec 'Build example contracts.'
    $defaultCapture = Join-Path $root 'default-plan-args'
    $env:FAKE_CAPTURE_ARGS = $defaultCapture
    $defaultRepo = Join-Path $root 'default-project'
    & (Join-Path $orch 'Plan-Tasks.ps1') -Provider Copilot -Spec $spec -RepoPath $defaultRepo -AgentPath $fake
    Assert-Role $defaultCapture 'bootstrap' 'gpt-6.1-sol' 'high' 'Copilot'
    Assert-Role $defaultCapture 'planner' 'gpt-6.1-sol' 'high' 'Copilot'
    $defaultPlan = Get-Content (Join-Path $defaultRepo '.orchestrator/tasks.json') -Raw | ConvertFrom-Json
    Assert-Equal $defaultPlan.settings.model 'gpt-6.1-sol' 'persisted Copilot model'
    Assert-Equal $defaultPlan.settings.reviewModel 'gpt-6.1-sol' 'persisted Copilot review model'
    if ($null -ne $defaultPlan.settings.effort) { throw 'An omitted WorkerEffort should persist as null.' }

    $explicitRepo = Join-Path $root 'explicit-project'
    $explicitCapture = Join-Path $root 'explicit-plan-args'
    $env:FAKE_CAPTURE_ARGS = $explicitCapture
    & (Join-Path $orch 'Initialize-Project.ps1') -Provider Copilot -Spec $spec -RepoPath $explicitRepo -AgentPath $fake -Model 'account/bootstrap-model' -Effort none
    Assert-Role $explicitCapture 'bootstrap' 'account/bootstrap-model' 'none' 'Copilot'
    & (Join-Path $orch 'Plan-Tasks.ps1') -Provider Copilot -Spec $spec -RepoPath $explicitRepo -AgentPath $fake `
        -Model 'account/planner-model' -Effort max -WorkerModel 'account/worker-model' -WorkerEffort minimal
    Assert-Role $explicitCapture 'planner' 'account/planner-model' 'max' 'Copilot'
    $explicitPlan = Get-Content (Join-Path $explicitRepo '.orchestrator/tasks.json') -Raw | ConvertFrom-Json
    Assert-Equal $explicitPlan.settings.model 'account/worker-model' 'persisted worker model'
    Assert-Equal $explicitPlan.settings.reviewModel 'account/worker-model' 'persisted reviewer model'
    Assert-Equal $explicitPlan.settings.effort 'minimal' 'persisted effort'
    Write-Host 'bootstrap and planner flags PASS'

    Run-Case 'claude-plan-copilot-run' Claude Copilot @{} 'gpt-6.1-sol' 'gpt-6.1-sol' 'high' ''
    Run-Case 'copilot-plan-claude-run' Copilot Claude @{} 'sonnet' 'sonnet' $null ''
    Run-Case 'worker-only-override' Copilot Copilot @{ model = 'account/settings-model'; effort = 'minimal' } `
        'account/settings-model' 'gpt-6.1-sol' 'minimal' 'account/task-model' -TwoTasks
    Run-Case 'review-only-override' Copilot Copilot @{ reviewModel = 'account/review-model'; effort = $null } `
        'gpt-6.1-sol' 'account/review-model' 'high' ''
    Run-Case 'claude-ids-under-copilot' Claude Copilot @{ model = 'sonnet'; reviewModel = 'haiku'; effort = 'none' } `
        'opus' 'haiku' 'none' 'opus'

    $env:FAKE_CAPTURE_ARGS = Join-Path $root 'effort-level-args'
    foreach ($level in 'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max') {
        $r = Invoke-Agent -Provider Copilot -AgentPath $fake -WorkDir $defaultRepo -Model 'account/unlisted-model' `
            -Effort $level -Prompt '<!-- orchestrator-role: reviewer -->'
        if (-not $r.Ok) { throw "Effort $level failed: $($r.Error)" }
    }
    $levelCalls = @(Get-Calls $env:FAKE_CAPTURE_ARGS 'reviewer')
    Assert-Equal $levelCalls.Count 7 'supported effort invocation count'
    $levels = @($levelCalls | ForEach-Object { Get-Flag $_ '--reasoning-effort' } | Sort-Object)
    if (($levels -join ',') -cne (('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max' | Sort-Object) -join ',')) {
        throw "Incorrect reasoning effort flags: $($levels -join ', ')"
    }
    foreach ($call in $levelCalls) { Assert-Equal (Get-Flag $call '--model') 'account/unlisted-model' 'unlisted model' }

    $badEffort = try {
        $null = Invoke-Agent -Provider Copilot -AgentPath $fake -WorkDir $defaultRepo -Effort invalid -Prompt 'ignored'
        $null
    } catch { $_.Exception.Message }
    if ($badEffort -notlike "*Invalid effort 'invalid'*") { throw "Invalid effort was not rejected: $badEffort" }
    $env:FAKE_REJECT_MODEL = 'account/unavailable-model'
    try {
        $rejected = Invoke-Agent -Provider Copilot -AgentPath $fake -WorkDir $defaultRepo `
            -Model $env:FAKE_REJECT_MODEL -Effort max -Prompt '<!-- orchestrator-role: reviewer -->'
        if ($rejected.Ok -or $rejected.Error -notlike "*Model 'account/unavailable-model' is unavailable*") {
            throw "CLI rejection was not surfaced: $($rejected.Error)"
        }
    }
    finally { Remove-Item Env:FAKE_REJECT_MODEL -ErrorAction SilentlyContinue }
    $env:FAKE_REJECT_EFFORT = 'max'
    try {
        $rejected = Invoke-Agent -Provider Copilot -AgentPath $fake -WorkDir $defaultRepo `
            -Model 'account/unlisted-model' -Effort max -Prompt '<!-- orchestrator-role: reviewer -->'
        if ($rejected.Ok -or $rejected.Error -notlike "*Reasoning effort 'max' is unsupported*") {
            throw "CLI model/effort rejection was not surfaced: $($rejected.Error)"
        }
    }
    finally { Remove-Item Env:FAKE_REJECT_EFFORT -ErrorAction SilentlyContinue }

    $schemaRepo = New-Baseline 'schema'
    $schemaPlan = Write-Plan $schemaRepo Copilot @{}
    foreach ($level in 'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', $null) {
        $doc = Get-Content $schemaPlan -Raw | ConvertFrom-Json -AsHashtable
        $doc.settings.effort = $level
        $doc.tasks[0].model = 'account/unlisted-model'
        $doc | ConvertTo-Json -Depth 10 | Set-Content $schemaPlan
        $errors = Test-Plan (Read-Plan -PlanFile $schemaPlan -Repo $schemaRepo -Provider Copilot)
        if ($errors.Count) { throw "Plan rejected effort '$level': $($errors -join ', ')" }
    }
    $doc.settings.effort = 'invalid'
    $doc | ConvertTo-Json -Depth 10 | Set-Content $schemaPlan
    if (-not (Test-Plan (Read-Plan -PlanFile $schemaPlan -Repo $schemaRepo -Provider Copilot)).Count) {
        throw 'Invalid plan effort was accepted.'
    }
    Write-Host 'effort levels, schema and CLI diagnostics PASS'
    $completed = $true
}
finally {
    Remove-Item Env:FAKE_CAPTURE_ARGS, Env:FAKE_REJECT_MODEL, Env:FAKE_REJECT_EFFORT -ErrorAction SilentlyContinue
    if ($completed) { Remove-Item -LiteralPath $root -Recurse -Force }
}
