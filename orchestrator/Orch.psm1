# The short `orch` command. It runs an orchestrator script for the repo that holds the current
# folder, so you type no path. Install-Orch.ps1 loads this module from the PowerShell profile.

$script:Commands = [ordered]@{
    status = @{ Script = 'Show-Tasks.ps1'; Help = 'Show the tasks of the current run.' }
}

function Get-OrchRepo {
    # The main checkout of the repo around the current folder. In a worktree, such as
    # <repo>.worktrees\_integration, git lists the main checkout first.
    $lines = @(git worktree list --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0 -or $lines[0] -notlike 'worktree *') { return $null }
    [IO.Path]::GetFullPath($lines[0].Substring(9))
}

function Show-OrchUsage {
    Write-Host 'Usage: orch <command> [flags]'
    foreach ($name in $script:Commands.Keys) {
        Write-Host ('  {0,-8} {1} ({2})' -f $name, $script:Commands[$name].Help, $script:Commands[$name].Script)
    }
    Write-Host 'Run it anywhere inside a repo. Other flags go to the script, for example: orch status -Plan other.json'
}

function orch {
    # A plain function, not an advanced one, so flags such as -Plan reach the script unchanged.
    # @() keeps a single flag a list: splatting a lone string would pass its characters.
    $command, $rest = $args
    $rest = @($rest | Where-Object { $null -ne $_ })
    if (-not $command -or $command -in 'help', '--help', '-h') { Show-OrchUsage; return }
    $entry = $script:Commands[$command]
    if (-not $entry) { Write-Host "orch: unknown command '$command'." -ForegroundColor Red; Show-OrchUsage; return }
    $file = Join-Path $PSScriptRoot $entry.Script
    try {
        if ($rest -match '^-RepoPath(:|$)') { & $file @rest; return }
        $repo = Get-OrchRepo
        if (-not $repo) { Write-Host "orch: $((Get-Location).Path) isn't inside a git repo." -ForegroundColor Red; return }
        Write-Host "orch: repo $repo" -ForegroundColor DarkGray
        & $file -RepoPath $repo @rest
    }
    catch { Write-Host "orch: $($_.Exception.Message)" -ForegroundColor Red }
}

Export-ModuleMember -Function orch
