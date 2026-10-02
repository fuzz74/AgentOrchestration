#requires -Version 7.2
<#
.SYNOPSIS
    Follow readable agent conversations from an orchestrator run.

.DESCRIPTION
    Read-only. Shows requests and responses from worker, reviewer, planner and bootstrap
    sessions, then follows new JSONL events. Click Open full request to view its prompt
    in a scrollable in-terminal popup; O opens the latest request without a mouse.
    Press Q or Ctrl+C to stop without affecting the run. -Once prints plain output.

.EXAMPLE
    ./Watch-Conversations.ps1 -RepoPath C:\src\myapp
.EXAMPLE
    ./Watch-Conversations.ps1 -RepoPath C:\src\myapp -Task terminal -ShowTools
.EXAMPLE
    ./Watch-Conversations.ps1 -RepoPath C:\src\myapp -NoMouse  # O opens latest request
.EXAMPLE
    ./Watch-Conversations.ps1 -RepoPath C:\src\myapp -Task terminal -Last 50 -Once
#>
[CmdletBinding()]
param(
    [string]$RepoPath = '.',
    [string]$Task,
    [ValidateRange(0, 500)][int]$Last = 25,
    [ValidateRange(1, 60)][int]$RefreshSeconds = 2,
    [switch]$ShowTools,
    [switch]$FullRequests,
    [switch]$NoMouse,
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Orchestrator.psm1') -Force
$paths = Get-OrchPaths -RepoPath $RepoPath
$offsets = @{}
$seenPrompts = @{}

function Get-EventFiles {
    if (-not (Test-Path $paths.LogDir)) { return @() }
    @(Get-ChildItem $paths.LogDir -Recurse -File -Filter '*.events.jsonl' |
        Where-Object { -not $Task -or ([IO.Path]::GetRelativePath($paths.LogDir, $_.FullName).Split([IO.Path]::DirectorySeparatorChar)[0] -eq $Task) } |
        Sort-Object FullName)
}

function Get-EventLabel([string]$File) {
    $relative = [IO.Path]::GetRelativePath($paths.LogDir, $File)
    $parts = $relative.Split([IO.Path]::DirectorySeparatorChar)
    $taskName = if ($parts.Length -gt 1) { $parts[0] } elseif ($parts[0] -match '^(planner|bootstrap)') { $Matches[1] } else { 'orchestrator' }
    $name = [IO.Path]::GetFileName($File)
    $role = if ($name -match 'review') { 'review' } elseif ($name -match 'worker') { 'worker' } elseif ($name -match 'resolver') { 'resolver' } else { 'agent' }
    $attempt = if ($name -match '^attempt-(\d+)') { "#$($Matches[1])" } else { '' }
    "$taskName/$role$attempt"
}

function Convert-Event($Event, [string]$Label) {
    $text = $null
    $kind = 'response'
    switch ($Event.type) {
        'assistant.message' {
            if ($Event.data.phase -in 'commentary', 'final_answer') { $text = "$($Event.data.content)" }
        }
        'tool.execution_start' {
            if ($ShowTools) {
                $kind = 'tool'
                $toolName = $Event.data.toolName
                $detail = $Event.data.arguments.description ?? $Event.data.arguments.path ?? ''
                $text = "tool: $toolName $detail".Trim()
            }
        }
        'assistant' {
            $messages = foreach ($block in @($Event.message.content)) {
                if ($block.type -eq 'text' -and "$($block.text)".Trim()) { "$($block.text)" }
                elseif ($ShowTools -and $block.type -eq 'tool_use') { "tool: $($block.name)" }
            }
            $text = $messages -join "`n"
        }
    }
    if (-not $text -or -not $text.Trim()) { return }
    $when = [datetimeoffset]::MinValue
    if ($Event.timestamp) { try { $when = [datetimeoffset]$Event.timestamp } catch { } }
    [pscustomobject]@{ Time = $when; Label = $Label; Kind = $kind; Text = $text.Trim() }
}

function Read-NewEvents([IO.FileInfo]$File) {
    $position = [long]($offsets[$File.FullName] ?? 0L)
    try { $stream = [IO.FileStream]::new($File.FullName, 'Open', 'Read', 'ReadWrite, Delete') }
    catch { return }
    try {
        if ($stream.Length -lt $position) { $position = 0 }
        $length = [int]($stream.Length - $position)
        if ($length -eq 0) { return }
        $buffer = [byte[]]::new($length)
        [void]$stream.Seek($position, 'Begin')
        $read = 0
        while ($read -lt $length) {
            $count = $stream.Read($buffer, $read, $length - $read)
            if ($count -eq 0) { break }
            $read += $count
        }
        if ($read -eq 0) { return }
        $end = [Array]::LastIndexOf($buffer, [byte]10, $read - 1)
        if ($end -lt 0) { return }
        $offsets[$File.FullName] = $position + $end + 1
        $label = Get-EventLabel $File.FullName
        foreach ($line in [Text.Encoding]::UTF8.GetString($buffer, 0, $end + 1).Split("`n")) {
            if (-not $line.TrimStart().StartsWith('{')) { continue }
            try {
                $item = Convert-Event ($line | ConvertFrom-Json -AsHashtable) $label
                if ($item) { $item }
            }
            catch { continue }
        }
    }
    finally { $stream.Dispose() }
}

function Read-Conversation([IO.FileInfo]$File) {
    $promptPath = $File.FullName -replace '\.events\.jsonl$', '.prompt.md'
    if (-not $seenPrompts.ContainsKey($promptPath) -and (Test-Path $promptPath)) {
        try { $prompt = [IO.File]::ReadAllText($promptPath) } catch { $prompt = $null }
        if ($prompt) {
            $seenPrompts[$promptPath] = $true
            $lines = @($prompt.Trim().Split("`n"))
            $text = if (-not $FullRequests -and $lines.Count -gt 12) {
                (($lines | Select-Object -First 12) -join "`n").TrimEnd() + "`n... Full request: $promptPath"
            }
            else { $prompt.Trim() }
            [pscustomobject]@{
                Time = [datetimeoffset](Get-Item $promptPath).LastWriteTimeUtc
                Label = Get-EventLabel $File.FullName
                Kind = 'request'
                Text = $text
                PromptPath = $promptPath
            }
        }
    }
    Read-NewEvents $File
}

function Show-Message($Message) {
    $time = if ($Message.Time -eq [datetimeoffset]::MinValue) { '--:--:--' } else { $Message.Time.ToLocalTime().ToString('HH:mm:ss') }
    $color = if ($Message.Kind -eq 'request') { 'Green' } elseif ($Message.Kind -eq 'tool') { 'DarkGray' } elseif ($Message.Label -match 'review') { 'Yellow' } else { 'White' }
    Write-Host "[$time][$($Message.Label)][$($Message.Kind.ToUpperInvariant())]" -ForegroundColor $color
    Write-Host $Message.Text
}

function Get-WrappedLines([string]$Text, [int]$Width) {
    foreach ($line in ($Text -replace "`r", '').Split("`n")) {
        if (-not $line) { ''; continue }
        $remaining = $line.Replace("`t", '    ')
        while ($remaining.Length -gt $Width) {
            $split = $remaining.LastIndexOf(' ', $Width)
            if ($split -le 0) { $split = $Width }
            $remaining.Substring(0, $split)
            $remaining = $remaining.Substring($split).TrimStart()
        }
        $remaining
    }
}

function Get-TranscriptLines([int]$Width) {
    foreach ($message in $history) {
        $time = if ($message.Time -eq [datetimeoffset]::MinValue) { '--:--:--' } else { $message.Time.ToLocalTime().ToString('HH:mm:ss') }
        $color = if ($message.Kind -eq 'request') { 'Green' } elseif ($message.Kind -eq 'tool') { 'DarkGray' } elseif ($message.Label -match 'review') { 'Yellow' } else { 'White' }
        $header = "[$time][$($message.Label)][$($message.Kind.ToUpperInvariant())]"
        $header = $header.Substring(0, [math]::Min($header.Length, $Width))
        [pscustomobject]@{ Text = $header; Color = $color; Path = $null }
        foreach ($rawLine in ($message.Text -replace "`r", '').Split("`n")) {
            if ($message.PromptPath -and $rawLine -like '... Full request:*') { continue }
            foreach ($line in (Get-WrappedLines $rawLine $Width)) {
                [pscustomobject]@{ Text = $line; Color = 'Gray'; Path = $null }
            }
        }
        if ($message.PromptPath) {
            [pscustomobject]@{ Text = '  [Open full request]'; Color = 'Link'; Path = $message.PromptPath; HitStart = 2; HitEnd = 21 }
        }
        [pscustomobject]@{ Text = ''; Color = 'Gray'; Path = $null }
    }
}

function Open-Request([string]$Path) {
    try { $content = [IO.File]::ReadAllText($Path) } catch { return }
    $popup.Path = $Path
    $popup.Content = $content
    $popup.Top = 0
    $view.BarDrag = $null
}

function Draw-Conversation {
    $width = [math]::Max(24, [Console]::WindowWidth - 1)
    $height = [math]::Max(8, [Console]::WindowHeight - 1)
    $view.Page = [math]::Max(1, $height - 3)
    $view.Hits = @{}
    $screen = [Collections.Generic.List[string]]::new()
    $title = "Conversations: $($paths.Repo)$(if ($Task) { " / $Task" }) | mouse: $(if ($mouse) { 'on' } else { 'off' })"
    $screen.Add($title.Substring(0, [math]::Min($title.Length, $width)))
    if ($popup.Path) {
        $boxWidth = [math]::Min(100, $width - 2)
        $boxHeight = [math]::Min(38, $height - 3)
        $contentWidth = $boxWidth - 4
        $lines = @(Get-WrappedLines $popup.Content $contentWidth)
        $page = [math]::Max(1, $boxHeight - 4)
        $max = [math]::Max(0, $lines.Count - $page)
        $popup.Top = [math]::Min($popup.Top, $max)
        $left = [math]::Max(0, [int][math]::Floor(($width - $boxWidth) / 2))
        $view.BarCol = if ($mouse -and $max -gt 0) { $left + $boxWidth - 2 } else { -1 }
        $view.BarRow = $screen.Count + 3
        $view.BarRows = $page + 1
        $view.ThumbSize = if ($max -gt 0) { [math]::Max(1, [math]::Round($view.BarRows * $page / $lines.Count)) } else { 0 }
        $view.ThumbTop = if ($max -gt 0) { [int][math]::Round(($view.BarRows - $view.ThumbSize) * $popup.Top / $max) } else { 0 }
        $screen.Add((' ' * $left) + '┌' + ('─' * ($boxWidth - 2)) + '┐')
        $title = " Full request: $([IO.Path]::GetFileName($popup.Path))"
        $screen.Add((' ' * $left) + '│' + $title.PadRight($boxWidth - 6).Substring(0, $boxWidth - 6) + ' [X]│')
        $view.CloseRow = $screen.Count - 1
        $view.CloseCol = $left + $boxWidth - 3
        $screen.Add((' ' * $left) + '├' + ('─' * ($boxWidth - 2)) + '┤')
        foreach ($line in ($lines | Select-Object -Skip $popup.Top -First $page)) {
            $barRow = $screen.Count - $view.BarRow
            $bar = if ($view.BarCol -lt 0) { ' ' } elseif ($barRow -ge $view.ThumbTop -and $barRow -lt $view.ThumbTop + $view.ThumbSize) { '█' } else { '░' }
            $screen.Add((' ' * $left) + '│ ' + $line.PadRight($contentWidth).Substring(0, $contentWidth) + "$bar│")
        }
        while ($screen.Count -lt $boxHeight) {
            $barRow = $screen.Count - $view.BarRow
            $bar = if ($view.BarCol -lt 0) { ' ' } elseif ($barRow -ge $view.ThumbTop -and $barRow -lt $view.ThumbTop + $view.ThumbSize) { '█' } else { '░' }
            $screen.Add((' ' * $left) + '│ ' + (' ' * $contentWidth) + "$bar│")
        }
        $screen.Add((' ' * $left) + '└' + ('─' * ($boxWidth - 2)) + '┘')
        $footer = "Lines $($popup.Top + 1)-$([math]::Min($lines.Count, $popup.Top + $page)) of $($lines.Count)  |  Up/Down, PgUp/PgDn, wheel  |  Esc to close"
        $screen.Add($footer.Substring(0, [math]::Min($footer.Length, $width)))
        $view.PopupMax = $max
        $view.PopupPage = $page
    }
    else {
        $latest = if ($latestRequest) { "  [Open full request: $($latestRequest.Label)]" } else { '  No saved requests yet' }
        $latest = $latest.Substring(0, [math]::Min($latest.Length, $width))
        if ($latestRequest) {
            $view.Hits[1] = [pscustomobject]@{ Path = $latestRequest.PromptPath; HitStart = 2; HitEnd = $latest.Length }
            $screen.Add("`e[$(if ($mouse) { '36;4' } else { '36' })m$latest`e[0m")
        }
        else { $screen.Add($latest) }
        $lines = @(Get-TranscriptLines ($width - 2))
        $view.Max = [math]::Max(0, $lines.Count - $view.Page)
        if ($view.Follow) { $view.Top = $view.Max }
        $view.Top = [math]::Min($view.Top, $view.Max)
        $row = 2
        foreach ($line in ($lines | Select-Object -Skip $view.Top -First $view.Page)) {
            if ($line.Path) { $view.Hits[$row] = $line }
            $colorCode = switch ($line.Color) { 'Green' { '32' } 'White' { '97' } 'Link' { $(if ($mouse) { '36;4' } else { '36' }) } 'Yellow' { '33' } 'DarkGray' { '90' } default { '37' } }
            $screen.Add("`e[${colorCode}m$($line.Text)`e[0m")
            $row++
        }
        $footer = "Lines $($view.Top + 1)-$([math]::Min($lines.Count, $view.Top + $view.Page)) of $($lines.Count)  |  $(if ($mouse) { 'Click Open full request' } else { 'Mouse unavailable' }), O: open, Q: quit"
        $screen.Add($footer.Substring(0, [math]::Min($footer.Length, $width)))
    }
    $output = [Text.StringBuilder]::new("`e[H")
    foreach ($line in $screen) {
        [void]$output.Append($line).Append("`e[K`n")
    }
    [void]$output.Append("`e[J")
    [Console]::Write($output.ToString())
}

function Invoke-ConversationKey([ConsoleKey]$Key) {
    if ($popup.Path) {
        switch ($Key) {
            'Escape' { $popup.Path = $null }
            'Q' { $popup.Path = $null }
            'X' { $popup.Path = $null }
            'UpArrow' { $popup.Top = [math]::Max(0, $popup.Top - 1) }
            'DownArrow' { $popup.Top = [math]::Min($view.PopupMax, $popup.Top + 1) }
            'PageUp' { $popup.Top = [math]::Max(0, $popup.Top - $view.PopupPage) }
            'PageDown' { $popup.Top = [math]::Min($view.PopupMax, $popup.Top + $view.PopupPage) }
            'Home' { $popup.Top = 0 }
            'End' { $popup.Top = $view.PopupMax }
        }
        return
    }
    switch ($Key) {
        'Q' { $view.Quit = $true }
        'O' {
            if ($latestRequest) { Open-Request $latestRequest.PromptPath }
        }
        'UpArrow' { $view.Follow = $false; $view.Top = [math]::Max(0, $view.Top - 1) }
        'DownArrow' { $view.Top = [math]::Min($view.Max, $view.Top + 1); $view.Follow = $view.Top -eq $view.Max }
        'PageUp' { $view.Follow = $false; $view.Top = [math]::Max(0, $view.Top - $view.Page) }
        'PageDown' { $view.Top = [math]::Min($view.Max, $view.Top + $view.Page); $view.Follow = $view.Top -eq $view.Max }
        'Home' { $view.Follow = $false; $view.Top = 0 }
        'End' { $view.Follow = $true; $view.Top = $view.Max }
    }
}

function Enable-ConversationMouse {
    if (-not $IsWindows) { return $false }
    if (-not ('OrchConversation.ConsoleInput' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace OrchConversation {
    public sealed class InputEvent {
        public bool IsKey; public int Key;
        public int X, Y, WindowTop, Wheel; public uint Buttons, Flags;
    }
    public static class ConsoleInput {
        [StructLayout(LayoutKind.Sequential)]
        struct KEY_EVENT_RECORD { public int KeyDown; public ushort RepeatCount, VirtualKeyCode, VirtualScanCode, UnicodeChar; public uint ControlKeyState; }
        [StructLayout(LayoutKind.Sequential)]
        struct MOUSE_EVENT_RECORD { public short X, Y; public uint ButtonState, ControlKeyState, EventFlags; }
        [StructLayout(LayoutKind.Explicit)]
        struct INPUT_RECORD {
            [FieldOffset(0)] public ushort EventType;
            [FieldOffset(4)] public KEY_EVENT_RECORD Key;
            [FieldOffset(4)] public MOUSE_EVENT_RECORD Mouse;
        }
        [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
        [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint mode);
        [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint mode);
        [DllImport("kernel32.dll")] static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint count);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern bool ReadConsoleInputW(IntPtr h, [Out] INPUT_RECORD[] buffer, uint length, out uint read);
        const uint WindowInput = 0x8, MouseInput = 0x10, QuickEdit = 0x40, ExtendedFlags = 0x80, VirtualTerminalInput = 0x200;
        static IntPtr handle; static uint savedMode; static bool enabled;

        public static bool Enable() {
            handle = GetStdHandle(-10);
            if (handle == IntPtr.Zero || handle == new IntPtr(-1) || !GetConsoleMode(handle, out savedMode)) return false;
            uint mode = (savedMode | MouseInput | WindowInput | ExtendedFlags) & ~(QuickEdit | VirtualTerminalInput);
            enabled = SetConsoleMode(handle, mode);
            return enabled;
        }
        public static void Restore() { if (enabled) { SetConsoleMode(handle, savedMode); enabled = false; } }
        public static List<InputEvent> Read(int windowTop) {
            var events = new List<InputEvent>();
            uint pending;
            if (!enabled || !GetNumberOfConsoleInputEvents(handle, out pending) || pending == 0) return events;
            var buffer = new INPUT_RECORD[Math.Min(pending, 64u)];
            uint read;
            if (!ReadConsoleInputW(handle, buffer, (uint)buffer.Length, out read)) return events;
            for (int i = 0; i < read; i++) {
                var item = buffer[i];
                if (item.EventType == 1 && item.Key.KeyDown != 0) {
                    events.Add(new InputEvent { IsKey = true, Key = item.Key.VirtualKeyCode });
                } else if (item.EventType == 2) {
                    var mouse = item.Mouse;
                    int wheel = (mouse.EventFlags & 0x4) != 0 ? (short)(mouse.ButtonState >> 16) : 0;
                    events.Add(new InputEvent { X = mouse.X, Y = mouse.Y, WindowTop = windowTop, Wheel = wheel, Buttons = mouse.ButtonState & 0xFFFF, Flags = mouse.EventFlags });
                }
            }
            return events;
        }
    }
}
'@
    }
    try { [OrchConversation.ConsoleInput]::Enable() } catch { $false }
}

function Invoke-ConversationMouse($Event) {
    $row = $Event.Y - $Event.WindowTop
    if ($popup.Path -and ($Event.Buttons -band 1) -eq 0 -and $Event.Wheel -eq 0) { $view.BarDrag = $null; return $false }
    if ($Event.Wheel -ne 0) {
        $change = -[math]::Sign($Event.Wheel) * 3
        if ($popup.Path) { $popup.Top = [math]::Min($view.PopupMax, [math]::Max(0, $popup.Top + $change)) }
        else { $view.Top = [math]::Min($view.Max, [math]::Max(0, $view.Top + $change)); $view.Follow = $view.Top -eq $view.Max }
        return $true
    }
    if ($popup.Path -and $null -ne $view.BarDrag -and ($Event.Buttons -band 1) -ne 0) {
        $room = $view.BarRows - $view.ThumbSize
        if ($room -le 0) { return $false }
        $thumbTop = [math]::Min([math]::Max(0, $row - $view.BarRow - $view.BarDrag), $room)
        $popup.Top = [int][math]::Round($thumbTop * $view.PopupMax / $room)
        return $true
    }
    if (($Event.Buttons -band 1) -eq 0 -or $Event.Flags -notin 0, 2) { return $false }
    if ($popup.Path) {
        if ($row -eq $view.CloseRow -and [math]::Abs($Event.X - $view.CloseCol) -le 1) { $popup.Path = $null; return $true }
        if ($Event.X -eq $view.BarCol -and $row -ge $view.BarRow -and $row -lt $view.BarRow + $view.BarRows) {
            $barRow = $row - $view.BarRow
            if ($barRow -lt $view.ThumbTop) { $popup.Top = [math]::Max(0, $popup.Top - $view.PopupPage) }
            elseif ($barRow -ge $view.ThumbTop + $view.ThumbSize) { $popup.Top = [math]::Min($view.PopupMax, $popup.Top + $view.PopupPage) }
            else { $view.BarDrag = $barRow - $view.ThumbTop }
            return $true
        }
        return $false
    }
    $hit = $view.Hits[$row]
    if ($hit -and $Event.X -ge $hit.HitStart -and $Event.X -lt $hit.HitEnd) {
        Open-Request $hit.Path
        return $true
    }
    $false
}

$initial = @(Get-EventFiles | ForEach-Object { Read-Conversation $_ })
if ($Once) {
    Write-Host "Conversations: $($paths.Repo)$(if ($Task) { " (task: $Task)" })" -ForegroundColor Green
    foreach ($message in ($initial | Sort-Object Time | Select-Object -Last $Last)) { Show-Message $message }
    return
}
if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { throw 'Interactive terminal required; use -Once for redirected I/O.' }
$history = [Collections.Generic.List[object]]::new()
foreach ($message in ($initial | Sort-Object Time | Select-Object -Last $Last)) { $history.Add($message) }
$latestRequest = $initial | Where-Object PromptPath | Sort-Object Time | Select-Object -Last 1
$view = @{ Top = 0; Max = 0; Page = 1; Follow = $true; Hits = @{}; Quit = $false; CloseRow = -1; CloseCol = -1; PopupMax = 0; PopupPage = 1; BarCol = -1; BarRow = -1; BarRows = 0; ThumbTop = 0; ThumbSize = 0; BarDrag = $null }
$popup = @{ Path = $null; Content = ''; Top = 0 }
$mouse = $false
[Console]::Write("`e[?1049h`e[?25l")
try {
    $mouse = -not $NoMouse -and (Enable-ConversationMouse)
    while (-not $view.Quit) {
        foreach ($message in @(Get-EventFiles | ForEach-Object { Read-Conversation $_ }) | Sort-Object Time) {
            $history.Add($message)
            if ($message.PromptPath) { $latestRequest = $message }
        }
        Draw-Conversation
        $next = (Get-Date).AddSeconds($RefreshSeconds)
        while ((Get-Date) -lt $next -and -not $view.Quit) {
            $changed = $false
            if ($mouse) {
                $top = [Console]::WindowTop
                foreach ($event in [OrchConversation.ConsoleInput]::Read($top)) {
                    if ($event.IsKey -and [Enum]::IsDefined([ConsoleKey], $event.Key)) {
                        Invoke-ConversationKey ([ConsoleKey]$event.Key)
                        $changed = $true
                    }
                    elseif (-not $event.IsKey -and (Invoke-ConversationMouse $event)) { $changed = $true }
                }
            }
            elseif ([Console]::KeyAvailable) {
                Invoke-ConversationKey ([Console]::ReadKey($true).Key)
                $changed = $true
            }
            if ($changed) { Draw-Conversation }
            else { [Threading.Thread]::Sleep(30) }
        }
    }
}
finally {
    if ($mouse) { [OrchConversation.ConsoleInput]::Restore() }
    [Console]::Write("`e[?25h`e[?1049l")
}