#requires -Version 7.2
<#
.SYNOPSIS
    Finishes a run: archives the run record and removes the worktrees and orch/* branches.

.DESCRIPTION
    Moves everything in .orchestrator except project.json to <repo>.runs\<timestamp>\.orchestrator
    (the archive also gets a copy of project.json), and removes the worktrees under
    <repo>.worktrees and the orch/* branches. The next plan then starts from a clean folder.
    Refuses while a run is active. Refuses a run that is not finished (a task that is not done,
    commits on the integration branch that the base branch lacks, or uncommitted changes in a
    worktree) unless -Force, which archives it as it is and deletes those changes.
    Plan-Tasks.ps1 does the same by itself before it plans on a finished run.

.EXAMPLE
    ./Complete-Orchestrator.ps1 -RepoPath C:\src\myapp
    ./Complete-Orchestrator.ps1 -RepoPath C:\src\myapp -Keep spec-next.md   # leave the next spec in .orchestrator
    ./Complete-Orchestrator.ps1 -RepoPath C:\src\myapp -Force               # archive an unfinished run
#>
[CmdletBinding(SupportsShouldProcess)]
param([string]$RepoPath = '.', [string[]]$Keep, [switch]$Force)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Orchestrator.psm1') -Force
$paths = Get-OrchPaths -RepoPath $RepoPath

$archive = Complete-Run $paths -Keep $Keep -Force:$Force -WhatIf:$WhatIfPreference
if ($archive) { Write-Host "Run archived to $archive" }
