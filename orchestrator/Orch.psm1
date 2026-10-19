# The short `orch` command. It runs an orchestrator script for the repo that holds the current
# folder, so you type no path. Install-Orch.ps1 loads this module from the PowerShell profile.

$script:Commands = [ordered]@{
    plan     = @{ Script = 'Plan-Tasks.ps1'; Help = 'Plan the tasks from a spec: orch plan <spec>.'; Provider = $true }
    run      = @{ Script = 'Invoke-Orchestrator.ps1'; Help = 'Run the plan (-DryRun only shows the waves, -Window runs it in a new window).'; Provider = $true }
    status   = @{ Script = 'Show-Tasks.ps1'; Help = 'Show the tasks of the current run.' }
    wait     = @{ Script = 'Wait-Orchestrator.ps1'; Help = 'Wait until a task fails or the run ends.' }
    watch    = @{ Script = 'Watch-Orchestrator.ps1'; Help = 'Live dashboard of the run.'; Provider = $true }
    timeline = @{ Script = 'Watch-AgentTimeline.ps1'; Help = 'Follow the steps of the run as a timeline.' }
    talk     = @{ Script = 'Watch-Conversations.ps1'; Help = 'Follow the conversations with the agents.' }
    stop     = @{ Script = 'Request-OrchestratorStop.ps1'; Help = 'Pause the run once active agents finish (-Cancel undoes it).' }
    try      = @{ Function = 'Invoke-OrchTry'; Help = 'Open the result (the _integration worktree) in a new VS Code window.' }
    finish   = @{ Function = 'Invoke-OrchFinish'; Help = 'Merge the result into the base branch and archive the run, after you confirm.' }
}

function Invoke-OrchTry {
    param([string]$Repo, [object[]]$Rest)
    Import-Module (Join-Path $PSScriptRoot 'Orchestrator.psm1')
    $worktree = (Get-OrchPaths -RepoPath $Repo).IntegrationWorktree
    if (-not (Test-Path $worktree)) { throw "There is no integration worktree at $worktree yet. A run creates it." }
    $code = Get-Command code -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $code) { throw "VS Code's code command isn't on PATH. Open $worktree yourself." }
    & $code.Source -n $worktree
    Write-Host "Opened $worktree in a new VS Code window. Close that window before orch finish."
}

function Invoke-OrchFinish {
    # Merges the integration branch into the run's base branch and archives the run. It checks
    # everything it can first, then asks; -Yes skips the question. A base branch that got commits
    # during the run stops it, because the integration check never saw them; -Force merges anyway.
    # It never pushes.
    param([string]$Repo, [object[]]$Rest)
    $unknown = @($Rest | Where-Object { "$_" -notin '-Yes', '-Force' })
    if ($unknown.Count) { throw "orch finish takes only -Yes and -Force, not $($unknown -join ' ')." }
    Import-Module (Join-Path $PSScriptRoot 'Orchestrator.psm1')
    $paths = Get-OrchPaths -RepoPath $Repo
    if (-not (Test-Path $paths.PlanFile)) { throw "There is no run to finish: $($paths.PlanFile) doesn't exist." }
    $lock = Open-RunLock $paths
    if ($lock) { $lock.Dispose() }
    $here = (Get-Location).Path
    if ($here -eq $paths.WorktreeRoot -or $here.StartsWith($paths.WorktreeRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Your terminal is in $here, inside the run's worktrees, which finishing removes. Run cd $Repo first."
    }
    $doc = Get-Content $paths.PlanFile -Raw | ConvertFrom-Json -AsHashtable
    $int = if ($doc.integrationBranch) { $doc.integrationBranch } else { 'orch/integration' }
    $head = (Invoke-Git $Repo @('rev-parse', '--abbrev-ref', 'HEAD')).Output
    $base = if ($doc.baseBranch) { $doc.baseBranch } else { $head }
    # Get-RunProblems also reports the commits still to merge, which is what finishing does. It returns
    # one list, so the list is filtered once it is in a variable.
    $all = Get-RunProblems $paths
    $problems = @($all | Where-Object { $_ -notlike "$int has * commit(s) that $base lacks" })
    if ($problems.Count) { throw "The run isn't finished: $($problems -join '; ')." }
    if (-not (Test-GitBranch $Repo $int)) { throw "There is no $int branch to merge." }
    if ($head -ne $base) { throw "The main checkout is on $head, but the run was based on $base. Switch to it first: git switch $base" }
    $dirty = @((Invoke-Git $Repo @('status', '--porcelain', '--untracked-files=no')).Output -split "`n" | Where-Object { $_ })
    # Invoke-Git trims its output, so the first status line may have lost its leading space.
    if ($dirty.Count) { throw "The main checkout has uncommitted changes ($(($dirty | ForEach-Object { $_ -replace '^\s*\S+\s+' }) -join ', ')). Commit or stash them first." }
    $moved = [int](Invoke-Git $Repo @('rev-list', '--count', "$int..$base")).Output
    if ($moved -and $Rest -notcontains '-Force') {
        throw "$base got $moved new commit(s) during the run, which the integration check never saw. Merge $int into $base by hand, or run orch finish -Force to merge anyway."
    }
    $ahead = [int](Invoke-Git $Repo @('rev-list', '--count', "$base..$int")).Output

    Write-Host 'orch finish will:'
    Write-Host $(if ($ahead) { "  1. Merge $int ($ahead commit(s)) into $base in $Repo." } else { "  1. Merge nothing: $base already has everything from $int." })
    if ($moved) { Write-Host "     $base has $moved commit(s) the run never saw (-Force)." -ForegroundColor Yellow }
    Write-Host "  2. Archive the run to $($paths.ArchiveRoot)\<timestamp>, and remove its worktrees and orch/* branches."
    Write-Host '  It doesn''t push. Close any VS Code window that is open on a worktree, for example from orch try.'
    if ($Rest -notcontains '-Yes' -and (Read-Host 'Go ahead? [y/N]') -notmatch '^(y|yes)$') { Write-Host 'Nothing changed.'; return }

    if ($ahead) {
        $merge = Invoke-Git $Repo @('merge', '--no-ff', '--no-edit', $int)
        if ($merge.Exit -ne 0) {
            [void](Invoke-Git $Repo @('merge', '--abort'))
            throw "The merge failed and was undone, so nothing changed. Merge $int into $base by hand, then run orch finish again. Git said: $(($merge.Output -split "`n")[0])"
        }
        Write-Host "Merged $int into $base."
    }
    $archive = Complete-Run $paths
    Write-Host "Run archived to $archive." -ForegroundColor Green
    Write-Host "Push $base yourself if the repo has a remote."
}

function Start-OrchWindow {
    # Runs the script in a new PowerShell window, which stays open at the end. Windows' WMI service
    # creates the window, so it belongs neither to the caller's process tree nor to its job object:
    # closing the chat or the editor that started it doesn't end the run. It also gets the user's own
    # environment, as a new terminal would, not the caller's: a chat's shell carries its session's
    # variables, which the run's agents must not inherit. The process starts in the home folder and
    # only PowerShell's location moves to the repo: cd doesn't change a process's working folder, so
    # a window left open would otherwise keep the repo folder from being moved or deleted.
    param([string]$Repo, [string]$Script, [hashtable]$Named, [object[]]$Rest)
    if (-not $IsWindows) { throw 'orch run -Window works on Windows only. Run orch run in a terminal of its own.' }
    $quote = { param($value) "'" + ("$value" -replace "'", "''") + "'" }
    $words = @(foreach ($key in $Named.Keys) { "-$key"; & $quote $Named[$key] }) +
             @(foreach ($arg in $Rest) { if ("$arg" -match '^-[A-Za-z]\w*:?$') { "$arg" } else { & $quote $arg } })
    $title = "orch run: $(Split-Path $Repo -Leaf)"
    $command = @(
        "`$Host.UI.RawUI.WindowTitle = $(& $quote $title)"
        "Set-Location -LiteralPath $(& $quote $Repo)"
        "try { & $(& $quote $Script) $($words -join ' '); `$code = `$LASTEXITCODE } catch { Write-Host `$_ -ForegroundColor Red; `$code = 1 }"
        "Write-Host `"The run ended with exit code `$code. You can close this window.`""
    ) -join "`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $started = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = "`"$(Join-Path $PSHOME 'pwsh.exe')`" -NoExit -EncodedCommand $encoded"; CurrentDirectory = $HOME
    }
    if ($started.ReturnValue -ne 0) { throw "Windows could not open the run window (Win32_Process.Create returned $($started.ReturnValue))." }
    Write-Host "The run started in a new window, $title. orch status or orch watch shows it here."
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
        $c = $script:Commands[$name]
        Write-Host ('  {0,-9} {1}{2}' -f $name, $c.Help, $(if ($c.Script) { " ($($c.Script))" }))
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
        if ($entry.Function) {
            $others = @(for ($i = 0; $i -lt $rest.Count; $i++) { if ("$($rest[$i])" -match '^-RepoPath:?$') { $i++ } else { $rest[$i] } })
            & $entry.Function $repo $others
            return
        }
        if ($command -eq 'run' -and $rest -contains '-Window') {
            Start-OrchWindow $repo (Join-Path $PSScriptRoot $entry.Script) $named @($rest | Where-Object { "$_" -ne '-Window' })
            return
        }
        & (Join-Path $PSScriptRoot $entry.Script) @named @rest
    }
    catch { Write-Host "orch: $($_.Exception.Message)" -ForegroundColor Red }
}

Export-ModuleMember -Function orch
