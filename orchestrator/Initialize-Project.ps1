#requires -Version 7.2
<#
.SYNOPSIS
    Creates the skeleton of a new project from its spec, so the orchestrator can build on it.

.DESCRIPTION
    Does nothing if the repo already has commits. Otherwise (no folder, no git repo, or no
    commits yet) it runs `git init`, lets a bootstrap agent create the manifest, dependencies,
    test runner and one smoke test for the stack the spec names, and commits the result. It
    then checks in a clean checkout that the setup command and the whole-project check pass.
    Failures go back to the same agent session and the fix is amended into the commit.
    The two commands are saved in .orchestrator/project.json, where Plan-Tasks.ps1 picks them
    up. Plan-Tasks.ps1 calls this script itself, so you rarely need to run it directly.

.EXAMPLE
    ./Initialize-Project.ps1 -Spec C:\src\myapp\.orchestrator\spec.md -RepoPath C:\src\myapp
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Spec,
    [Parameter(Mandatory)][string]$RepoPath,
    [string]$Model = 'sonnet',
    [string]$ClaudePath,
    [double]$MaxBudgetUsd = 5,
    [int]$MaxAttempts = 3
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Orchestrator.psm1') -Force

$specText = Get-Content (Resolve-Path $Spec).Path -Raw
if (-not (Test-Path $RepoPath)) { New-Item -ItemType Directory -Path $RepoPath | Out-Null }
$RepoPath = (Resolve-Path $RepoPath).Path
& git -C $RepoPath rev-parse --show-toplevel *> $null
if ($LASTEXITCODE -ne 0) {
    $r = Invoke-Git $RepoPath @('init', '-q', '-b', 'main')
    if ($r.Exit -ne 0) { throw "git init failed: $($r.Output)" }
}
if ((Invoke-Git $RepoPath @('rev-parse', '--verify', '--quiet', 'HEAD')).Exit -eq 0) {
    Write-Verbose "$RepoPath already has commits; no skeleton needed."
    return
}

$paths = Get-OrchPaths -RepoPath $RepoPath
Initialize-RunDir $paths   # excludes .orchestrator/ before anything is committed
$claude = Resolve-ClaudePath $ClaudePath
$defaults = Get-DefaultSettings
$logBase = Join-Path $paths.LogDir ("bootstrap-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $logBase | Out-Null
$log = { param($m) Write-OrchLog $paths.ProgressFile "[bootstrap] $m" }
& $log "Creating the project skeleton in $($paths.Repo) with $Model"

$call = @{
    ClaudePath = $claude; WorkDir = $paths.Repo; Schema = 'bootstrap-result.schema.json'; Model = $Model
    PermissionMode = $defaults.permissionMode; AllowedTools = $defaults.allowedTools
    MaxBudgetUsd = $MaxBudgetUsd; Name = 'orch:bootstrap'
    ProgressFile = $paths.ProgressFile; ActivityLabel = '[bootstrap]'; Activity = 'each'
}
$pathspec = @('--', '.') + @($defaults.ignore | ForEach-Object { ":(exclude,glob)$_" })
$checkDir = Join-Path $paths.WorktreeRoot '_bootstrap-check'
$cost = 0.0
$sessionId = $null
$feedback = $null

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $prompt = if ($attempt -eq 1) { Format-Template 'bootstrap.md' @{ SPEC = $specText } }
              else { "<!-- orchestrator-role: bootstrap -->`nAttempt $attempt of ${MaxAttempts}. $feedback`n`nFix it in the current directory, run both commands again, and report the result." }
    $r = Invoke-Claude @call -Prompt $prompt -ResumeSessionId $sessionId -LogPath (Join-Path $logBase "attempt-$attempt.json")
    $cost += $r.Cost
    if ($r.SessionId) { $sessionId = $r.SessionId }
    if (-not $r.Ok) { throw "Bootstrap agent failed: $($r.Error)" }
    $out = $r.Structured
    if ($out.status -eq 'blocked') { throw "Bootstrap agent is blocked: $($out.blocked_reason)" }
    & $log "attempt ${attempt}: $($out.summary)"

    # Commit (the first attempt) or amend (later attempts), leaving build artifacts out.
    [void](Invoke-Git $paths.Repo (@('add', '-A') + $pathspec))
    $hasHead = (Invoke-Git $paths.Repo @('rev-parse', '--verify', '--quiet', 'HEAD')).Exit -eq 0
    if (-not $hasHead -and (Invoke-Git $paths.Repo @('diff', '--cached', '--quiet')).Exit -eq 0) {
        $feedback = 'You did not create any files. Create the project skeleton described in the first message.'
        continue
    }
    $c = if ($hasHead) { Invoke-Git $paths.Repo @('commit', '-q', '--amend', '--no-edit') }
         else { Invoke-Git $paths.Repo @('commit', '-q', '-m', 'Project skeleton') }
    if ($c.Exit -ne 0) { throw "git commit failed: $($c.Output)" }

    # Check from a clean checkout, the way every task worktree will start.
    if (Test-Path $checkDir) { [void](Invoke-Git $paths.Repo @('worktree', 'remove', '--force', $checkDir)) }
    [void](Invoke-Git $paths.Repo @('worktree', 'prune'))
    $w = Invoke-Git $paths.Repo @('worktree', 'add', '--detach', $checkDir, 'HEAD')
    if ($w.Exit -ne 0) { throw "Could not create a check worktree: $($w.Output)" }
    $failed = $null
    try {
        foreach ($step in @(@('setup', $out.setup), @('integration check', $out.integration_check))) {
            if (-not $step[1]) { $failed = "You returned no $($step[0]) command."; break }
            & $log "checking $($step[0]): $($step[1])"
            $s = Invoke-ShellCommand $checkDir $step[1] (Join-Path $logBase "attempt-$attempt-$($step[0] -replace ' ', '-').log") $defaults.commandTimeoutSec
            if (-not $s.Ok) {
                $failed = "The skeleton was committed, but in a clean checkout the $($step[0]) command ``$($step[1])`` failed. " +
                          "Only committed files are there: nothing listed in .gitignore, and no installed dependencies until setup runs.`n$($s.Tail)"
                break
            }
        }
    }
    finally {
        [void](Invoke-Git $paths.Repo @('worktree', 'remove', '--force', $checkDir))
        if (Test-Path $checkDir) { Remove-Item -Recurse -Force $checkDir -ErrorAction SilentlyContinue }
    }
    if (-not $failed) {
        [ordered]@{ setup = $out.setup; integrationCheck = $out.integration_check } |
            ConvertTo-Json | Set-Content -Path (Join-Path $paths.RunDir 'project.json') -Encoding utf8
        & $log ("Skeleton committed and checked ({0:N2} USD). setup: {1}; integration check: {2}" -f $cost, $out.setup, $out.integration_check)
        return
    }
    & $log "attempt ${attempt} failed the clean-checkout check"
    $feedback = $failed
}
throw "The project skeleton still fails its checks after $MaxAttempts attempts. See $logBase. Last problem:`n$feedback"
