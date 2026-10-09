#requires -Version 7.2
# Shared functions for the agent orchestrator: plan and state files, the task graph,
# git worktrees, headless CLI calls, and the per-task pipeline
# (worker -> commit -> ownership check -> sync -> acceptance -> review).

$script:PromptDir = Join-Path $PSScriptRoot 'prompts'
$script:SchemaDir = Join-Path $PSScriptRoot 'schemas'
$script:CopilotModel = 'gpt-6-sol'
# Seconds between the summary lines of Invoke-Agent -Activity heartbeat.
$script:HeartbeatSeconds = 60
# claude.ai connectors hidden from every Claude agent. They stay enabled in interactive sessions.
$script:ClaudeDeniedMcpServers = @('mcp__claude_ai_Spotify', 'mcp__claude_ai_Strava', 'mcp__claude_ai_Claude_Docs')

$script:DefaultSettings = [ordered]@{
    model             = 'sonnet'
    reviewModel       = 'sonnet'
    effort            = $null
    permissionMode    = 'acceptEdits'
    allowedTools      = @('Read', 'Edit', 'Write', 'Glob', 'Grep', 'Bash', 'PowerShell')
    maxAttempts       = 3
    maxBudgetUsd      = 0     # 0 = no cap
    review            = $true
    setup             = $null
    integrationCheck  = $null
    commandTimeoutSec = 1800
    enforceOwns       = $true
    shared            = @()
    additionalDirectories = @()
    # Never committed from a worktree: build and tool artifacts that repos often forget to .gitignore.
    ignore            = @('**/__pycache__/**', '**/*.pyc', '**/.pytest_cache/**', '**/.mypy_cache/**', '**/.venv/**', '**/node_modules/**', '**/.DS_Store')
}

function Get-DefaultSettings { [ordered]@{} + $script:DefaultSettings }

function Resolve-AgentModel {
    param([string]$Provider, [string]$Model)
    if ($Provider -eq 'Copilot') { return $script:CopilotModel }
    return $Model
}

#region Paths, logging, agent discovery

function Get-OrchPaths {
    param([string]$RepoPath = '.', [string]$PlanFile)
    $top = (& git -C $RepoPath rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $top) { throw "Not a git repository: $RepoPath" }
    $repo = [IO.Path]::GetFullPath($top.Trim())
    $runDir = Join-Path $repo '.orchestrator'
    $wtRoot = Join-Path (Split-Path $repo -Parent) ((Split-Path $repo -Leaf) + '.worktrees')
    [pscustomobject]@{
        Repo                = $repo
        RunDir              = $runDir
        PlanFile            = if ($PlanFile) { [IO.Path]::GetFullPath($PlanFile) } else { Join-Path $runDir 'tasks.json' }
        StateFile           = Join-Path $runDir 'state.json'
        StopFile            = Join-Path $runDir 'stop-requested'
        ProgressFile        = Join-Path $runDir 'progress.md'
        ProjectFile         = Join-Path $runDir 'project.json'
        LockFile            = Join-Path $runDir 'run.lock'
        LogDir              = Join-Path $runDir 'logs'
        WorktreeRoot        = $wtRoot
        IntegrationWorktree = Join-Path $wtRoot '_integration'
        # Finished runs: <repo>.runs/<timestamp>/.orchestrator, the same shape as a live run.
        ArchiveRoot         = Join-Path (Split-Path $repo -Parent) ((Split-Path $repo -Leaf) + '.runs')
    }
}

function Initialize-RunDir {
    param($Paths)
    foreach ($d in $Paths.RunDir, $Paths.LogDir, $Paths.WorktreeRoot) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    }
    # Keep run state out of commits without touching the project's .gitignore.
    $commonDir = (& git -C $Paths.Repo rev-parse --git-common-dir).Trim()
    if (-not [IO.Path]::IsPathRooted($commonDir)) { $commonDir = Join-Path $Paths.Repo $commonDir }
    $exclude = Join-Path $commonDir 'info/exclude'
    if (-not (Test-Path (Split-Path $exclude))) { New-Item -ItemType Directory -Path (Split-Path $exclude) | Out-Null }
    if (-not (Test-Path $exclude) -or -not (Select-String -Path $exclude -Pattern '^/\.orchestrator/$' -Quiet)) {
        Add-Content -Path $exclude -Value '/.orchestrator/'
    }
}

function Write-OrchLog {
    param([string]$ProgressFile, [string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    if (-not $ProgressFile) { return }
    # Workers run on several threads; a named mutex keeps lines whole.
    $mutex = [Threading.Mutex]::new($false, 'Local\AgentOrchestratorProgress')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $owned = $true }
        [IO.File]::AppendAllText($ProgressFile, "$line`n")
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Resolve-AgentPath {
    param([ValidateSet('Claude', 'Copilot')][string]$Provider, [string]$AgentPath)
    if ($AgentPath) { return (Resolve-Path $AgentPath).Path }
    $override = [Environment]::GetEnvironmentVariable("ORCH_$($Provider.ToUpperInvariant())")
    if ($override) { return (Resolve-Path $override).Path }
    $commandName = if ($Provider -eq 'Copilot') { 'copilot.exe' } else { 'claude' }
    $cmd = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    if ($Provider -eq 'Copilot') {
        $cmd = Get-Command copilot -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source -notlike '*github.copilot-chat*') { return $cmd.Source }
    }
    # Fall back to the binary bundled with the VS Code extension (newest version first).
    $extRoot = Join-Path $HOME '.vscode/extensions'
    $filter = if ($Provider -eq 'Claude') { 'anthropic.claude-code-*' } else { 'github.copilot-chat-*' }
    $candidates = Get-ChildItem $extRoot -Directory -Filter $filter -ErrorAction SilentlyContinue |
        Sort-Object { try { [version]($_.Name -replace '^.*?-([\d.]+).*$', '$1') } catch { [version]'0.0' } } -Descending
    foreach ($dir in $candidates) {
        $relativePaths = if ($Provider -eq 'Claude') { @('resources/native-binary/claude.exe', 'resources/native-binary/claude') }
                         else { @('dist/copilot.exe', 'resources/copilot.exe', 'resources/app/copilot.exe') }
        foreach ($name in $relativePaths) {
            $p = Join-Path $dir.FullName $name
            if (Test-Path $p) { return $p }
        }
    }
    if ($Provider -eq 'Copilot') {
        $managed = Join-Path $env:APPDATA 'Code/User/globalStorage/github.copilot-chat/copilotCli'
        foreach ($name in 'copilot.exe', 'copilot.bat', 'copilot') {
            $path = Join-Path $managed $name
            if (Test-Path $path) { return $path }
        }
    }
    throw "Could not find $Provider. Put it on PATH, set ORCH_$($Provider.ToUpperInvariant()), or pass -AgentPath."
}

#endregion

#region Plan, graph and state

function Read-Plan {
    param([string]$PlanFile, [string]$Repo)
    if (-not (Test-Path $PlanFile)) { throw "Plan file not found: $PlanFile. Create one with Plan-Tasks.ps1." }
    $raw = Get-Content $PlanFile -Raw
    $schemaErrors = @()
    try {
        $schema = Get-Content (Join-Path $script:SchemaDir 'tasks.schema.json') -Raw
        $null = Test-Json -Json $raw -Schema $schema -ErrorAction Stop
    }
    catch { $schemaErrors += "Schema: $($_.Exception.Message)" }
    $doc = $raw | ConvertFrom-Json -AsHashtable

    $settings = [ordered]@{}
    foreach ($k in $script:DefaultSettings.Keys) { $settings[$k] = $script:DefaultSettings[$k] }
    if ($doc.settings) { foreach ($k in $doc.settings.Keys) { $settings[$k] = $doc.settings[$k] } }
    $settings.additionalDirectories = @($settings.additionalDirectories | ForEach-Object {
        if (-not $_ -or -not $_.Trim()) { $schemaErrors += 'additionalDirectories cannot contain an empty path'; return }
        $directory = if ([IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $Repo $_ }
        $directory = [IO.Path]::GetFullPath($directory)
        if (-not [IO.Directory]::Exists($directory)) { $schemaErrors += "Additional directory not found: $directory" }
        $directory
    })

    $tasks = foreach ($t in @($doc.tasks)) {
        [pscustomobject]@{
            id         = [string]$t.id
            title      = [string]$t.title
            prompt     = [string]$t.prompt
            deps       = @($t.deps | Where-Object { $_ })
            owns       = @($t.owns | Where-Object { $_ })
            acceptance = if ($t.acceptance) { [string]$t.acceptance } else { $null }
            model      = $t.model
        }
    }

    $specText = $null
    if ($doc.spec) {
        $specPath = if ([IO.Path]::IsPathRooted($doc.spec)) { $doc.spec } else { Join-Path $Repo $doc.spec }
        if (Test-Path $specPath) { $specText = Get-Content $specPath -Raw }
        else { $schemaErrors += "Spec file not found: $specPath" }
    }

    [pscustomobject]@{
        Path              = $PlanFile
        Spec              = $doc.spec
        SpecText          = $specText
        BaseBranch        = $doc.baseBranch
        IntegrationBranch = if ($doc.integrationBranch) { $doc.integrationBranch } else { 'orch/integration' }
        Settings          = $settings
        Tasks             = @($tasks)
        LoadErrors        = $schemaErrors
    }
}

function Test-Plan {
    # Returns a list of problems; empty means the graph is runnable.
    param($Plan)
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($e in $Plan.LoadErrors) { $errors.Add($e) }
    $ids = @{}
    foreach ($t in $Plan.Tasks) {
        if ($t.id -notmatch '^[a-z0-9][a-z0-9._-]{0,48}$') { $errors.Add("Invalid id '$($t.id)' (lowercase letters, digits, . _ -)") }
        if ($ids.ContainsKey($t.id)) { $errors.Add("Duplicate id '$($t.id)'") }
        $ids[$t.id] = $t
        if (-not $t.title) { $errors.Add("Task '$($t.id)' has no title") }
        if (-not $t.prompt) { $errors.Add("Task '$($t.id)' has no prompt") }
    }
    foreach ($t in $Plan.Tasks) {
        foreach ($d in $t.deps) {
            if ($d -eq $t.id) { $errors.Add("Task '$($t.id)' depends on itself") }
            elseif (-not $ids.ContainsKey($d)) { $errors.Add("Task '$($t.id)' depends on unknown task '$d'") }
        }
    }
    if ($errors.Count -eq 0) {
        $cycle = Find-Cycle $Plan.Tasks
        if ($cycle) { $errors.Add("Dependency cycle: $($cycle -join ' -> ')") }
    }
    , $errors
}

function Find-Cycle {
    param($Tasks)
    $byId = @{}; foreach ($t in $Tasks) { $byId[$t.id] = $t }
    $color = @{}   # 1 = on the stack, 2 = finished
    $stack = [Collections.Generic.List[string]]::new()
    $visit = $null
    $visit = {
        param($id)
        $color[$id] = 1; $stack.Add($id)
        foreach ($d in $byId[$id].deps) {
            if ($color[$d] -eq 1) { return @($stack[$stack.IndexOf($d)..($stack.Count - 1)]) + $d }
            if (-not $color[$d]) { $c = & $visit $d; if ($c) { return $c } }
        }
        $color[$id] = 2; $stack.RemoveAt($stack.Count - 1)
        return $null
    }
    foreach ($t in $Tasks) {
        if (-not $color[$t.id]) { $c = & $visit $t.id; if ($c) { return $c } }
    }
    $null
}

function Get-Waves {
    # Groups tasks by dependency depth: wave 1 has no deps, wave N depends on wave N-1 at most.
    param($Tasks)
    $depth = @{}
    $remaining = [Collections.Generic.List[object]]::new(); $Tasks | ForEach-Object { $remaining.Add($_) }
    while ($remaining.Count -gt 0) {
        $progress = $false
        foreach ($t in @($remaining)) {
            if (@($t.deps | Where-Object { -not $depth.ContainsKey($_) }).Count -eq 0) {
                $depth[$t.id] = [int](1 + (@($t.deps | ForEach-Object { $depth[$_] }) + 0 | Measure-Object -Maximum).Maximum)
                [void]$remaining.Remove($t); $progress = $true
            }
        }
        if (-not $progress) { throw 'Cannot compute waves: the graph has a cycle.' }
    }
    $depth
}

function Get-DependentCounts {
    # Number of tasks that transitively depend on each task. Used to start critical-path work first.
    param($Tasks)
    $children = @{}; foreach ($t in $Tasks) { $children[$t.id] = @() }
    foreach ($t in $Tasks) { foreach ($d in $t.deps) { if ($children.ContainsKey($d)) { $children[$d] += $t.id } } }
    $counts = @{}
    foreach ($t in $Tasks) {
        $seen = @{}; $queue = [Collections.Generic.Queue[string]]::new(); $queue.Enqueue($t.id)
        while ($queue.Count) { foreach ($c in $children[$queue.Dequeue()]) { if (-not $seen[$c]) { $seen[$c] = $true; $queue.Enqueue($c) } } }
        $counts[$t.id] = $seen.psbase.Count   # psbase: a task called 'count' would hide the property
    }
    $counts
}

function Read-State {
    param($Paths)
    if (Test-Path $Paths.StateFile) { return (Get-Content $Paths.StateFile -Raw | ConvertFrom-Json -AsHashtable) }
    [ordered]@{ tasks = [ordered]@{} }
}

function Save-State {
    param($Paths, $State)
    $tmp = "$($Paths.StateFile).tmp"
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $Paths.StateFile -Force
}

function New-TaskState {
    [ordered]@{
        status = 'pending'; mode = 'fresh'; attempts = 0; syncRuns = 0; costUsd = 0.0
        sessionId = $null; summary = $null; notes = $null; error = $null; feedback = $null; specRejections = 0
        startedAt = $null; finishedAt = $null; mergedSha = $null
    }
}

function Get-TaskDisplayStatus {
    # 'blocked' is derived: pending with a failed task somewhere upstream.
    param($Task, $Plan, $State)
    $s = $State.tasks[$Task.id]
    if (-not $s) { return 'pending' }
    if ($s.status -ne 'pending') { return $s.status }
    $byId = @{}; foreach ($t in $Plan.Tasks) { $byId[$t.id] = $t }
    $queue = [Collections.Generic.Queue[string]]::new(); $Task.deps | ForEach-Object { $queue.Enqueue($_) }
    $seen = @{}
    while ($queue.Count) {
        $d = $queue.Dequeue(); if ($seen[$d]) { continue }; $seen[$d] = $true
        if ($State.tasks[$d] -and $State.tasks[$d].status -eq 'failed') { return 'blocked' }
        $byId[$d].deps | ForEach-Object { $queue.Enqueue($_) }
    }
    'pending'
}

#endregion

#region File ownership

function ConvertTo-GlobRegex {
    param([string]$Glob)
    $g = $Glob.Replace('\', '/').Trim()
    if ($g.StartsWith('./')) { $g = $g.Substring(2) }
    $hasWildcard = $g -match '[*?]'
    if ($g.EndsWith('/')) { $g += '**'; $hasWildcard = $true }
    $sb = [Text.StringBuilder]::new('^')
    for ($i = 0; $i -lt $g.Length; $i++) {
        $c = $g[$i]
        if ($c -eq '*' -and $i + 1 -lt $g.Length -and $g[$i + 1] -eq '*') {
            if ($i + 2 -lt $g.Length -and $g[$i + 2] -eq '/') { [void]$sb.Append('(?:.*/)?'); $i += 2 }
            else { [void]$sb.Append('.*'); $i++ }
        }
        elseif ($c -eq '*') { [void]$sb.Append('[^/]*') }
        elseif ($c -eq '?') { [void]$sb.Append('[^/]') }
        else { [void]$sb.Append([regex]::Escape([string]$c)) }
    }
    # A plain path such as "src/auth" covers the file itself or everything below the folder.
    if (-not $hasWildcard) { [void]$sb.Append('(?:/.*)?') }
    [void]$sb.Append('$')
    $sb.ToString()
}

function Test-PathOwned {
    param([string]$Path, [string[]]$Globs)
    $p = $Path.Replace('\', '/')
    foreach ($g in $Globs) { if ($p -match (ConvertTo-GlobRegex $g)) { return $true } }
    $false
}

function Get-GlobPrefix {
    param([string]$Glob)
    $g = $Glob.Replace('\', '/').Trim().ToLowerInvariant()
    if ($g.StartsWith('./')) { $g = $g.Substring(2) }
    $i = $g.IndexOfAny([char[]]'*?[')
    if ($i -ge 0) { $g = $g.Substring(0, $i) }
    $g
}

function Test-OwnsOverlap {
    # Conservative: two globs overlap when one literal prefix starts with the other.
    # Empty owns means "the whole repo", which overlaps everything.
    param([string[]]$A, [string[]]$B)
    if (-not $A -or -not $B -or $A.Count -eq 0 -or $B.Count -eq 0) { return $true }
    foreach ($x in $A) {
        foreach ($y in $B) {
            $px = Get-GlobPrefix $x; $py = Get-GlobPrefix $y
            if ($px.StartsWith($py) -or $py.StartsWith($px)) { return $true }
        }
    }
    $false
}

#endregion

#region git and shell helpers

function Use-Utf8Output {
    # git, claude and copilot write UTF-8, but PowerShell decodes a native command's output with
    # [Console]::OutputEncoding, the OEM code page unless set (437 on an English Windows): ↳, › and …
    # came back as Γå│, ΓÇ║ and ΓÇª. The setting is process-wide and read when a native command starts,
    # so it is set and never restored: the thread jobs of a run share it, and a restore in one could
    # land between another's set and its start.
    if ([Console]::OutputEncoding.CodePage -ne 65001) {
        try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
    }
}

function Invoke-Git {
    param([string]$Dir, [string[]]$Arguments)
    Use-Utf8Output
    $out = & git -c core.quotepath=false -C $Dir @Arguments 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Exit = $LASTEXITCODE; Output = ($out -join "`n").Trim() }
}

function Test-GitBranch {
    param([string]$Dir, [string]$Branch)
    (Invoke-Git $Dir @('rev-parse', '--verify', '--quiet', "refs/heads/$Branch")).Exit -eq 0
}

function Initialize-Integration {
    # Creates the integration branch (from the base branch) and a worktree that holds it.
    param($Paths, $Plan)
    $repo = $Paths.Repo
    $base = $Plan.BaseBranch
    if (-not $base) { $base = (Invoke-Git $repo @('rev-parse', '--abbrev-ref', 'HEAD')).Output }
    if (-not (Test-GitBranch $repo $Plan.IntegrationBranch)) {
        $r = Invoke-Git $repo @('branch', $Plan.IntegrationBranch, $base)
        if ($r.Exit -ne 0) { throw "Could not create $($Plan.IntegrationBranch) from ${base}: $($r.Output)" }
    }
    $wt = $Paths.IntegrationWorktree
    if (-not (Test-Path $wt)) {
        [void](Invoke-Git $repo @('worktree', 'prune'))
        $r = Invoke-Git $repo @('worktree', 'add', $wt, $Plan.IntegrationBranch)
        if ($r.Exit -ne 0) { throw "Could not create the integration worktree: $($r.Output)" }
    }
    $dirty = (Invoke-Git $wt @('status', '--porcelain')).Output
    if ($dirty) { throw "The integration worktree $wt has uncommitted changes. Commit or discard them first." }
}

function New-TaskWorktree {
    param($Paths, [string]$Id, [string]$FromBranch)
    $repo = $Paths.Repo
    $wt = Join-Path $Paths.WorktreeRoot $Id
    $branch = "orch/task/$Id"
    if (Test-Path $wt) {
        if ((Invoke-Git $wt @('status', '--porcelain')).Output) {
            throw "Cannot recreate $($Id): worktree $wt has uncommitted changes. Preserve them before retrying."
        }
        [void](Invoke-Git $repo @('worktree', 'remove', '--force', $wt))
        if (Test-Path $wt) { Remove-Item -Recurse -Force $wt }
    }
    [void](Invoke-Git $repo @('worktree', 'prune'))
    if (Test-GitBranch $repo $branch) { [void](Invoke-Git $repo @('branch', '-D', $branch)) }
    $r = Invoke-Git $repo @('worktree', 'add', '-b', $branch, $wt, $FromBranch)
    if ($r.Exit -ne 0) { throw "git worktree add failed for ${Id}: $($r.Output)" }
    [pscustomobject]@{ Path = $wt; Branch = $branch }
}

function Invoke-ShellCommand {
    # Runs a command with pwsh in a directory, with a timeout. Output goes to a log file.
    param([string]$WorkDir, [string]$Command, [string]$LogPath, [int]$TimeoutSec = 1800)
    $pwsh = Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    $errPath = "$LogPath.stderr"
    $p = Start-Process -FilePath $pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded `
        -WorkingDirectory $WorkDir -NoNewWindow -PassThru -RedirectStandardOutput $LogPath -RedirectStandardError $errPath
    $null = $p.Handle   # keeps ExitCode readable after exit
    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) { try { $p.Kill($true) } catch { } ; $exit = -1 }
    else { $p.WaitForExit(); $exit = $p.ExitCode }
    $text = ((Get-Content $LogPath -Raw -ErrorAction SilentlyContinue) + (Get-Content $errPath -Raw -ErrorAction SilentlyContinue))
    if ($null -eq $text) { $text = '' }
    $tail = (($text -split "`r?`n") | Select-Object -Last 80) -join "`n"
    if ($timedOut) { $tail = "Timed out after $TimeoutSec s.`n$tail" }
    [pscustomobject]@{ Ok = (-not $timedOut -and $exit -eq 0); Exit = $exit; Tail = $tail.Trim() }
}

#endregion

#region Finishing a run

function Open-RunLock {
    # Opens run.lock the way Invoke-Orchestrator.ps1 holds it for a whole run, so this fails while a
    # run is active. Returns the open stream (dispose it when done), or nothing without a lock file.
    param($Paths)
    if (-not (Test-Path $Paths.LockFile)) { return }
    try { [IO.File]::Open($Paths.LockFile, 'Open', 'ReadWrite', 'None') }
    catch [IO.IOException] { throw "An orchestrator run is active for $($Paths.Repo). Let it end, or stop it with Request-OrchestratorStop.ps1, then try again." }
}

function Get-RunWorktrees {
    # The registered worktrees under <repo>.worktrees.
    param($Paths)
    $prefix = $Paths.WorktreeRoot + [IO.Path]::DirectorySeparatorChar
    @((Invoke-Git $Paths.Repo @('worktree', 'list', '--porcelain')).Output -split "`n" | Where-Object { $_ -like 'worktree *' } |
        ForEach-Object { [IO.Path]::GetFullPath($_.Substring(9)) } | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
}

function Get-RunProblems {
    # Returns the reasons the run in .orchestrator is not finished; empty means finished: every task
    # in the plan is done, the integration branch is gone or has no commit the base branch lacks, and
    # no worktree holds uncommitted changes.
    param($Paths)
    $problems = [Collections.Generic.List[string]]::new()
    $doc = $null
    if (Test-Path $Paths.PlanFile) { try { $doc = Get-Content $Paths.PlanFile -Raw | ConvertFrom-Json -AsHashtable } catch { } }
    if (-not $doc) { $problems.Add("there is no readable plan at $($Paths.PlanFile) to check it against"); return , $problems }
    $done = (Read-State $Paths).tasks ?? @{}
    $open = @($doc.tasks | Where-Object { $done[[string]$_.id].status -ne 'done' } | ForEach-Object { $_.id })
    if ($open.Count) {
        $names = (($open | Select-Object -First 5) -join ', ') + $(if ($open.Count -gt 5) { ', ...' })
        $problems.Add("$($open.Count) of $(@($doc.tasks).Count) tasks are not done ($names)")
    }
    $int = if ($doc.integrationBranch) { $doc.integrationBranch } else { 'orch/integration' }
    if (Test-GitBranch $Paths.Repo $int) {
        $base = if ($doc.baseBranch) { $doc.baseBranch } else { (Invoke-Git $Paths.Repo @('rev-parse', '--abbrev-ref', 'HEAD')).Output }
        $ahead = Invoke-Git $Paths.Repo @('rev-list', '--count', "$base..$int")
        if ($ahead.Exit -ne 0) { $problems.Add("$int cannot be compared with $base") }
        elseif ([int]$ahead.Output -gt 0) { $problems.Add("$int has $($ahead.Output) commit(s) that $base lacks") }
    }
    # Removing a worktree deletes what is not committed. Count what a worker commit would pick up:
    # changed and new files, minus git-ignored ones and the plan's ignore globs.
    $ignore = if ($null -ne $doc.settings.ignore) { @($doc.settings.ignore) } else { $script:DefaultSettings.ignore }
    $pathspec = @('--', '.') + @($ignore | Where-Object { $_ } | ForEach-Object { ":(exclude,glob)$_" })
    foreach ($wt in Get-RunWorktrees $Paths) {
        if (-not (Test-Path $wt)) { continue }
        $changed = @((Invoke-Git $wt (@('status', '--porcelain') + $pathspec)).Output -split "`n" | Where-Object { $_ })
        if ($changed.Count) {
            $names = (($changed | Select-Object -First 3 | ForEach-Object { $_.Substring(3) }) -join ', ') + $(if ($changed.Count -gt 3) { ', ...' })
            $problems.Add("the worktree $wt has uncommitted changes that would be deleted ($names)")
        }
    }
    , $problems
}

function Complete-Run {
    # Finishes the run in .orchestrator: removes the worktrees under <repo>.worktrees and the orch/*
    # branches, then moves the run record to <repo>.runs/<timestamp>/.orchestrator. project.json stays
    # (the archive gets a copy), and so does every -Keep path (absolute, or relative to .orchestrator).
    # Refuses an active run, and an unfinished one unless -Force. Returns the archive folder, or
    # nothing when there was nothing to archive.
    [CmdletBinding(SupportsShouldProcess)]
    param($Paths, [string[]]$Keep, [switch]$Force)
    $ErrorActionPreference = 'Stop'   # a module function does not inherit the calling script's preference
    if (-not (Test-Path $Paths.RunDir)) { Write-Host "Nothing to archive in $($Paths.RunDir)."; return }
    $repo = $Paths.Repo
    $sep = [IO.Path]::DirectorySeparatorChar
    $stay = @($Paths.ProjectFile) + @($Keep | Where-Object { $_ } | ForEach-Object {
            $p = [IO.Path]::GetFullPath($_, $Paths.RunDir)
            if (-not $p.StartsWith("$($Paths.RunDir)$sep", [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $p)) {
                throw "Cannot keep '$_': there is no such file in $($Paths.RunDir)."
            }
            $p
        })
    # Everything else moves. A folder that holds a kept file is walked instead of moved whole.
    $moves = [Collections.Generic.List[IO.FileSystemInfo]]::new()
    $walk = $null
    $walk = {
        param($dir)
        foreach ($e in Get-ChildItem -LiteralPath $dir -Force) {
            if ($stay -contains $e.FullName) { continue }
            if ($e.PSIsContainer -and ($stay | Where-Object { $_.StartsWith("$($e.FullName)$sep", [StringComparison]::OrdinalIgnoreCase) })) { & $walk $e.FullName }
            else { $moves.Add($e) }
        }
    }
    & $walk $Paths.RunDir
    if ($moves.Count -eq 0) { Write-Host "Nothing to archive in $($Paths.RunDir)."; return }

    $lock = Open-RunLock $Paths   # held until the end, so no run can start meanwhile
    try {
        $problems = Get-RunProblems $Paths
        if ($problems.Count) {
            $what = "The run in $($Paths.RunDir) is not finished: $($problems -join '; ')."
            if (-not $Force) { throw "$what Finish it (rerun Invoke-Orchestrator.ps1, merge the integration branch into the base branch, commit or discard changes in the worktrees), or use -Force to archive it as it is." }
            Write-Warning "$what Archiving it as it is (-Force)."
        }

        $worktrees = Get-RunWorktrees $Paths
        $wt = $null
        foreach ($line in (Invoke-Git $repo @('worktree', 'list', '--porcelain')).Output -split "`n") {
            if ($line -like 'worktree *') { $wt = [IO.Path]::GetFullPath($line.Substring(9)) }
            elseif ($line -like 'branch refs/heads/orch/*' -and $worktrees -notcontains $wt) {
                throw "Branch $($line.Substring(18)) is checked out in $wt, so it cannot be removed. Switch that checkout to another branch, then try again."
            }
        }
        foreach ($w in $worktrees) {
            if (-not $PSCmdlet.ShouldProcess($w, 'git worktree remove')) { continue }
            [void](Invoke-Git $repo @('worktree', 'remove', '--force', $w))
            if (Test-Path $w) { Remove-Item -Recurse -Force $w }
        }
        if (-not $WhatIfPreference) { [void](Invoke-Git $repo @('worktree', 'prune')) }

        $archive = Join-Path $Paths.ArchiveRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
        if (Test-Path $archive) { Start-Sleep -Seconds 1; $archive = Join-Path $Paths.ArchiveRoot (Get-Date -Format 'yyyyMMdd-HHmmss') }
        $dest = Join-Path $archive '.orchestrator'
        # The branch tips go into the archive first, so a removed branch can be recreated from its commit.
        $branches = @((Invoke-Git $repo @('for-each-ref', '--format=%(objectname) %(refname:short)', 'refs/heads/orch/')).Output -split "`n" | Where-Object { $_ })
        if (-not $WhatIfPreference) {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            if ($branches) { Set-Content -Path (Join-Path $dest 'branches.txt') -Value $branches -Encoding utf8 }
        }
        foreach ($b in $branches) {
            $name = $b.Substring($b.IndexOf(' ') + 1)
            if (-not $PSCmdlet.ShouldProcess($name, 'git branch -D')) { continue }
            $r = Invoke-Git $repo @('branch', '-D', $name)
            if ($r.Exit -ne 0) { throw "Could not delete branch ${name}: $($r.Output)" }
        }

        # Folders first: one that is in use fails before anything else has moved. run.lock goes last, once released.
        foreach ($e in @($moves | Sort-Object { $_.FullName -eq $Paths.LockFile }, { -not $_.PSIsContainer })) {
            if (-not $PSCmdlet.ShouldProcess($e.FullName, "Move to $dest")) { continue }
            if ($lock -and $e.FullName -eq $Paths.LockFile) { $lock.Dispose(); $lock = $null }
            $target = Join-Path $dest ([IO.Path]::GetRelativePath($Paths.RunDir, $e.FullName))
            New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
            Move-Item -LiteralPath $e.FullName -Destination $target
        }
        if ((Test-Path $Paths.ProjectFile) -and $PSCmdlet.ShouldProcess($Paths.ProjectFile, "Copy to $dest")) {
            Copy-Item -LiteralPath $Paths.ProjectFile -Destination $dest
        }
        if ((Test-Path $Paths.WorktreeRoot) -and -not (Get-ChildItem $Paths.WorktreeRoot -Force)) { Remove-Item $Paths.WorktreeRoot }
    }
    finally {
        if ($lock) { $lock.Dispose() }
    }
    if (-not $WhatIfPreference) { $archive }
}

#endregion

#region agent CLI

function Get-CompactSchema {
    param([string]$Name)
    Get-Content (Join-Path $script:SchemaDir $Name) -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 50 -Compress
}

function Format-Template {
    param([string]$Name, [hashtable]$Values)
    $text = Get-Content (Join-Path $script:PromptDir $Name) -Raw
    foreach ($k in $Values.Keys) { $text = $text.Replace("{{$k}}", [string]$Values[$k]) }
    $text
}

function Format-SubAgents {
    # The {{SUBAGENTS}} section of the worker and planner prompts. The providers name the tool and
    # its foreground setting differently, and only a worker's sub-agents could edit files.
    param([ValidateSet('Claude', 'Copilot')][string]$Provider, [ValidateSet('worker', 'planner')][string]$Role)
    $copilot = $Provider -eq 'Copilot'
    Format-Template 'subagents.md' @{
        TOOL       = $copilot ? 'the `task` tool' : 'the Agent tool'
        FOREGROUND = $copilot ? '`mode: "sync"`' : '`run_in_background: false`'
        EDITS      = $Role -eq 'worker' ? "Sub-agents investigate; make all code changes yourself. They share your worktree, so tell each one not to edit files.`n`n" : ''
    }
}

function Format-ToolUse {
    # One short line describing a tool call from the event stream, e.g. "Read src/app.cs".
    param([Collections.IDictionary]$Block, [string]$WorkDir)
    $in = $Block.input ?? @{}
    $rel = {
        param($p)
        if ("$p" -match '^/([a-zA-Z])/(.*)$') { $p = "$($Matches[1].ToUpper()):/$($Matches[2])" }   # Git Bash style
        if ($p -and $WorkDir -and [IO.Path]::IsPathRooted($p)) {
            $r = [IO.Path]::GetRelativePath($WorkDir, $p)
            if (-not $r.StartsWith('..')) { $p = $r }
        }
        "$p".Replace('\', '/')
    }
    $detail = switch -Regex ($Block.name) {
        '^(Read|Edit|Write|MultiEdit|NotebookEdit)$' { & $rel $in.file_path; break }
        '^Glob$' { $in.pattern; break }
        '^Grep$' { "$($in.pattern)$(if ($in.path) { " in $(& $rel $in.path)" })"; break }
        '^(Bash|PowerShell)$' { ("$($in.command)" -split "`n")[0]; break }
        '^StructuredOutput$' { 'reporting the result'; break }
        '^(Task|Agent)$' { $in.description; break }
        default { '' }
    }
    $detail = "$detail".Trim()
    if ($detail.Length -gt 100) { $detail = $detail.Substring(0, 97) + '...' }
    if ($detail) { "$($Block.name) $detail" } else { $Block.name }
}

function Get-SubAgentName {
    # The short name of the sub-agent an event came from, or nothing for the agent's own events.
    # Pass every event of one stream in order, with one $Names table per stream: it learns each
    # sub-agent's description from the event that starts it.
    # Claude: a sub-agent's events carry parent_tool_use_id, the id of the Task (Agent) call.
    # Copilot: subagent.started names the agentId that the sub-agent's events carry.
    param([Collections.IDictionary]$Event, [Collections.IDictionary]$Names)
    if ($Event.type -eq 'subagent.started') { $Names[$Event.agentId] = $Event.data.agentDescription }
    elseif ($Event.type -eq 'assistant') {
        foreach ($b in @($Event.message.content)) {
            if ($b -is [Collections.IDictionary] -and $b.type -eq 'tool_use' -and $b.name -match '^(Task|Agent)$') { $Names[$b.id] = $b.input.description }
        }
    }
    $key = if ($Event.parent_tool_use_id) { $Event.parent_tool_use_id } else { $Event.agentId }
    if ($key) { Format-SubAgentName ($Names[$key] ?? $Event.task_description) }
}

function Format-SubAgentName {
    # A sub-agent's description, cut to 32 characters so the lines that carry it still fit the views.
    param([string]$Description)
    $name = ($Description -replace '\s+', ' ').Trim()
    if (-not $name) { return 'sub-agent' }
    if ($name.Length -le 32) { return $name }
    $cut = $name.LastIndexOf(' ', 31)
    if ($cut -lt 20) { $cut = 31 }   # end at a word, unless that drops too much
    $name.Substring(0, $cut).TrimEnd() + '…'
}

function Invoke-Agent {
    # One non-interactive claude call. The prompt goes in on stdin. Output is read as a stream of JSON
    # events (kept in <LogPath>.events.jsonl); the final result event is logged and parsed.
    # Activity: 'each' logs every tool call, 'heartbeat' logs a summary at most once a minute.
    # -SubAgents adds the sub-agent tool (Task) to the tool lists that are given.
    param(
        [ValidateSet('Claude', 'Copilot')][string]$Provider = 'Claude', [string]$AgentPath, [string]$WorkDir, [string]$Prompt, [string]$Schema,
        [string]$Model, [string]$Effort, [string]$PermissionMode, [string[]]$AllowedTools, [string[]]$Tools, [switch]$SubAgents,
        [double]$MaxBudgetUsd, [string]$ResumeSessionId, [string]$Name, [string]$LogPath, [string[]]$AdditionalDirectories,
        [string]$ProgressFile, [string]$StopFile, [string]$ActivityLabel, [ValidateSet('none', 'each', 'heartbeat')][string]$Activity = 'none'
    )
    $Model = Resolve-AgentModel -Provider $Provider -Model $Model
    if ($SubAgents) {
        # Only a list that is given: an empty one sets no filter, so the tool is there already.
        if ($AllowedTools -and $AllowedTools -notcontains 'Task') { $AllowedTools += 'Task' }
        if ($Tools -and $Tools -notcontains 'Task') { $Tools += 'Task' }
    }
    $cliArgs = [Collections.Generic.List[string]]::new()
    foreach ($directory in $AdditionalDirectories) { $cliArgs.AddRange([string[]]@('--add-dir', $directory)) }
    if ($Provider -eq 'Claude') {
        $cliArgs.AddRange([string[]]@('-p', '--output-format', 'stream-json', '--verbose', '--permission-prompts', 'none'))
        # Auto memory lives outside the repo on one machine; agents must not read or write it.
        $cliArgs.AddRange([string[]]@('--settings', '{"autoMemoryEnabled":false}'))
        $cliArgs.AddRange([string[]]@('--disallowedTools', ($script:ClaudeDeniedMcpServers -join ',')))
        if ($Schema) { $cliArgs.AddRange([string[]]@('--json-schema', (Get-CompactSchema $Schema))) }
        if ($Model) { $cliArgs.AddRange([string[]]@('--model', $Model)) }
        if ($Effort) { $cliArgs.AddRange([string[]]@('--effort', $Effort)) }
        if ($PermissionMode) { $cliArgs.AddRange([string[]]@('--permission-mode', $PermissionMode)) }
        if ($AllowedTools) { $cliArgs.AddRange([string[]]@('--allowedTools', ($AllowedTools -join ','))) }
        if ($Tools) { $cliArgs.AddRange([string[]]@('--tools', ($Tools -join ','))) }
        if ($MaxBudgetUsd -gt 0) { $cliArgs.AddRange([string[]]@('--max-budget-usd', [string]$MaxBudgetUsd)) }
        if ($ResumeSessionId) { $cliArgs.AddRange([string[]]@('--resume', $ResumeSessionId)) }
        if ($Name) { $cliArgs.AddRange([string[]]@('--name', $Name)) }
    }
    else {
        if ($Schema) {
            $Prompt += "`n`nReturn ONLY a JSON object matching this schema (no Markdown fence or explanation):`n$(Get-CompactSchema $Schema)"
        }
        $cliArgs.AddRange([string[]]@('--output-format', 'json', '--allow-all-tools'))
        $cliArgs.AddRange([string[]]@('--model', $Model))
        if ($Effort -in 'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max') { $cliArgs.AddRange([string[]]@('--reasoning-effort', $Effort)) }
        $requested = if ($Tools) { $Tools } else { $AllowedTools }
        if ($requested) {
            $available = foreach ($tool in $requested) {
                switch -Regex ($tool) {
                    '^Read$' { 'view'; break }
                    '^Glob$' { 'glob'; break }
                    '^Grep$' { 'rg'; break }
                    '^(Edit|Write)$' { 'apply_patch'; break }
                    # A command that outlives its wait moves to the background; the other three read and stop it.
                    '^(Bash|PowerShell)$' { 'powershell', 'read_powershell', 'stop_powershell', 'list_powershell'; break }
                    # Start a sub-agent, read a background one's result, list them. No write_agent (follow-ups).
                    '^Task$' { 'task', 'read_agent', 'list_agents'; break }
                    default { throw "Copilot cannot enforce tool rule '$tool'. Use whole-tool names in allowedTools." }
                }
            }
            $cliArgs.Add("--available-tools=$(($available | Select-Object -Unique) -join ',')")
        }
        if ($ResumeSessionId) { $cliArgs.AddRange([string[]]@('--resume', $ResumeSessionId)) }
        if ($Name -and -not $ResumeSessionId) { $cliArgs.AddRange([string[]]@('--name', $Name)) }
    }

    if ($LogPath) { Set-Content -Path "$LogPath.prompt.md" -Value $Prompt -Encoding utf8 }
    $errPath = if ($LogPath) { "$LogPath.stderr" } else { [IO.Path]::GetTempFileName() }
    $events = if ($LogPath) { [IO.StreamWriter]::new("$LogPath.events.jsonl", $false, [Text.UTF8Encoding]::new($false)) }
    $label = if ($ActivityLabel) { "$ActivityLabel " } else { '' }
    $act = @{ Calls = 0; Last = $null; Reported = 0; Next = (Get-Date).AddSeconds($script:HeartbeatSeconds) }
    $subAgentNames = @{}
    $parsed = $null
    $copilotText = $null
    $other = [Collections.Generic.List[string]]::new()
    Push-Location $WorkDir
    try {
        Use-Utf8Output
        $Prompt | & $AgentPath @cliArgs 2> $errPath | ForEach-Object {
            $line = "$_"
            if ($events) { $events.WriteLine($line); $events.Flush() }
            $ev = $null
            if ($line.TrimStart().StartsWith('{')) { try { $ev = $line | ConvertFrom-Json -AsHashtable } catch { } }
            if (-not $ev) { if ($line.Trim()) { $other.Add($line) }; return }
            # A session that waits for background sub-agents sends a result after each turn; the last one counts.
            if ($ev.type -eq 'result') { $parsed = $ev; return }
            $sub = if ($Activity -ne 'none') { Get-SubAgentName $ev $subAgentNames }
            $tag = if ($sub) { "↳ [$sub] " } else { '' }
            if ($Provider -eq 'Copilot') {
                # A sub-agent's answer carries its agentId; only the agent's own answer is the result.
                if ($ev.type -eq 'assistant.message' -and $ev.data.phase -eq 'final_answer' -and -not $ev.agentId) { $copilotText = $ev.data.content }
                if ($ev.type -eq 'tool.execution_start' -and $Activity -ne 'none') {
                    $act.Calls++; $act.Last = "${tag}tool: $($ev.data.toolName)$(if ($ev.data.toolName -eq 'task') { " $($ev.data.arguments.description)" })"
                    if ($Activity -eq 'each') { Write-OrchLog $ProgressFile "$label$($act.Last)" }
                }
            }
            elseif ($ev.type -eq 'assistant' -and $Activity -ne 'none') {
                foreach ($block in @($ev.message.content)) {
                    if ($block -isnot [Collections.IDictionary] -or $block.type -ne 'tool_use') { continue }
                    $act.Calls++
                    $act.Last = $tag + (Format-ToolUse $block $WorkDir)
                    if ($Activity -eq 'each') { Write-OrchLog $ProgressFile "$label$($act.Last)" }
                }
            }
            if ($Activity -eq 'heartbeat' -and $act.Calls -gt $act.Reported -and (Get-Date) -ge $act.Next) {
                Write-OrchLog $ProgressFile "$label$($act.Calls) tool calls, last: $($act.Last)"
                $act.Reported = $act.Calls
                $act.Next = (Get-Date).AddSeconds($script:HeartbeatSeconds)
            }
        }
        $exit = $LASTEXITCODE
    }
    finally {
        Pop-Location
        if ($events) { $events.Dispose() }
    }
    $text = if ($parsed) { $parsed | ConvertTo-Json -Depth 50 } else { ($other -join "`n").Trim() }
    if ($LogPath) { Set-Content -Path $LogPath -Value $text -Encoding utf8 }
    $stderrTail = ((Get-Content $errPath -ErrorAction SilentlyContinue) | Select-Object -Last 20) -join "`n"
    $finished = $exit -eq 0 -and $parsed -and $(if ($Provider -eq 'Copilot') { $parsed.exitCode -eq 0 } else { -not $parsed.is_error })
    $structured = $parsed.structured_output
    $schemaError = $null
    if ($Provider -eq 'Copilot' -and $Schema -and $copilotText) {
        $jsonText = $copilotText.Trim() -replace '^```(?:json)?\s*', '' -replace '\s*```$', ''
        try {
            if (Test-Json -Json $jsonText -Schema (Get-CompactSchema $Schema) -ErrorAction Stop) {
                $structured = $jsonText | ConvertFrom-Json -AsHashtable
            }
        } catch { $schemaError = $_.Exception.Message }
    }
    $ok = $finished -and (-not $Schema -or $structured)
    $err = $null
    if (-not $ok) {
        $err = if ($finished) { "the run finished without a valid structured result: $schemaError $copilotText" }
               elseif ($parsed -and $parsed.result) { "$($parsed.subtype): $($parsed.result)" }
               elseif ($parsed -and $parsed.subtype) { "$Provider ended with $($parsed.subtype)" }
               else { "$Provider exited with $exit. $stderrTail" }
    }
    $r = [pscustomobject]@{
        Ok         = [bool]$ok
        Finished   = [bool]$finished
        Exit       = $exit
        SessionId  = $parsed ? $(if ($Provider -eq 'Copilot') { $parsed.sessionId } else { $parsed.session_id }) : $null
        Cost       = [double]($parsed ? ($parsed.total_cost_usd ?? 0) : 0)
        Structured = $structured
        Text       = if ($Provider -eq 'Copilot') { $copilotText } elseif ($parsed) { $parsed.result } else { $text }
        Error      = $err
    }

    # Models sometimes finish the work but skip (or only claim) the structured result.
    # Resume the same session once and ask for just the result.
    if ($Schema -and $finished -and -not $ok -and $r.SessionId -and -not $script:InNudge -and
        (-not $StopFile -or -not (Test-Path $StopFile))) {
        $script:InNudge = $true
        try {
            $nudge = Invoke-Agent -Provider $Provider -AgentPath $AgentPath -WorkDir $WorkDir -Schema $Schema -Model $Model -Effort $Effort `
                -PermissionMode $PermissionMode -AllowedTools $AllowedTools -Tools $Tools -SubAgents:$SubAgents -MaxBudgetUsd $MaxBudgetUsd -AdditionalDirectories $AdditionalDirectories `
                -ResumeSessionId $r.SessionId -Name $Name -LogPath ($LogPath ? "$LogPath.nudge.json" : $null) `
                -ProgressFile $ProgressFile -StopFile $StopFile -ActivityLabel $ActivityLabel -Activity $Activity `
                -Prompt $(if ($Provider -eq 'Claude') { 'Your work is finished. Do not do any more work. Report your result now by calling the StructuredOutput tool with the required fields.' } else { "Your work is finished. Do not do any more work. Your previous JSON did not match the schema: $schemaError. Return the corrected JSON object now." })
        }
        finally { $script:InNudge = $false }
        $nudge.Cost += $r.Cost
        if (-not $nudge.Ok -and -not $nudge.Text) { $nudge.Text = $r.Text }
        return $nudge
    }
    $r
}

#endregion

#region Task pipeline (runs on a worker thread)

function Format-Owns {
    param([string[]]$Owns, [string[]]$Shared)
    $lines = @(if ($Owns -and $Owns.Count) { $Owns | ForEach-Object { "- ``$_``" } } else { '- Any file in the repository.' })
    if ($Shared -and $Shared.Count) {
        $quoted = ($Shared | ForEach-Object { '`' + $_ + '`' }) -join ', '
        $lines += "- Shared files any task may edit: $quoted"
    }
    $lines -join "`n"
}

function Get-TaskChanges {
    # Files this task changed relative to the integration branch (merge-base diff).
    param([string]$Worktree, [string]$IntegrationBranch)
    $r = Invoke-Git $Worktree @('diff', '--name-only', "$IntegrationBranch...HEAD")
    @($r.Output -split "`n" | Where-Object { $_ })
}

function Save-WorkerChanges {
    param([string]$Worktree, [string]$Message, [string[]]$Ignore)
    $pathspec = @('--', '.') + @($Ignore | Where-Object { $_ } | ForEach-Object { ":(exclude,glob)$_" })
    [void](Invoke-Git $Worktree (@('add', '-A') + $pathspec))
    $staged = Invoke-Git $Worktree @('diff', '--cached', '--quiet')
    if ($staged.Exit -eq 0) { return $null }   # nothing new
    $c = Invoke-Git $Worktree @('commit', '-q', '-m', $Message)
    if ($c.Exit -ne 0) { return "git commit failed:`n$($c.Output)" }
    $null
}

function Sync-WithIntegration {
    # Merges the integration branch into the task branch; asks a resolver agent to fix conflicts.
    param([hashtable]$Ctx, [int]$Attempt, [ref]$Cost)
    $wt = $Ctx.Worktree
    $isAncestor = (Invoke-Git $wt @('merge-base', '--is-ancestor', $Ctx.IntegrationBranch, 'HEAD')).Exit -eq 0
    if ($isAncestor) { return $null }
    $m = Invoke-Git $wt @('merge', '--no-edit', $Ctx.IntegrationBranch)
    if ($m.Exit -eq 0) { return $null }
    $conflicts = (Invoke-Git $wt @('diff', '--name-only', '--diff-filter=U')).Output
    if (-not $conflicts) {
        [void](Invoke-Git $wt @('merge', '--abort'))
        return "Merging $($Ctx.IntegrationBranch) failed:`n$($m.Output)"
    }
    if ($Ctx.StopFile -and (Test-Path $Ctx.StopFile)) {
        [void](Invoke-Git $wt @('merge', '--abort'))
        return 'Integration sync deferred for graceful stop.'
    }
    Write-OrchLog $Ctx.ProgressFile "[$($Ctx.Id)] merge conflicts with $($Ctx.IntegrationBranch); starting resolver"
    $prompt = Format-Template 'resolver.md' @{
        BRANCH = $Ctx.Branch; TASK_ID = $Ctx.Id; TITLE = $Ctx.Title; INTEGRATION = $Ctx.IntegrationBranch
        FILES = (($conflicts -split "`n") | ForEach-Object { "- $_" }) -join "`n"; PROMPT = $Ctx.Prompt
    }
    $resolverTools = if ($Ctx.Provider -eq 'Copilot') { @($Ctx.AllowedTools) + @('Bash') }
                     else { @($Ctx.AllowedTools) + @('Bash(git add *)', 'Bash(git status *)', 'Bash(git diff *)') }
    $r = Invoke-Agent -Provider $Ctx.Provider -AgentPath $Ctx.AgentPath -WorkDir $wt -Prompt $prompt -Model $Ctx.ReviewModel `
        -PermissionMode 'acceptEdits' -AllowedTools $resolverTools -AdditionalDirectories $Ctx.AdditionalDirectories `
        -MaxBudgetUsd $Ctx.MaxBudgetUsd -Name "orch:$($Ctx.Id):resolve" -LogPath (Join-Path $Ctx.LogDir "attempt-$Attempt-resolver.json") `
        -ProgressFile $Ctx.ProgressFile -StopFile $Ctx.StopFile -ActivityLabel "[$($Ctx.Id)] resolver:" -Activity 'heartbeat'
    $Cost.Value += $r.Cost
    [void](Invoke-Git $wt @('add', '-A'))
    $left = (Invoke-Git $wt @('diff', '--name-only', '--diff-filter=U')).Output
    $markers = (Invoke-Git $wt @('grep', '-l', '-E', '^(<<<<<<<|>>>>>>>) ', '--', '.')).Output
    if ($left -or $markers) {
        [void](Invoke-Git $wt @('merge', '--abort'))
        return "Merging $($Ctx.IntegrationBranch) into your branch gave conflicts the resolver could not fix in: $($conflicts -replace "`n", ', '). Rework your change so it fits the code now on $($Ctx.IntegrationBranch)."
    }
    $c = Invoke-Git $wt @('commit', '-q', '--no-edit')
    if ($c.Exit -ne 0) { [void](Invoke-Git $wt @('merge', '--abort')); return "Committing the conflict resolution failed:`n$($c.Output)" }
    $null
}

function Invoke-Review {
    param([hashtable]$Ctx, [int]$Attempt, [ref]$Cost)
    $wt = $Ctx.Worktree
    $range = "$($Ctx.IntegrationBranch)...HEAD"
    $diff = (Invoke-Git $wt @('diff', $range)).Output
    $limit = 80000
    if ($diff.Length -gt $limit) { $diff = $diff.Substring(0, $limit) + "`n... (diff truncated; read the files for the rest)" }
    $prompt = Format-Template 'reviewer.md' @{
        TASK_ID = $Ctx.Id; TITLE = $Ctx.Title; PROMPT = $Ctx.Prompt; OWNS = (Format-Owns $Ctx.Owns $Ctx.Shared)
        ADDITIONAL_DIRECTORIES = $(if ($Ctx.AdditionalDirectories.Count) { ($Ctx.AdditionalDirectories | ForEach-Object { "- ``$_``" }) -join "`n" } else { '(none)' })
        SPEC = ($Ctx.SpecText ?? '(no spec file)'); BASE = $Ctx.IntegrationBranch
        DIFF_STAT = (Invoke-Git $wt @('diff', '--stat', $range)).Output; DIFF = $diff
    }
    for ($try = 1; $try -le 2; $try++) {
        if ($Ctx.StopFile -and (Test-Path $Ctx.StopFile)) { return @{ paused = $true } }
        $r = Invoke-Agent -Provider $Ctx.Provider -AgentPath $Ctx.AgentPath -WorkDir $wt -Prompt $prompt -Schema 'review-result.schema.json' `
            -Model $Ctx.ReviewModel -PermissionMode 'dontAsk' -Tools @('Read', 'Glob', 'Grep') -AllowedTools @('Read', 'Glob', 'Grep') -AdditionalDirectories $Ctx.AdditionalDirectories `
            -MaxBudgetUsd $Ctx.MaxBudgetUsd -Name "orch:$($Ctx.Id):review" -LogPath (Join-Path $Ctx.LogDir "attempt-$Attempt-review-$try.json") `
            -ProgressFile $Ctx.ProgressFile -StopFile $Ctx.StopFile -ActivityLabel "[$($Ctx.Id)] review:" -Activity 'heartbeat'
        $Cost.Value += $r.Cost
        if ($r.Ok) { return $r.Structured }
    }
    @{ error = $r.Error }
}

function Invoke-TaskPipeline {
    # Runs one task to a verdict. Returns a hashtable with Success, Summary, Notes, Error, Cost, SessionId, Attempts.
    param([hashtable]$Ctx)
    $log = { param($msg) Write-OrchLog $Ctx.ProgressFile "[$($Ctx.Id)] $msg" }
    $cost = 0.0
    $sessionId = $Ctx.SessionId
    $summary = $Ctx.PreviousSummary; $notes = $Ctx.PreviousNotes
    $feedback = $Ctx.Feedback
    $workerRuns = 0
    $skipWorker = $Ctx.Mode -eq 'sync'
    $specRejections = [int]$Ctx.SpecRejections
    $retryMode = 'bounded'
    if (-not (Test-Path $Ctx.LogDir)) { New-Item -ItemType Directory -Path $Ctx.LogDir | Out-Null }
    $result = { param($ok, $err, $n) @{ Success = $ok; Summary = $summary; Notes = $notes; Error = $err; Cost = $cost; SessionId = $sessionId; Attempts = $n } }
    $pause = { param($mode)
        $r = & $result $false $null $workerRuns
        $r.Paused = $true; $r.Mode = $mode; $r.Feedback = $feedback; $r.SpecRejections = $specRejections
        $r
    }

    try {
        if ($Ctx.Mode -eq 'fresh' -and $Ctx.Setup) {
            & $log "setup: $($Ctx.Setup)"
            $s = Invoke-ShellCommand $Ctx.Worktree $Ctx.Setup (Join-Path $Ctx.LogDir 'setup.log') $Ctx.CommandTimeoutSec
            if (-not $s.Ok) { return (& $result $false "Setup command failed:`n$($s.Tail)" $workerRuns) }
        }

        for ($attempt = 1; $specRejections -lt 5 -and ($attempt -le $Ctx.MaxAttempts -or $retryMode -eq 'quality' -or $retryMode -eq 'spec'); $attempt++) {
            if ($Ctx.StopFile -and (Test-Path $Ctx.StopFile)) { return (& $pause ($skipWorker ? 'sync' : 'resume')) }
            $limit = if ($retryMode -eq 'quality') { 'unlimited' } elseif ($retryMode -eq 'spec') { '5 spec rejections' } else { "$($Ctx.MaxAttempts)" }
            $retryMode = 'bounded'
            if (-not $skipWorker) {
                if ($feedback -and $sessionId) {
                    $prompt = Format-Template 'retry.md' @{
                        TASK_ID = $Ctx.Id; ATTEMPT = $attempt; MAX_ATTEMPTS = $limit
                        FEEDBACK = $feedback; ACCEPTANCE = ($Ctx.Acceptance ?? '(none)')
                    }
                    $resume = $sessionId
                }
                else {
                    $fb = if ($feedback) { "`n## Feedback from the previous attempt`n`n$feedback`n" } else { '' }
                    $prompt = Format-Template 'worker.md' @{
                        TASK_ID = $Ctx.Id; TITLE = $Ctx.Title; PROMPT = $Ctx.Prompt; BRANCH = $Ctx.Branch
                        OWNS = (Format-Owns $Ctx.Owns $Ctx.Shared); ACCEPTANCE = ($Ctx.Acceptance ?? '(none - explain in your summary how you checked the work)')
                        ADDITIONAL_DIRECTORIES = $(if ($Ctx.AdditionalDirectories.Count) { ($Ctx.AdditionalDirectories | ForEach-Object { "- ``$_``" }) -join "`n" } else { '(none)' })
                        SUBAGENTS = (Format-SubAgents $Ctx.Provider 'worker')
                        DEPENDENCIES = $Ctx.DepContext; SPEC = ($Ctx.SpecText ?? '(no spec file)'); FEEDBACK = $fb
                    }
                    $resume = $null
                }
                & $log "attempt $attempt/$($limit): worker started ($($Ctx.Model))"
                $workerRuns++
                $w = Invoke-Agent -Provider $Ctx.Provider -AgentPath $Ctx.AgentPath -WorkDir $Ctx.Worktree -Prompt $prompt -Schema 'worker-result.schema.json' `
                    -Model $Ctx.Model -Effort $Ctx.Effort -PermissionMode $Ctx.PermissionMode -AllowedTools $Ctx.AllowedTools -SubAgents -AdditionalDirectories $Ctx.AdditionalDirectories `
                    -MaxBudgetUsd $Ctx.MaxBudgetUsd -ResumeSessionId $resume -Name "orch:$($Ctx.Id)" `
                    -LogPath (Join-Path $Ctx.LogDir "attempt-$attempt-worker.json") `
                    -ProgressFile $Ctx.ProgressFile -StopFile $Ctx.StopFile -ActivityLabel "[$($Ctx.Id)] worker:" -Activity 'heartbeat'
                $cost += $w.Cost
                if ($w.SessionId) { $sessionId = $w.SessionId }
                if ($w.Ok) { $out = $w.Structured }
                elseif ($w.Finished) {
                    # The run completed but gave no structured result even after a nudge. The gates below
                    # are the real check, so carry on with the plain-text answer as the summary.
                    & $log 'worker gave no structured result; continuing to the gates with its text answer'
                    $out = @{ status = 'done'; summary = "$($w.Text)"; notes_for_dependents = '' }
                }
                else {
                    $feedback = "The previous worker run ended with an error: $($w.Error)"
                    & $log "worker error: $($w.Error)"
                    continue
                }
                if ($out.status -eq 'blocked') {
                    return (& $result $false "Worker reported blocked: $($out.blocked_reason ?? $out.summary)" $workerRuns)
                }
                $summary = $out.summary; $notes = $out.notes_for_dependents
                $ignore = if ($null -ne $Ctx.Ignore) { $Ctx.Ignore } else { $script:DefaultSettings.ignore }
                $commitError = Save-WorkerChanges $Ctx.Worktree "orch($($Ctx.Id)): $($Ctx.Title)`n`nAttempt $attempt." $ignore
                if ($commitError) { $feedback = $commitError; & $log 'commit failed'; continue }
                if ($Ctx.StopFile -and (Test-Path $Ctx.StopFile)) { return (& $pause 'sync') }
            }
            $skipWorker = $false

            $changed = Get-TaskChanges $Ctx.Worktree $Ctx.IntegrationBranch
            if ($changed.Count -eq 0) {
                $feedback = 'No file changes were found on your branch. Implement the task in the worktree.'
                & $log 'no changes'; continue
            }
            if ($Ctx.EnforceOwns -and $Ctx.Owns.Count -gt 0) {
                $allowed = @($Ctx.Owns) + @($Ctx.Shared)
                $outside = @($changed | Where-Object { -not (Test-PathOwned $_ $allowed) })
                if ($outside.Count) {
                    $feedback = "You changed files outside the paths this task owns. Revert these (git checkout $($Ctx.IntegrationBranch) -- <file>, or delete new files) or move the change inside your paths:`n" + (($outside | ForEach-Object { "- $_" }) -join "`n")
                    & $log "edited files outside owns: $($outside -join ', ')"; continue
                }
            }

            if ($Ctx.StopFile -and (Test-Path $Ctx.StopFile)) { return (& $pause 'sync') }
            $syncError = Sync-WithIntegration $Ctx $attempt ([ref]$cost)
            if ($Ctx.StopFile -and (Test-Path $Ctx.StopFile)) { return (& $pause 'sync') }
            if ($syncError) { $feedback = $syncError; & $log 'sync with integration failed'; continue }

            if ($Ctx.Acceptance) {
                & $log "acceptance: $($Ctx.Acceptance)"
                $a = Invoke-ShellCommand $Ctx.Worktree $Ctx.Acceptance (Join-Path $Ctx.LogDir "attempt-$attempt-acceptance.log") $Ctx.CommandTimeoutSec
                if (-not $a.Ok) {
                    $feedback = "The acceptance command ``$($Ctx.Acceptance)`` failed (exit $($a.Exit)). Last output:`n``````n$($a.Tail)`n``````"
                    & $log "acceptance failed (exit $($a.Exit))"; continue
                }
            }

            if ($Ctx.Review) {
                if ($Ctx.StopFile -and (Test-Path $Ctx.StopFile)) { return (& $pause 'sync') }
                & $log "review started ($($Ctx.ReviewModel))"
                $rv = Invoke-Review $Ctx $attempt ([ref]$cost)
                if ($rv.paused) { return (& $pause 'sync') }
                if ($rv.error) { return (& $result $false "Review agent failed: $($rv.error)" $workerRuns) }
                if ($rv.spec_verdict -ne 'pass' -or $rv.quality_verdict -ne 'pass') {
                    $issues = @($rv.issues) | ForEach-Object { "- [$($_.severity)] $(if ($_.file) { "$($_.file): " })$($_.description)" }
                    $feedback = "The reviewer rejected the change (spec: $($rv.spec_verdict), quality: $($rv.quality_verdict)).`n$($rv.summary)`n" + ($issues -join "`n")
                    if ($rv.spec_verdict -eq 'fail') { $specRejections++; $retryMode = 'spec' }
                    else { $retryMode = 'quality' }
                    & $log "review rejected (spec $($rv.spec_verdict), quality $($rv.quality_verdict))"; continue
                }
                & $log 'review passed'
            }
            return (& $result $true $null $workerRuns)
        }
        & $result $false "Gave up after $($attempt - 1) attempts ($specRejections spec rejections). Last problem:`n$feedback" $workerRuns
    }
    catch {
        & $result $false "Pipeline error: $($_.Exception.Message)" $workerRuns
    }
}

#endregion

Export-ModuleMember -Function *-*
