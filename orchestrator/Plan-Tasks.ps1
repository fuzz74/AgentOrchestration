#requires -Version 7.2
<#
.SYNOPSIS
    Turns a spec into a task graph (.orchestrator/tasks.json) with a read-only planner agent.

.DESCRIPTION
    A new project (the folder does not exist, is not a git repo, or has no commits) first gets
    its skeleton from Initialize-Project.ps1, which also supplies the default -Setup and
    -IntegrationCheck commands.
    A repo that still holds an earlier run (state.json) has that run archived first, the way
    Complete-Orchestrator.ps1 does it. If that run is not finished the script stops; -Force
    archives it anyway. A plan that never ran is only overwritten with -Force.
    Then runs the selected headless CLI in the target repo with read-only tools, asks for a plan that matches
    schemas/plan-output.schema.json, validates the graph (ids, deps, cycles) and writes
    tasks.json with the planner's shared files and default settings. If the graph is invalid the
    planner gets one chance to fix it.
    -Effort bounds the planner's reasoning (Claude only); -WorkerEffort is written to the plan's
    settings.effort. A model that reasons at length can spend its whole output budget thinking,
    hit the output-token limit and start over; a lower effort prevents that.
    Review and edit the file before running Invoke-Orchestrator.ps1.

.EXAMPLE
    ./Plan-Tasks.ps1 -Provider Copilot -Spec .\spec.md -RepoPath C:\src\myapp -Setup 'npm ci'
.EXAMPLE
    ./Plan-Tasks.ps1 -Provider Claude -Spec .\spec.md -RepoPath C:\src\myapp -Model fable -Effort medium -WorkerModel fable
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Spec,
    [Parameter(Mandatory)][ValidateSet('Claude', 'Copilot')][string]$Provider,
    [string]$RepoPath = '.',
    [string]$Out,
    [string]$Model = 'opus',
    [string]$WorkerModel = 'sonnet',
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')][string]$Effort,        # planner reasoning effort (Claude only)
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')][string]$WorkerEffort,  # written to settings.effort
    [string]$Setup,
    [string]$IntegrationCheck,
    [string]$AgentPath,
    [double]$MaxBudgetUsd = 0,   # 0 = no cap
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Orchestrator.psm1') -Force
$Model = Resolve-AgentModel -Provider $Provider -Model $Model
$WorkerModel = Resolve-AgentModel -Provider $Provider -Model $WorkerModel

# A new project gets its skeleton (git repo, manifest, test runner) before planning.
& (Join-Path $PSScriptRoot 'Initialize-Project.ps1') -Spec $Spec -RepoPath $RepoPath -Model $WorkerModel `
    -Provider $Provider -AgentPath $AgentPath -MaxBudgetUsd $MaxBudgetUsd

$paths = Get-OrchPaths -RepoPath $RepoPath -PlanFile $Out
if (Test-Path $paths.ProjectFile) {
    $project = Get-Content $paths.ProjectFile -Raw | ConvertFrom-Json
    if (-not $Setup) { $Setup = $project.setup }
    if (-not $IntegrationCheck) { $IntegrationCheck = $project.integrationCheck }
}
$specFull = (Resolve-Path $Spec).Path

# An earlier run is archived first, so a new plan never sits next to old state: a task that reuses an
# old id would count as done. An unfinished run stops here unless -Force. The spec stays if it lies
# in .orchestrator.
$archive = $null
if (Test-Path $paths.StateFile) {
    $keep = @($specFull | Where-Object { $_.StartsWith($paths.RunDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) })
    $archive = Complete-Run $paths -Keep $keep -Force:$Force
}
if ((Test-Path $paths.PlanFile) -and -not $Force) { throw "$($paths.PlanFile) exists. Use -Force to overwrite it." }
Initialize-RunDir $paths
if ($archive) { Write-OrchLog $paths.ProgressFile "Earlier run archived to $archive" }
$agent = Resolve-AgentPath -Provider $Provider -AgentPath $AgentPath

# Keep the spec next to the plan unless it already lives in the repo.
if ($specFull.StartsWith($paths.Repo, [StringComparison]::OrdinalIgnoreCase)) {
    $specRel = [IO.Path]::GetRelativePath($paths.Repo, $specFull).Replace('\', '/')
}
else {
    Copy-Item $specFull (Join-Path $paths.RunDir 'spec.md') -Force
    $specRel = '.orchestrator/spec.md'
}
$specText = Get-Content $specFull -Raw

$planningRules = Get-Content (Join-Path $PSScriptRoot 'prompts/planning-rules.md') -Raw
$prompt = Format-Template 'planner.md' @{ SPEC = $specText; PLANNING_RULES = $planningRules.TrimEnd() }
$logBase = Join-Path $paths.LogDir ("planner-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Write-OrchLog $paths.ProgressFile "Planning from $specRel with $Model"

$call = @{
    Provider = $Provider; AgentPath = $agent; WorkDir = $paths.Repo; Schema = 'plan-output.schema.json'; Model = $Model
    Effort = $Effort; PermissionMode = 'dontAsk'; Tools = @('Read', 'Glob', 'Grep'); AllowedTools = @('Read', 'Glob', 'Grep')
    MaxBudgetUsd = $MaxBudgetUsd; Name = 'orch:planner'
    ProgressFile = $paths.ProgressFile; ActivityLabel = '[planner]'; Activity = 'each'
}
$r = Invoke-Agent @call -Prompt $prompt -LogPath "$logBase-1.json"
$cost = $r.Cost
if (-not $r.Ok) { throw "Planner failed: $($r.Error)" }

$base = (Invoke-Git $paths.Repo @('rev-parse', '--abbrev-ref', 'HEAD')).Output
function New-PlanDoc($structured) {
    [ordered]@{
        version           = 1
        spec              = $specRel
        baseBranch        = $base
        integrationBranch = 'orch/integration'
        settings          = [ordered]@{
            model            = $WorkerModel
            reviewModel      = $WorkerModel
            effort           = if ($WorkerEffort) { $WorkerEffort } else { $null }
            maxAttempts      = 3
            review           = $true
            setup            = if ($Setup) { $Setup } else { $null }
            integrationCheck = if ($IntegrationCheck) { $IntegrationCheck } else { $null }
            shared           = @($structured.shared | Where-Object { $_ })
        }
        tasks             = @($structured.tasks | ForEach-Object {
                [ordered]@{
                    id = $_.id; title = $_.title; deps = @($_.deps); owns = @($_.owns)
                    acceptance = if ($_.acceptance) { $_.acceptance } else { $null }
                    prompt = $_.prompt
                }
            })
    }
}

for ($round = 1; $round -le 2; $round++) {
    $doc = New-PlanDoc $r.Structured
    $doc | ConvertTo-Json -Depth 10 | Set-Content -Path $paths.PlanFile -Encoding utf8
    $problems = Test-Plan (Read-Plan -PlanFile $paths.PlanFile -Repo $paths.Repo)
    if (-not $problems.Count) { break }
    if ($round -eq 2) {
        Write-Host "The plan still has problems. Fix $($paths.PlanFile) by hand:" -ForegroundColor Red
        $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        exit 1
    }
    Write-OrchLog $paths.ProgressFile "Plan invalid ($($problems.Count) problem(s)); asking the planner to fix it"
    $fix = "Your plan has these problems. Return the whole corrected plan.`n" + (($problems | ForEach-Object { "- $_" }) -join "`n")
    $r = Invoke-Agent @call -Prompt $fix -ResumeSessionId $r.SessionId -LogPath "$logBase-2.json"
    $cost += $r.Cost
    if (-not $r.Ok) { throw "Planner failed while fixing the plan: $($r.Error)" }
}

Write-OrchLog $paths.ProgressFile ("Plan written: {0} tasks, {1:N2} USD" -f $doc.tasks.Count, $cost)
if ($r.Structured.notes) { Write-Host "`nPlanner notes:`n$($r.Structured.notes)`n" -ForegroundColor Yellow }
& (Join-Path $PSScriptRoot 'Invoke-Orchestrator.ps1') -Provider $Provider -RepoPath $paths.Repo -Plan $paths.PlanFile -DryRun
Write-Host "`nReview and edit $($paths.PlanFile), then run:" -ForegroundColor Green
Write-Host "  $(Join-Path $PSScriptRoot 'Invoke-Orchestrator.ps1') -Provider $Provider -RepoPath `"$($paths.Repo)`""
