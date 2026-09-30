# Stand-in for `claude -p` used by Run-SmokeTest.ps1. It reads the prompt from stdin, looks at the
# orchestrator-role marker and returns a canned JSON result in the same shape as `claude -p --output-format json`.
# Set FAKE_FAIL_ONCE to a task id to make that task's first worker attempt edit a file outside its owns.
# No param block on purpose: CLI flags land in $args and the piped prompt in $input.

$copilot = $args -contains '--output-format' -and $args[[array]::IndexOf($args, '--output-format') + 1] -eq 'json'
$prompt = if ($copilot) { $args[[array]::IndexOf($args, '-p') + 1] } else { @($input) -join "`n" }
$role = if ($prompt -match 'orchestrator-role: (\w+)') { $Matches[1] } else { 'unknown' }
$here = (Get-Location).Path
$memo = Join-Path ([IO.Path]::GetTempPath()) 'fake-claude'
New-Item -ItemType Directory -Force -Path $memo | Out-Null

function Out-Result($structured, $session = [guid]::NewGuid().ToString()) {
    if ($copilot) {
        $content = if ($structured) { $structured | ConvertTo-Json -Depth 20 -Compress } else { 'ok' }
        @{ type = 'assistant.message'; data = @{ phase = 'final_answer'; content = $content } } | ConvertTo-Json -Depth 20 -Compress
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
        $check = { param($f) "if (-not (Test-Path '$f')) { Write-Output 'missing $f'; exit 1 }" }
        Out-Result @{
            notes = 'Fake plan for the smoke test.'
            tasks = @(
                @{ id = 'contracts'; title = 'Define contracts'; deps = @(); owns = @('contracts/**'); acceptance = (& $check 'contracts/contracts.txt'); prompt = 'Write contracts.' }
                @{ id = 'feature-a'; title = 'Feature A'; deps = @('contracts'); owns = @('a/**'); acceptance = (& $check 'a/feature-a.txt'); prompt = 'Build A.' }
                @{ id = 'feature-b'; title = 'Feature B'; deps = @('contracts'); owns = @('b/**'); acceptance = (& $check 'b/feature-b.txt'); prompt = 'Build B.' }
                @{ id = 'wire-up'; title = 'Wire A and B together'; deps = @('feature-a', 'feature-b'); owns = @('app/**'); acceptance = (& $check 'app/wire-up.txt'); prompt = 'Wire it.' }
            )
        }
    }
    'worker' {
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
        # Set FAKE_NO_STRUCTURED to a task id to finish that task's first run without a structured result.
        if ($env:FAKE_NO_STRUCTURED -eq $id) { Out-Result $null "fake-$id" }
        Out-Result @{ status = 'done'; summary = "Fake work for $id"; notes_for_dependents = "See $dir/$id.txt" } "fake-$id"
    }
    'reviewer' { Out-Result @{ spec_verdict = 'pass'; quality_verdict = 'pass'; issues = @(); summary = 'Looks fine.' } }
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
