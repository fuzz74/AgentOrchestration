#requires -Version 7.2
<#
.SYNOPSIS
    Makes a throwaway practice repo with the fake agent, for trying orchestrator commands by hand
    without a real project and without spending tokens.
.DESCRIPTION
    Always uses <temp>\orch-practice and replaces what a previous call left there. The repo is
    <temp>\orch-practice\demo and its spec <temp>\orch-practice\spec.md. -Stage sets how far it gets:
      Run      (default) a finished run: four tasks done, the result on orch/integration, not merged
      Planned  a plan with four tasks, none started
      Failing  the same plan, but feature-b always fails, and feature-a takes 20 seconds longer, so
               the run is still going when feature-b fails
      Empty    a project skeleton with one commit and no plan
    The orchestrator's output goes to <temp>\orch-practice\setup.log, apart from the run's progress
    lines, which the worker threads write to the screen. Close any VS Code window or terminal that
    is open in the practice folder first: Windows can't delete a folder that is in use.
.EXAMPLE
    .\tests\New-PracticeRepo.ps1 -Stage Planned
#>
param(
    [ValidateSet('Run', 'Planned', 'Failing', 'Empty')][string]$Stage = 'Run',
    [ValidateSet('Claude', 'Copilot')][string]$Provider = 'Claude'
)

$ErrorActionPreference = 'Stop'
$orch = Join-Path $PSScriptRoot '..\orchestrator'
$fake = Join-Path $PSScriptRoot 'fake-claude.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) 'orch-practice'
$repo = Join-Path $root 'demo'
$spec = Join-Path $root 'spec.md'
$log = Join-Path $root 'setup.log'
$marker = Join-Path $root '.orch-practice'

if (Test-Path $root) {
    # Only replace a folder this script made.
    if (-not (Test-Path $marker)) { throw "$root exists, but this script did not make it. Move or delete it yourself." }
    # Right after a run, its last processes or a virus scan can hold a file for a moment.
    for ($try = 1; Test-Path $root; $try++) {
        try { Remove-Item $root -Recurse -Force }
        catch {
            if ($try -ge 5) { throw "Could not delete $root. Close any VS Code window or terminal that is open in it, then try again. ($($_.Exception.Message))" }
            Start-Sleep -Seconds 1
        }
    }
}
Remove-Item (Join-Path ([IO.Path]::GetTempPath()) 'fake-claude') -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $root | Out-Null
Set-Content $marker 'Made by tests\New-PracticeRepo.ps1, which replaces this folder each time it runs.'
Set-Content $spec 'Build A and B on top of shared contracts, then wire them together.'

$common = @{ Provider = $Provider; RepoPath = $repo; AgentPath = $fake }
try {
    if ($Stage -eq 'Empty') {
        & (Join-Path $orch 'Initialize-Project.ps1') @common -Spec $spec *> $log
    }
    else {
        & (Join-Path $orch 'Plan-Tasks.ps1') @common -Spec $spec *> $log
        if ($Stage -eq 'Failing') {
            $planFile = Join-Path $repo '.orchestrator\tasks.json'
            $doc = Get-Content $planFile -Raw | ConvertFrom-Json -AsHashtable
            foreach ($t in $doc.tasks) {
                if ($t.id -eq 'feature-a') { $t.acceptance = "Start-Sleep -Seconds 20; $($t.acceptance)" }
                if ($t.id -eq 'feature-b') { $t.acceptance = "Write-Output 'feature-b never passes in this practice repo'; exit 1" }
            }
            $doc | ConvertTo-Json -Depth 20 | Set-Content $planFile -Encoding utf8
        }
        if ($Stage -eq 'Run') {
            & (Join-Path $orch 'Invoke-Orchestrator.ps1') @common *>> $log
            if ($LASTEXITCODE -ne 0) { throw "The run ended with exit code $LASTEXITCODE." }
        }
    }
}
catch {
    Get-Content $log -Tail 20 -ErrorAction SilentlyContinue | Write-Host
    throw "Making the practice repo failed: $($_.Exception.Message) Full output: $log"
}

$what = @{
    Run     = 'a finished run: four tasks done, the result on orch/integration, not merged yet'
    Planned = 'a plan with four tasks, none started'
    Failing = 'a plan with four tasks, none started, in which feature-b always fails and feature-a is slow'
    Empty   = "a project skeleton with one commit and no plan. Spec for planning: $spec"
}[$Stage]
Write-Host "Practice repo ready: $repo" -ForegroundColor Green
Write-Host "It has $what."
