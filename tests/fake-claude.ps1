# Stand-in for `claude -p` used by Run-SmokeTest.ps1. It reads the prompt from stdin, looks at the
# orchestrator-role marker and returns a canned JSON result in the same shape as `claude -p --output-format json`.
# Planner and worker runs first stream a sub-agent call (Out-SubAgent) for the watch views.
# Set FAKE_FAIL_ONCE to a task id to make that task's first worker attempt edit a file outside its owns.
# No param block on purpose: CLI flags land in $args and the piped prompt in $input.

$copilot = $args -contains '--output-format' -and $args[[array]::IndexOf($args, '--output-format') + 1] -eq 'json'
if ($copilot -and $env:FAKE_REQUIRE_MODEL -and $args[[array]::IndexOf($args, '--model') + 1] -ne $env:FAKE_REQUIRE_MODEL) {
    throw "Expected Copilot model $env:FAKE_REQUIRE_MODEL"
}
if ($env:FAKE_REQUIRE_ADD_DIR) {
    $positions = @(for ($index = 0; $index -lt $args.Count - 1; $index++) { if ($args[$index] -eq '--add-dir') { $index } })
    if ($positions.Count -ne 1 -or $args[$positions[0] + 1] -ne $env:FAKE_REQUIRE_ADD_DIR) {
        throw "Expected --add-dir $env:FAKE_REQUIRE_ADD_DIR"
    }
}
$prompt = @($input) -join "`n"
$role = if ($prompt -match 'orchestrator-role: (\w+)') { $Matches[1] } else { 'unknown' }
if ($copilot -and ($toolFilter = @($args) -like '--available-tools=*')) {
    # With --allow-all-tools, this filter is all that keeps the planner and reviewer read-only.
    # Workers and the planner also get sub-agents, which inherit the filter.
    $edit = 'view,apply_patch,glob,rg,powershell,read_powershell,stop_powershell,list_powershell'
    $expected = switch ($role) {
        'reviewer' { 'view,glob,rg' }
        'planner' { 'view,glob,rg,task,read_agent,list_agents' }
        { $_ -in 'bootstrap', 'resolver' } { $edit }
        default { "$edit,task,read_agent,list_agents" }   # a worker, or the nudge that resumes one
    }
    if ($toolFilter -ne "--available-tools=$expected") { throw "Expected --available-tools=$expected for $role, got $toolFilter" }
}
if (-not $copilot -and $role -ne 'unknown') {
    # Only workers and the planner get sub-agents (Task).
    $allowed = @(if (($i = [array]::IndexOf($args, '--allowedTools')) -ge 0) { $args[$i + 1] -split ',' })
    $tools = @(if (($i = [array]::IndexOf($args, '--tools')) -ge 0) { $args[$i + 1] -split ',' })
    $want = $role -in 'planner', 'worker'
    if (($allowed -contains 'Task') -ne $want -or ($tools.Count -and ($tools -contains 'Task') -ne $want)) {
        throw "Expected Task $(if ($want) { 'in' } else { 'not in' }) the tools for $role, got --allowedTools $($allowed -join ',') --tools $($tools -join ',')"
    }
}
$here = (Get-Location).Path
$memo =Join-Path ([IO.Path]::GetTempPath()) 'fake-claude'
New-Item -ItemType Directory -Force -Path $memo | Out-Null

function Out-SubAgent {
    # The agent hands one question to a sub-agent, the way each CLI streams it. Claude's sub-agent
    # runs in the background, so the session sends an early result before its last turn.
    $ask = @{ description = 'Survey the fake repo'; prompt = "List the files in the repo.`nReport what each one holds." }
    $events = if ($copilot) {
        @{ type = 'tool.execution_start'; data = @{ toolCallId = 'call-sub'; toolName = 'task'; arguments = $ask + @{ mode = 'sync' } } }
        @{ type = 'subagent.started'; agentId = 'sub-1'; data = @{ toolCallId = 'call-sub'; agentDescription = $ask.description } }
        @{ type = 'tool.execution_start'; agentId = 'sub-1'; data = @{ toolCallId = 'call-glob'; toolName = 'glob'; parentToolCallId = 'call-sub'; arguments = @{ pattern = '**/*' } } }
        @{ type = 'tool.execution_complete'; agentId = 'sub-1'; data = @{ toolCallId = 'call-glob'; parentToolCallId = 'call-sub'; success = $true } }
        @{ type = 'subagent.completed'; agentId = 'sub-1'; data = @{ toolCallId = 'call-sub' } }
        @{ type = 'tool.execution_complete'; data = @{ toolCallId = 'call-sub'; success = $true } }
    }
    else {
        @{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; id = 'toolu-sub'; name = 'Agent'; input = $ask + @{ run_in_background = $true } }) } }
        @{ type = 'user'; message = @{ content = @(@{ type = 'tool_result'; tool_use_id = 'toolu-sub'; content = 'Async agent launched.' }) } }
        @{ type = 'assistant'; parent_tool_use_id = 'toolu-sub'; message = @{ content = @(@{ type = 'text'; text = 'Listing the files.' }, @{ type = 'tool_use'; id = 'toolu-glob'; name = 'Glob'; input = @{ pattern = '**/*' } }) } }
        @{ type = 'user'; parent_tool_use_id = 'toolu-sub'; message = @{ content = @(@{ type = 'tool_result'; tool_use_id = 'toolu-glob'; content = 'skeleton.txt' }) } }
        @{ type = 'result'; subtype = 'success'; is_error = $false; total_cost_usd = 0.005; result = 'Waiting for the sub-agent.' }
        @{ type = 'assistant'; message = @{ content = @(@{ type = 'text'; text = 'The sub-agent reported back.' }) } }
    }
    $events | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }
}

function Out-Result($structured, $session = [guid]::NewGuid().ToString()) {
    if ($copilot) {
        $content = if ($structured) { $structured | ConvertTo-Json -Depth 20 -Compress } else { 'ok' }
        @{ type = 'assistant.message'; data = @{ phase = 'final_answer'; content = $content } } | ConvertTo-Json -Depth 20 -Compress
        # A sub-agent's answer that comes last must not become the agent's result.
        if ($role -in 'planner', 'worker') {
            @{ type = 'assistant.message'; agentId = 'sub-1'; data = @{ phase = 'final_answer'; content = 'The repo holds skeleton.txt.' } } | ConvertTo-Json -Compress
        }
        @{ type = 'result'; sessionId = $session; exitCode = 0 } | ConvertTo-Json -Compress
        exit 0
    }
    [ordered]@{
        type = 'result'; subtype = 'success'; is_error = $false; session_id = $session
        total_cost_usd = 0.01; result = 'ok'; structured_output = $structured
    } | ConvertTo-Json -Depth 20 -Compress
    exit 0
}

# The orchestrator's follow-up when a run finished without a structured result.
if ($prompt -match 'Report your result now') {
    $sid = $args[[array]::IndexOf($args, '--resume') + 1]
    Out-Result @{ status = 'done'; summary = "Result after nudge ($sid)"; notes_for_dependents = '' } $sid
}
if ($prompt -match 'Your previous JSON did not match the schema') {
    $sid = $args[[array]::IndexOf($args, '--resume') + 1]
    Out-Result @{ status = 'done'; summary = "Result after nudge ($sid)"; notes_for_dependents = '' } $sid
}

switch ($role) {
    'bootstrap' {
        # First attempt forgets tool.txt, so the clean-checkout check fails and the fix is amended.
        Set-Content (Join-Path $here 'skeleton.txt') 'skeleton'
        if ($prompt -match 'clean checkout') { Set-Content (Join-Path $here 'tool.txt') 'tool' }
        Out-Result @{
            status = 'done'; summary = 'Fake skeleton.'
            setup = "if (-not (Test-Path 'skeleton.txt')) { exit 1 }"
            integration_check = "if (-not (Test-Path 'tool.txt')) { Write-Output 'missing tool.txt'; exit 1 }"
        } 'fake-bootstrap'
    }
    'planner' {
        Out-SubAgent
        $check = { param($f) "if (-not (Test-Path '$f')) { Write-Output 'missing $f'; exit 1 }" }
        Out-Result @{
            notes = 'Fake plan for the smoke test.'
            shared = @(if ($env:FAKE_SHARED) { 'registry.txt' })
            tasks = @(
                @{ id = 'contracts'; title = 'Define contracts'; deps = @(); owns = @('contracts/**'); acceptance = (& $check 'contracts/contracts.txt'); prompt = 'Write contracts.' }
                @{ id = 'feature-a'; title = 'Feature A'; deps = @('contracts'); owns = @('a/**'); acceptance = (& $check 'a/feature-a.txt'); prompt = 'Build A.'; workerType = 'coding' }
                @{ id = 'feature-b'; title = 'Feature B'; deps = @('contracts'); owns = @('b/**'); acceptance = (& $check 'b/feature-b.txt'); prompt = 'Build B.' }
                @{ id = 'wire-up'; title = 'Wire A and B together'; deps = @('feature-a', 'feature-b'); owns = @('app/**'); acceptance = (& $check 'app/wire-up.txt'); prompt = 'Wire it.' }
            )
        }
    }
    'worker' {
        Out-SubAgent
        if ($prompt -match '## Your task: (\S+) - ') {
            $id = $Matches[1]
            $dir = if ($prompt -match '- `([^`/]+)/\*\*`') { $Matches[1] } else { '.' }
            Set-Content (Join-Path $memo "$id.dir") $dir
        }
        elseif ($prompt -match 'on task (\S+) and it did not pass') {
            $id = $Matches[1]; $dir = Get-Content (Join-Path $memo "$id.dir")
        }
        else { Write-Error 'fake-claude: cannot find task id'; exit 1 }

        $failMarker = Join-Path $memo "$id.failed-once"
        if ($env:FAKE_FAIL_ONCE -eq $id -and -not (Test-Path $failMarker)) {
            Set-Content $failMarker 'x'
            Set-Content (Join-Path $here 'outside-owns.txt') 'oops'
        }
        else {
            Remove-Item (Join-Path $here 'outside-owns.txt') -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path (Join-Path $here $dir) | Out-Null
            Set-Content (Join-Path $here "$dir/$id.txt") "built by $id"
            # Every task appends to one shared file, so parallel tasks conflict on merge.
            if ($env:FAKE_SHARED) { Add-Content (Join-Path $here 'registry.txt') $id }
        }
        if ($env:FAKE_STOP_TASK -eq $id) {
            & (Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')) -NoProfile -File (Join-Path $PSScriptRoot '../orchestrator/Request-OrchestratorStop.ps1') -RepoPath $env:FAKE_STOP_REPO
            if ($LASTEXITCODE -ne 0) { throw 'Stop request script failed.' }
        }
        # Set FAKE_NO_STRUCTURED to a task id to finish that task's first run without a structured result.
        if ($env:FAKE_NO_STRUCTURED -eq $id) { Out-Result $null "fake-$id" }
        Out-Result @{ status = 'done'; summary = "Fake work for $id"; notes_for_dependents = "See $dir/$id.txt" } "fake-$id"
    }
    'reviewer' {
        if ($prompt -match '## The task: (quality-only|spec-only|pause-retry) - ') {
            $id = $Matches[1]
            $counter = Join-Path $memo "$id.review-count"
            $count = if (Test-Path $counter) { [int](Get-Content $counter) + 1 } else { 1 }
            Set-Content $counter $count
            if ($id -eq 'pause-retry' -and $count -eq 1) {
                & (Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')) -NoProfile -File (Join-Path $PSScriptRoot '../orchestrator/Request-OrchestratorStop.ps1') -RepoPath $env:FAKE_STOP_REPO
                if ($LASTEXITCODE -ne 0) { throw 'Stop request script failed.' }
                Out-Result @{ spec_verdict = 'pass'; quality_verdict = 'fail'; issues = @(@{ severity = 'major'; description = 'Fix the bug.' }); summary = 'Bug remains.' }
            }
            if ($id -eq 'quality-only' -and $count -le 4) {
                Out-Result @{ spec_verdict = 'pass'; quality_verdict = 'fail'; issues = @(@{ severity = 'major'; description = 'Fix the bug.' }); summary = 'Bug remains.' }
            }
            if ($id -eq 'spec-only') {
                Out-Result @{ spec_verdict = 'fail'; quality_verdict = 'fail'; issues = @(@{ severity = 'major'; description = 'Meet the spec.' }); summary = 'Spec remains incomplete.' }
            }
        }
        Out-Result @{ spec_verdict = 'pass'; quality_verdict = 'pass'; issues = @(); summary = 'Looks fine.' }
    }
    'resolver' {
        # Keep both sides: drop the conflict markers from each listed file and stage it.
        $section = ($prompt -split 'Conflicted files:')[1] -split 'Resolve every conflict' | Select-Object -First 1
        foreach ($m in [regex]::Matches($section, '(?m)^- (.+?)\s*$')) {
            $file = Join-Path $here $m.Groups[1].Value
            (Get-Content $file) | Where-Object { $_ -notmatch '^(<<<<<<<|=======|>>>>>>>)' } | Set-Content $file
            git add -- $m.Groups[1].Value
        }
        Out-Result $null
    }
    default { Write-Error "fake-claude: unknown role '$role'"; exit 1 }
}
