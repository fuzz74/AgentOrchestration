#requires -Version 7.2
<#
.SYNOPSIS
    Removes task worktrees and orch/task/* branches. Optionally also the integration branch and run state.
.EXAMPLE
    ./Clear-Orchestrator.ps1 -Provider Copilot -RepoPath C:\src\myapp                 # task worktrees + branches only
    ./Clear-Orchestrator.ps1 -Provider Copilot -RepoPath C:\src\myapp -All            # also integration branch, state and logs
#>
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][ValidateSet('Claude', 'Copilot')][string]$Provider, [string]$RepoPath = '.', [switch]$All)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Orchestrator.psm1') -Force
$paths = Get-OrchPaths -RepoPath $RepoPath

$worktrees = (Invoke-Git $paths.Repo @('worktree', 'list', '--porcelain')).Output -split "`n" |
    Where-Object { $_ -like 'worktree *' } | ForEach-Object { [IO.Path]::GetFullPath($_.Substring(9)) } |
    Where-Object { $_.StartsWith($paths.WorktreeRoot, [StringComparison]::OrdinalIgnoreCase) }
foreach ($wt in $worktrees) {
    if (-not $All -and $wt -eq $paths.IntegrationWorktree) { continue }
    if ($PSCmdlet.ShouldProcess($wt, 'git worktree remove')) { [void](Invoke-Git $paths.Repo @('worktree', 'remove', '--force', $wt)) }
}
[void](Invoke-Git $paths.Repo @('worktree', 'prune'))

$branches = (Invoke-Git $paths.Repo @('for-each-ref', '--format=%(refname:short)', 'refs/heads/orch/')).Output -split "`n" | Where-Object { $_ }
foreach ($b in $branches) {
    if (-not $All -and $b -notlike 'orch/task/*') { continue }
    if ($PSCmdlet.ShouldProcess($b, 'git branch -D')) { [void](Invoke-Git $paths.Repo @('branch', '-D', $b)) }
}

if ($All) {
    foreach ($f in $paths.StateFile, $paths.LogDir, $paths.ProgressFile) {
        if ((Test-Path $f) -and $PSCmdlet.ShouldProcess($f, 'Remove')) { Remove-Item -Recurse -Force $f }
    }
    if ((Test-Path $paths.WorktreeRoot) -and -not (Get-ChildItem $paths.WorktreeRoot -Force)) { Remove-Item $paths.WorktreeRoot }
}
else {
    # Task branches are gone, so only 'done' tasks keep meaning; everything else starts fresh.
    if (Test-Path $paths.StateFile) {
        $state = Read-State $paths
        foreach ($k in @($state.tasks.Keys)) {
            $s = $state.tasks[$k]
            if ($s.status -ne 'done') { $s.status = 'pending'; $s.mode = 'fresh'; $s.sessionId = $null; $s.error = $null }
        }
        Save-State $paths $state
    }
}
Write-Host 'Cleaned up.'
