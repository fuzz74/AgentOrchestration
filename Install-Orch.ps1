#requires -Version 7.2
<#
.SYNOPSIS
    Installs the short `orch` command on this PC. Run it once per PC.
.DESCRIPTION
    Sets the user environment variable ORCH_HOME to this checkout, and adds one line to the
    PowerShell profile that every PowerShell 7 host reads ($PROFILE.CurrentUserAllHosts), so it
    also works in the VS Code PowerShell extension's terminal. The line holds no path: a profile
    that OneDrive shares between PCs loads `orch` from each PC's own checkout, and does nothing on
    a PC without ORCH_HOME. It reads ORCH_HOME from the registry when the terminal's environment
    lacks it, so terminals of an editor started before the install work too.
    Running the script again changes nothing, unless the checkout has moved. It also loads `orch`
    into the terminal it runs in.
    -Provider sets this PC's default provider, the user environment variable ORCH_PROVIDER.
    `orch` uses it when neither -Provider nor the plan names one.
    It also links the skills in .claude\skills (/write-spec, /plan-tasks, /auto-develop) into
    the personal skill folders, ~\.claude\skills for Claude Code and ~\.copilot\skills for
    Copilot, so they work in every repo. The links are junctions into this checkout: they need
    no admin rights, and a git pull updates the skills. A real folder with a skill's name is
    left alone. Last, it allows this checkout and ~\.claude\skills in
    permissions.additionalDirectories of ~\.claude\settings.json, after a backup of that file,
    so Claude reads the orchestrator's files from another repo without asking.
.EXAMPLE
    .\Install-Orch.ps1 -Provider Claude
.EXAMPLE
    .\Install-Orch.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param([ValidateSet('Claude', 'Copilot')][string]$Provider)

$ErrorActionPreference = 'Stop'
$orchHome = $PSScriptRoot
$profilePath = $PROFILE.CurrentUserAllHosts
$profileLine = "& { `$h = `$env:ORCH_HOME ?? [Environment]::GetEnvironmentVariable('ORCH_HOME', 'User'); if (`$h) { Import-Module (Join-Path `$h 'orchestrator\Orch.psm1') -Global } }"
$changed = $false

$current = [Environment]::GetEnvironmentVariable('ORCH_HOME', 'User')
if ($current -ne $orchHome -and $PSCmdlet.ShouldProcess("ORCH_HOME = $orchHome", 'Set user environment variable')) {
    [Environment]::SetEnvironmentVariable('ORCH_HOME', $orchHome, 'User')
    Write-Host $(if ($current) { "ORCH_HOME changed from $current to $orchHome." } else { "ORCH_HOME set to $orchHome." })
    $changed = $true
}
$env:ORCH_HOME = $orchHome

if ($Provider) {
    $Provider = [string](@('Claude', 'Copilot') -eq $Provider)
    $currentProvider = [Environment]::GetEnvironmentVariable('ORCH_PROVIDER', 'User')
    if ($currentProvider -cne $Provider -and $PSCmdlet.ShouldProcess("ORCH_PROVIDER = $Provider", 'Set user environment variable')) {
        [Environment]::SetEnvironmentVariable('ORCH_PROVIDER', $Provider, 'User')
        Write-Host $(if ($currentProvider) { "Default provider changed from $currentProvider to $Provider." } else { "Default provider set to $Provider." })
        $changed = $true
    }
    $env:ORCH_PROVIDER = $Provider
}

$text = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }
if ($text -notmatch 'Orch\.psm1' -and $PSCmdlet.ShouldProcess($profilePath, 'Add the line that loads orch')) {
    New-Item -ItemType Directory -Force -Path (Split-Path $profilePath) | Out-Null
    $separator = if ($text -and -not $text.EndsWith("`n")) { [Environment]::NewLine } else { '' }
    Add-Content -Path $profilePath -Value "$separator# The short orch command for the agent orchestrator (added by Install-Orch.ps1)`n$profileLine"
    Write-Host "Added the line that loads orch to $profilePath."
    $changed = $true
}

$skillsSource = Join-Path $orchHome '.claude\skills'
foreach ($root in (Join-Path $HOME '.claude\skills'), (Join-Path $HOME '.copilot\skills')) {
    foreach ($skill in Get-ChildItem $skillsSource -Directory) {
        $link = Join-Path $root $skill.Name
        $item = Get-Item $link -Force -ErrorAction SilentlyContinue
        if ($item -and -not $item.LinkType) {
            Write-Warning "$link is a real folder, not a link, so it was left alone. /$($skill.Name) there is not this checkout's skill."
            continue
        }
        if ($item -and "$($item.Target)" -eq $skill.FullName) { continue }
        if (-not $PSCmdlet.ShouldProcess($link, "Link to $($skill.FullName)")) { continue }
        # Delete only the old link, never the folder it points to.
        if ($item) { [IO.Directory]::Delete($link, $false) }
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        New-Item -ItemType Junction -Path $link -Target $skill.FullName | Out-Null
        Write-Host "Linked $link to $($skill.FullName)."
        $changed = $true
    }
}

# The skills are read through their links in ~\.claude\skills, so that folder is allowed too.
$claudeSettings = Join-Path $HOME '.claude\settings.json'
$settings = if (Test-Path $claudeSettings) { Get-Content $claudeSettings -Raw | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }
if (-not $settings.permissions) { $settings.permissions = [ordered]@{} }
$allowed = @($settings.permissions.additionalDirectories | Where-Object { $_ })
$missing = @(@($orchHome, (Join-Path $HOME '.claude\skills')) | Where-Object {
        $dir = [IO.Path]::GetFullPath($_)
        -not ($allowed | Where-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') -eq $dir.TrimEnd('\') })
    } | ForEach-Object { $_ -replace '\\', '/' })
if ($missing.Count -and $PSCmdlet.ShouldProcess($claudeSettings, "Allow $($missing -join ' and ') in permissions.additionalDirectories")) {
    if (Test-Path $claudeSettings) { Copy-Item $claudeSettings "$claudeSettings.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    $settings.permissions.additionalDirectories = @($allowed + $missing)
    $settings | ConvertTo-Json -Depth 20 | Set-Content -Path $claudeSettings -Encoding utf8
    Write-Host "Allowed $($missing -join ' and ') for Claude in $claudeSettings."
    $changed = $true
}

if ($WhatIfPreference) { return }
Import-Module (Join-Path $orchHome 'orchestrator\Orch.psm1') -Global -Force
if ($changed) { Write-Host "orch is installed from $orchHome. It works in this terminal and in every new one." -ForegroundColor Green }
else { Write-Host "orch is already installed from $orchHome. Nothing changed." -ForegroundColor Green }
