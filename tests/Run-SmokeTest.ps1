#requires -Version 7.2
<#
.SYNOPSIS
    End-to-end test of plan -> schedule -> gate -> merge using fake-claude.ps1 (no tokens spent).
    Builds a throwaway git repo, plans 4 tasks (one diamond: contracts -> a, b -> wire-up),
    makes feature-b fail its first attempt, and checks everything lands on orch/integration.
#>
param([string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) "orch-smoke-$(Get-Random)"))

$ErrorActionPreference = 'Stop'
$orch = Join-Path $PSScriptRoot '..\orchestrator'
$fake = Join-Path $PSScriptRoot 'fake-claude.ps1'
Remove-Item (Join-Path ([IO.Path]::GetTempPath()) 'fake-claude') -Recurse -Force -ErrorAction SilentlyContinue

$repo = Join-Path $WorkDir 'demo'
New-Item -ItemType Directory -Force -Path $repo | Out-Null
git -C $repo init -q -b main
git -C $repo config user.email 'smoke@example.com'
git -C $repo config user.name 'Smoke Test'
Set-Content (Join-Path $repo 'README.md') '# demo'
git -C $repo add -A; git -C $repo commit -q -m 'init'
$spec = Join-Path $WorkDir 'spec.md'
Set-Content $spec "Build A and B on top of shared contracts, then wire them together."

$env:FAKE_FAIL_ONCE = 'feature-b'
$env:FAKE_SHARED = '1'
$env:FAKE_NO_STRUCTURED = 'contracts'
try {
    & (Join-Path $orch 'Plan-Tasks.ps1') -Spec $spec -RepoPath $repo -ClaudePath $fake
    # Let every task touch registry.txt so the parallel tasks conflict and the resolver path runs.
    $planFile = Join-Path $repo '.orchestrator/tasks.json'
    $planDoc = Get-Content $planFile -Raw | ConvertFrom-Json -AsHashtable
    $planDoc.settings.shared = @('registry.txt')
    $planDoc | ConvertTo-Json -Depth 10 | Set-Content $planFile
    & (Join-Path $orch 'Invoke-Orchestrator.ps1') -RepoPath $repo -ClaudePath $fake -MaxParallel 2 -PollSeconds 1
    $exit = $LASTEXITCODE
}
finally { Remove-Item Env:FAKE_FAIL_ONCE, Env:FAKE_SHARED, Env:FAKE_NO_STRUCTURED }

$files = git -C $repo ls-tree -r --name-only orch/integration
$state = Get-Content (Join-Path $repo '.orchestrator/state.json') -Raw | ConvertFrom-Json -AsHashtable
$checks = [ordered]@{
    'orchestrator exit code 0'          = $exit -eq 0
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
& (Join-Path $orch 'Clear-Orchestrator.ps1') -RepoPath $repo -All
Remove-Item $WorkDir -Recurse -Force
Write-Host 'Smoke test passed.' -ForegroundColor Green
