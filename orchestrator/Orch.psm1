# The short `orch` command. It runs an orchestrator script for the repo that holds the current
# folder, so you type no path. Install-Orch.ps1 loads this module from the PowerShell profile.

$script:Commands = [ordered]@{
    plan     = @{ Script = 'Plan-Tasks.ps1'; Help = 'Plan the tasks from a spec: orch plan <spec>.'; Provider = $true }
    run      = @{ Script = 'Invoke-Orchestrator.ps1'; Help = 'Run the plan (-DryRun only shows the waves).'; Provider = $true }
    status   = @{ Script = 'Show-Tasks.ps1'; Help = 'Show the tasks of the current run.' }
    watch    = @{ Script = 'Watch-Orchestrator.ps1'; Help = 'Live dashboard of the run.'; Provider = $true }
    timeline = @{ Script = 'Watch-AgentTimeline.ps1'; Help = 'Follow the steps of the run as a timeline.' }
    talk     = @{ Script = 'Watch-Conversations.ps1'; Help = 'Follow the conversations with the agents.' }
    stop     = @{ Script = 'Request-OrchestratorStop.ps1'; Help = 'Pause the run once active agents finish (-Cancel undoes it).' }
}

function Get-OrchRepo {
    # The main checkout of the repo around the current folder. In a worktree, such as
    # <repo>.worktrees\_integration, git lists the main checkout first.
    $lines = @(git worktree list --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0 -or $lines[0] -notlike 'worktree *') { return $null }
    [IO.Path]::GetFullPath($lines[0].Substring(9))
}

function Get-OrchArg {
    # The value given for -Name among the flags. `-Name:value` arrives as '-Name:' and then the value.
    param([object[]]$Rest, [string]$Name)
    for ($i = 0; $i -lt $Rest.Count; $i++) {
        if ("$($Rest[$i])" -match "^-$Name(:(.+))?:?$") {
            if ($Matches[2]) { return $Matches[2] }
            if ($i + 1 -lt $Rest.Count) { return "$($Rest[$i + 1])" }
        }
    }
}

function Resolve-OrchProvider {
    # -Provider, then the provider the plan was made for, then the provider of the repo's last plan
    # (project.json), then the user's default (ORCH_PROVIDER). The registry covers terminals of an
    # editor that was started before the default was set.
    param([string]$Repo, [object[]]$Rest)
    $flag = Get-OrchArg $Rest 'Provider'
    if ($flag) { return @{ Name = $flag; From = '-Provider'; Given = $true } }
    $planArg = Get-OrchArg $Rest 'Plan'
    $planFile = if ($planArg) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($planArg) }
                else { Join-Path $Repo '.orchestrator\tasks.json' }
    $planned = if (Test-Path $planFile) { try { (Get-Content $planFile -Raw | ConvertFrom-Json).provider } catch { $null } }
    if ($planned) { return @{ Name = $planned; From = 'the plan' } }
    $projectFile = Join-Path $Repo '.orchestrator\project.json'
    $remembered = if (Test-Path $projectFile) { try { (Get-Content $projectFile -Raw | ConvertFrom-Json).provider } catch { $null } }
    if ($remembered) { return @{ Name = $remembered; From = 'project.json' } }
    $default = $env:ORCH_PROVIDER ?? [Environment]::GetEnvironmentVariable('ORCH_PROVIDER', 'User')
    if ($default) { return @{ Name = $default; From = 'your default' } }
}

function Show-OrchUsage {
    Write-Host 'Usage: orch <command> [flags]'
    foreach ($name in $script:Commands.Keys) {
        Write-Host ('  {0,-9} {1} ({2})' -f $name, $script:Commands[$name].Help, $script:Commands[$name].Script)
    }
    Write-Host 'Run it anywhere inside a repo. Other flags go to the script, for example: orch watch -Once'
}

function orch {
    # A plain function, not an advanced one, so flags such as -Once reach the script unchanged.
    # @() keeps a single flag a list: splatting a lone string would pass its characters.
    $command, $rest = $args
    $rest = @($rest | Where-Object { $null -ne $_ })
    if (-not $command -or $command -in 'help', '--help', '-h') { Show-OrchUsage; return }
    $entry = $script:Commands[$command]
    if (-not $entry) { Write-Host "orch: unknown command '$command'." -ForegroundColor Red; Show-OrchUsage; return }
    $file = Join-Path $PSScriptRoot $entry.Script
    try {
        $named = @{}
        $repo = Get-OrchArg $rest 'RepoPath'
        if (-not $repo) {
            $repo = Get-OrchRepo
            if (-not $repo) {
                $hint = if ($command -eq 'plan') { ' For a new project, add -RepoPath <folder>.' } else { '' }
                Write-Host "orch: $((Get-Location).Path) isn't inside a git repo.$hint" -ForegroundColor Red
                return
            }
            $named.RepoPath = $repo
        }
        $header = "orch: repo $repo"
        if ($entry.Provider) {
            $provider = Resolve-OrchProvider $repo $rest
            if (-not $provider) {
                Write-Host 'orch: no provider. Add -Provider Claude or -Provider Copilot, or set your default with Install-Orch.ps1 -Provider.' -ForegroundColor Red
                return
            }
            if (-not $provider.Given) { $named.Provider = $provider.Name }
            $header += ", provider $($provider.Name) (from $($provider.From))"
        }
        Write-Host $header -ForegroundColor DarkGray
        & $file @named @rest
    }
    catch { Write-Host "orch: $($_.Exception.Message)" -ForegroundColor Red }
}

Export-ModuleMember -Function orch
