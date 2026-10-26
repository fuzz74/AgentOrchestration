#requires -Version 7.2
# Static instruction contracts only; interactive interview and output choice require manual checks.
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$skills = Join-Path $root '.claude/skills'
function Skill([string]$Name) { Get-Content (Join-Path $skills "$Name/SKILL.md") -Raw }
function Has([string]$Text, [string]$Pattern) { $Text -match $Pattern }
$wrappers = [ordered]@{ analyze = 'orch'; 'auto-analyze' = 'auto-develop'; 'write-spec-analyze' = 'write-spec' }
$checks = [ordered]@{}
foreach ($name in $wrappers.Keys) {
    $text = Skill $name
    $delegate = $wrappers[$name]
    $checks["$name forwards to $delegate"] =
        (Has $text "Skill tool \(``skill: $delegate``") -and
        (Has $text "\.\./$delegate/SKILL\.md") -and
        (Has $text "request.*word for\s+word") -and
        (Has $text 'mode: analysis') -and
        (Has $text 'combined text')
    $checks["$name stays a thin wrapper"] =
        -not (Has $text '(?i)Prime directive:|settings\.workerType|Initialize-Project|Invoke-Orchestrator|tasks\.json')
}
$auto = Skill 'auto-develop'
$orch = Skill 'orch'
$plan = Skill 'plan-tasks'
$spec = Skill 'write-spec'
$template = Get-Content (Join-Path $skills 'write-spec/spec-template.md') -Raw
$review = Get-Content (Join-Path $skills 'write-spec/reviewer-prompt.md') -Raw
$rules = Get-Content (Join-Path $root 'orchestrator/prompts/planning-rules.md') -Raw
$checks['autonomy directive belongs to auto-develop'] = (Has $auto 'Prime directive: You work 100% autonomously') -and
    (Has $auto 'mode: analysis') -and (Has $auto 'stops before the merge') -and
    -not (Has (Skill 'auto-analyze') 'Prime directive:|100% autonomously')
$checks['mode flows from spec to both planners'] = (Has $spec 'settings\.workerType') -and
    (Has $spec 'Plan-Tasks\.ps1.*-WorkerType <Coding\|Analysis>') -and
    (Has $spec 'orch plan <path> -WorkerType <Coding\|Analysis>') -and
    (Has $plan 'Initialize-Project\.ps1.*-WorkerType <Coding\|Analysis>') -and
    (Has $plan '(?s)settings\.workerType.{0,90}"analysis"') -and (Has $rules 'workerType.*`coding`')
$checks['resumes honor persisted mode and conflicts'] = (Has $orch 'settings\.workerType.*authoritative; absent means coding') -and
    (Has $orch 'without involvement, stop and report the conflict') -and
    (Has $orch 'Never change the plan.s mode') -and
    (Has $plan 'missing means coding') -and (Has $plan 'do not rewrite its mode or retag tasks') -and
    (Has $plan 'stop and explain the conflict')
$checks['output choice is reviewed and kept in repo'] = (Has $spec 'Preserve a representation the\s+user specified') -and
    (Has $spec 'choose a suitable representation, record that choice') -and
    (Has $spec 'do not ask a separate\s+format-choice question') -and
    (Has $spec 'repo-relative\s+destinations') -and
    (Has $template 'analysis mode') -and (Has $template 'sources and access limits') -and
    (Has $review 'For analysis specs:') -and (Has $review 'user.s')
$checks['software sections conditional; coding tasks allowed'] = (Has $spec 'Do not demand software design, contracts, setup or tests') -and
    (Has $template 'only if software is needed') -and (Has $review 'Do not require software commands for analysis') -and
    (Has $plan 'workerType: "coding"') -and (Has $rules 'coding tasks')
$checks['handoff and finish remain shared'] = (Has $orch 'Start `write-spec` with the user.s idea and selected mode') -and
    (Has $orch 'Start `plan-tasks` with the spec and selected mode') -and
    (Has $orch 'orch try') -and (Has $orch 'orch finish') -and
    (Has (Skill 'write-spec-analyze') 'stops at its hand-off')
foreach ($check in $checks.GetEnumerator()) {
    Write-Host ("{0,-55} {1}" -f $check.Key, ($check.Value ? 'PASS' : 'FAIL')) -ForegroundColor ($check.Value ? 'Green' : 'Red')
}
if ($checks.Values -contains $false) { exit 1 }
Write-Host 'Manual checks not run: specified/unspecified output interviews, coding-tool interview, spec-only stop, mode conflict, and legacy resume.'
