#requires -Version 7.2
# Shared functions for the agent orchestrator: plan and state files, the task graph,
# git worktrees, calls to `claude -p`, and the per-task pipeline
# (worker -> commit -> ownership check -> sync -> acceptance -> review).

$script:PromptDir = Join-Path $PSScriptRoot 'prompts'
$script:SchemaDir = Join-Path $PSScriptRoot 'schemas'

$script:DefaultSettings = [ordered]@{
    model             = 'sonnet'
    reviewModel       = 'sonnet'
    effort            = $null
    permissionMode    = 'acceptEdits'
    allowedTools      = @('Read', 'Edit', 'Write', 'Glob', 'Grep', 'Bash', 'PowerShell')
    maxAttempts       = 3
    maxBudgetUsd      = 10
    review            = $true
    setup             = $null
    integrationCheck  = $null
    commandTimeoutSec = 1800
    enforceOwns       = $true
    shared            = @()
    # Never committed from a worktree: build and tool artifacts that repos often forget to .gitignore.
    ignore            = @('**/__pycache__/**', '**/*.pyc', '**/.pytest_cache/**', '**/.mypy_cache/**', '**/.venv/**', '**/node_modules/**', '**/.DS_Store')
}

#region Paths, logging, claude discovery

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
        ProgressFile        = Join-Path $runDir 'progress.md'
        LogDir              = Join-Path $runDir 'logs'
        WorktreeRoot        = $wtRoot
        IntegrationWorktree = Join-Path $wtRoot '_integration'
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

function Resolve-ClaudePath {
    param([string]$ClaudePath)
    if ($ClaudePath) { return (Resolve-Path $ClaudePath).Path }
    if ($env:ORCH_CLAUDE) { return $env:ORCH_CLAUDE }
    $cmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    # Fall back to the binary bundled with the VS Code extension (newest version first).
    $extRoot = Join-Path $HOME '.vscode/extensions'
    $candidates = Get-ChildItem $extRoot -Directory -Filter 'anthropic.claude-code-*' -ErrorAction SilentlyContinue |
        Sort-Object { try { [version]($_.Name -replace '^anthropic\.claude-code-([\d.]+).*$', '$1') } catch { [version]'0.0' } } -Descending
    foreach ($dir in $candidates) {
        foreach ($name in 'claude.exe', 'claude') {
            $p = Join-Path $dir.FullName "resources/native-binary/$name"
            if (Test-Path $p) { return $p }
        }
    }
    throw 'Could not find claude. Put it on PATH, set $env:ORCH_CLAUDE, or pass -ClaudePath.'
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
        $counts[$t.id] = $seen.Count
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
        sessionId = $null; summary = $null; notes = $null; error = $null
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

function Invoke-Git {
    param([string]$Dir, [string[]]$Arguments)
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
    Set-Content -Path $LogPath -Value "> $Command`n$text" -Encoding utf8
    Remove-Item $errPath -ErrorAction SilentlyContinue
    $tail = (($text -split "`r?`n") | Select-Object -Last 80) -join "`n"
    if ($timedOut) { $tail = "Timed out after $TimeoutSec s.`n$tail" }
    [pscustomobject]@{ Ok = (-not $timedOut -and $exit -eq 0); Exit = $exit; Tail = $tail.Trim() }
}

#endregion

#region claude

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

function Invoke-Claude {
    # One non-interactive claude call. The prompt goes in on stdin; the JSON result is logged and parsed.
    param(
        [string]$ClaudePath, [string]$WorkDir, [string]$Prompt, [string]$Schema,
        [string]$Model, [string]$Effort, [string]$PermissionMode, [string[]]$AllowedTools, [string[]]$Tools,
        [double]$MaxBudgetUsd, [string]$ResumeSessionId, [string]$Name, [string]$LogPath
    )
    $cliArgs = [Collections.Generic.List[string]]::new()
    $cliArgs.AddRange([string[]]@('-p', '--output-format', 'json', '--permission-prompts', 'none'))
    if ($Schema) { $cliArgs.AddRange([string[]]@('--json-schema', (Get-CompactSchema $Schema))) }
    if ($Model) { $cliArgs.AddRange([string[]]@('--model', $Model)) }
    if ($Effort) { $cliArgs.AddRange([string[]]@('--effort', $Effort)) }
    if ($PermissionMode) { $cliArgs.AddRange([string[]]@('--permission-mode', $PermissionMode)) }
    if ($AllowedTools) { $cliArgs.AddRange([string[]]@('--allowedTools', ($AllowedTools -join ','))) }
    if ($Tools) { $cliArgs.AddRange([string[]]@('--tools', ($Tools -join ','))) }
    if ($MaxBudgetUsd -gt 0) { $cliArgs.AddRange([string[]]@('--max-budget-usd', [string]$MaxBudgetUsd)) }
    if ($ResumeSessionId) { $cliArgs.AddRange([string[]]@('--resume', $ResumeSessionId)) }
    if ($Name) { $cliArgs.AddRange([string[]]@('--name', $Name)) }

    if ($LogPath) { Set-Content -Path "$LogPath.prompt.md" -Value $Prompt -Encoding utf8 }
    $errPath = if ($LogPath) { "$LogPath.stderr" } else { [IO.Path]::GetTempFileName() }
    Push-Location $WorkDir
    try { $stdout = $Prompt | & $ClaudePath @cliArgs 2> $errPath; $exit = $LASTEXITCODE }
    finally { Pop-Location }
    $text = (@($stdout) -join "`n").Trim()
    if ($LogPath) { Set-Content -Path $LogPath -Value $text -Encoding utf8 }

    $parsed = $null
    try { $parsed = $text | ConvertFrom-Json -AsHashtable }
    catch {
        $last = @($stdout) | Where-Object { "$_".TrimStart().StartsWith('{') } | Select-Object -Last 1
        if ($last) { try { $parsed = $last | ConvertFrom-Json -AsHashtable } catch { } }
    }
    $stderrTail = ((Get-Content $errPath -ErrorAction SilentlyContinue) | Select-Object -Last 20) -join "`n"
    $finished = $exit -eq 0 -and $parsed -and -not $parsed.is_error
    $ok = $finished -and (-not $Schema -or $parsed.structured_output)
    $err = $null
    if (-not $ok) {
        $err = if ($finished) { "the run finished without a structured result: $($parsed.result)" }
               elseif ($parsed -and $parsed.result) { "$($parsed.subtype): $($parsed.result)" }
               elseif ($parsed -and $parsed.subtype) { "claude ended with $($parsed.subtype)" }
               else { "claude exited with $exit. $stderrTail" }
    }
    $r = [pscustomobject]@{
        Ok         = [bool]$ok
        Finished   = [bool]$finished
        Exit       = $exit
        SessionId  = $parsed ? $parsed.session_id : $null
        Cost       = [double]($parsed ? ($parsed.total_cost_usd ?? 0) : 0)
        Structured = $parsed ? $parsed.structured_output : $null
        Text       = $parsed ? $parsed.result : $text
        Error      = $err
    }

    # Models sometimes finish the work but skip (or only claim) the structured result.
    # Resume the same session once and ask for just the result.
    if ($Schema -and $finished -and -not $ok -and $r.SessionId -and -not $script:InNudge) {
        $script:InNudge = $true
        try {
            $nudge = Invoke-Claude -ClaudePath $ClaudePath -WorkDir $WorkDir -Schema $Schema -Model $Model -Effort $Effort `
                -PermissionMode $PermissionMode -AllowedTools $AllowedTools -Tools $Tools -MaxBudgetUsd $MaxBudgetUsd `
                -ResumeSessionId $r.SessionId -Name $Name -LogPath ($LogPath ? "$LogPath.nudge.json" : $null) `
                -Prompt 'Your work is finished. Do not do any more work. Report your result now by calling the StructuredOutput tool with the required fields.'
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
    Write-OrchLog $Ctx.ProgressFile "[$($Ctx.Id)] merge conflicts with $($Ctx.IntegrationBranch); starting resolver"
    $prompt = Format-Template 'resolver.md' @{
        BRANCH = $Ctx.Branch; TASK_ID = $Ctx.Id; TITLE = $Ctx.Title; INTEGRATION = $Ctx.IntegrationBranch
        FILES = (($conflicts -split "`n") | ForEach-Object { "- $_" }) -join "`n"; PROMPT = $Ctx.Prompt
    }
    $r = Invoke-Claude -ClaudePath $Ctx.ClaudePath -WorkDir $wt -Prompt $prompt -Model $Ctx.ReviewModel `
        -PermissionMode 'acceptEdits' -AllowedTools ($Ctx.AllowedTools + @('Bash(git add *)', 'Bash(git status *)', 'Bash(git diff *)')) `
        -MaxBudgetUsd $Ctx.MaxBudgetUsd -Name "orch:$($Ctx.Id):resolve" -LogPath (Join-Path $Ctx.LogDir "attempt-$Attempt-resolver.json")
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
        SPEC = ($Ctx.SpecText ?? '(no spec file)'); BASE = $Ctx.IntegrationBranch
        DIFF_STAT = (Invoke-Git $wt @('diff', '--stat', $range)).Output; DIFF = $diff
    }
    for ($try = 1; $try -le 2; $try++) {
        $r = Invoke-Claude -ClaudePath $Ctx.ClaudePath -WorkDir $wt -Prompt $prompt -Schema 'review-result.schema.json' `
            -Model $Ctx.ReviewModel -PermissionMode 'dontAsk' -Tools @('Read', 'Glob', 'Grep') -AllowedTools @('Read', 'Glob', 'Grep') `
            -MaxBudgetUsd $Ctx.MaxBudgetUsd -Name "orch:$($Ctx.Id):review" -LogPath (Join-Path $Ctx.LogDir "attempt-$Attempt-review-$try.json")
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
    $feedback = $null
    $workerRuns = 0
    $skipWorker = $Ctx.Mode -eq 'sync'
    if (-not (Test-Path $Ctx.LogDir)) { New-Item -ItemType Directory -Path $Ctx.LogDir | Out-Null }
    $result = { param($ok, $err, $n) @{ Success = $ok; Summary = $summary; Notes = $notes; Error = $err; Cost = $cost; SessionId = $sessionId; Attempts = $n } }

    try {
        if ($Ctx.Mode -eq 'fresh' -and $Ctx.Setup) {
            & $log "setup: $($Ctx.Setup)"
            $s = Invoke-ShellCommand $Ctx.Worktree $Ctx.Setup (Join-Path $Ctx.LogDir 'setup.log') $Ctx.CommandTimeoutSec
            if (-not $s.Ok) { return (& $result $false "Setup command failed:`n$($s.Tail)" $workerRuns) }
        }

        for ($attempt = 1; $attempt -le $Ctx.MaxAttempts; $attempt++) {
            if (-not $skipWorker) {
                if ($feedback -and $sessionId) {
                    $prompt = Format-Template 'retry.md' @{
                        TASK_ID = $Ctx.Id; ATTEMPT = $attempt; MAX_ATTEMPTS = $Ctx.MaxAttempts
                        FEEDBACK = $feedback; ACCEPTANCE = ($Ctx.Acceptance ?? '(none)')
                    }
                    $resume = $sessionId
                }
                else {
                    $fb = if ($feedback) { "`n## Feedback from the previous attempt`n`n$feedback`n" } else { '' }
                    $prompt = Format-Template 'worker.md' @{
                        TASK_ID = $Ctx.Id; TITLE = $Ctx.Title; PROMPT = $Ctx.Prompt; BRANCH = $Ctx.Branch
                        OWNS = (Format-Owns $Ctx.Owns $Ctx.Shared); ACCEPTANCE = ($Ctx.Acceptance ?? '(none - explain in your summary how you checked the work)')
                        DEPENDENCIES = $Ctx.DepContext; SPEC = ($Ctx.SpecText ?? '(no spec file)'); FEEDBACK = $fb
                    }
                    $resume = $null
                }
                & $log "attempt $attempt/$($Ctx.MaxAttempts): worker started ($($Ctx.Model))"
                $workerRuns++
                $w = Invoke-Claude -ClaudePath $Ctx.ClaudePath -WorkDir $Ctx.Worktree -Prompt $prompt -Schema 'worker-result.schema.json' `
                    -Model $Ctx.Model -Effort $Ctx.Effort -PermissionMode $Ctx.PermissionMode -AllowedTools $Ctx.AllowedTools `
                    -MaxBudgetUsd $Ctx.MaxBudgetUsd -ResumeSessionId $resume -Name "orch:$($Ctx.Id)" `
                    -LogPath (Join-Path $Ctx.LogDir "attempt-$attempt-worker.json")
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

            $syncError = Sync-WithIntegration $Ctx $attempt ([ref]$cost)
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
                & $log "review started ($($Ctx.ReviewModel))"
                $rv = Invoke-Review $Ctx $attempt ([ref]$cost)
                if ($rv.error) { return (& $result $false "Review agent failed: $($rv.error)" $workerRuns) }
                if ($rv.spec_verdict -ne 'pass' -or $rv.quality_verdict -ne 'pass') {
                    $issues = @($rv.issues) | ForEach-Object { "- [$($_.severity)] $(if ($_.file) { "$($_.file): " })$($_.description)" }
                    $feedback = "The reviewer rejected the change (spec: $($rv.spec_verdict), quality: $($rv.quality_verdict)).`n$($rv.summary)`n" + ($issues -join "`n")
                    & $log "review rejected (spec $($rv.spec_verdict), quality $($rv.quality_verdict))"; continue
                }
                & $log 'review passed'
            }
            return (& $result $true $null $workerRuns)
        }
        & $result $false "Gave up after $($Ctx.MaxAttempts) attempts. Last problem:`n$feedback" $workerRuns
    }
    catch {
        & $result $false "Pipeline error: $($_.Exception.Message)" $workerRuns
    }
}

#endregion

Export-ModuleMember -Function *-*
