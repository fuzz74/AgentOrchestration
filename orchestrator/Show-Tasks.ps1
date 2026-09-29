#requires -Version 7.2
<#
.SYNOPSIS
    Shows the task graph with each task's wave, status, attempts and cost. Validates the plan.
.EXAMPLE
    ./Show-Tasks.ps1 -RepoPath C:\src\myapp
#>
[CmdletBinding()]
param([string]$RepoPath = '.', [string]$Plan)

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
$state = Read-State $paths
$waves = Get-Waves $planObj.Tasks
$planObj.Tasks | ForEach-Object {
    $s = $state.tasks[$_.id]
    [pscustomobject]@{
        Wave     = $waves[$_.id]
        Task     = $_.id
        Status   = Get-TaskDisplayStatus $_ $planObj $state
        Deps     = $_.deps -join ', '
        Attempts = if ($s) { $s.attempts } else { 0 }
        CostUsd  = if ($s) { [math]::Round([double]$s.costUsd, 2) } else { 0 }
        Detail   = if ($s -and $s.error) { ($s.error -split "`n")[0] } elseif ($s) { $s.summary } else { $_.title }
    }
} | Sort-Object Wave, Task | Format-Table -AutoSize -Wrap
