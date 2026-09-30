#requires -Version 7.2
<#
.SYNOPSIS
    Lets active agents finish their current session, then pauses the orchestrator.
.EXAMPLE
    ./Request-OrchestratorStop.ps1 -RepoPath C:\src\myapp
#>
[CmdletBinding()]
param([string]$RepoPath = '.', [switch]$Cancel)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Orchestrator.psm1') -Force
$paths = Get-OrchPaths -RepoPath $RepoPath
if ($Cancel) {
    Remove-Item $paths.StopFile -Force -ErrorAction SilentlyContinue
    Write-Host "Stop request cleared for $($paths.Repo)."
    return
}
if (-not (Test-Path $paths.StateFile)) { throw "No orchestrator state found in $($paths.RunDir)." }
[IO.File]::WriteAllText($paths.StopFile, (Get-Date).ToString('o'))
Write-Host "Stop requested for $($paths.Repo). Active sessions may finish; the runner will then pause."