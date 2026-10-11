# .NET notes

Reference notes for projects the orchestrator builds on .NET. Found while building Example Project A
(October 2026, .NET SDK 10.0.302, C# 14).

## A test filter that matches nothing passes

`dotnet test --filter "FullyQualifiedName~Some.Namespace"` under VSTest prints a warning
and exits 0 when no test matches. An acceptance command with a misspelled namespace or a
module name that differs from the test folder therefore passes vacuously.

**For specs:** name the test folders and namespaces exactly in section 6, and make the
module names in 4.2 match them. **For plans:** pin the test class in the filter when a
task creates only one (`~ExampleProject.Tests.Module.ComponentTests`).

## Versions that worked together

| Package | Version | Note |
| --- | --- | --- |
| `xunit` | 2.9.3 | classic runner under VSTest; `--filter` works as above |
| `xunit.runner.visualstudio` | 3.1.5 | |
| `Microsoft.NET.Test.Sdk` | 18.10.1 | |
| `NAudio` | 2.4.0 | latest stable 2.x; `WaveOutEvent` + float `ISampleProvider` |

Do not mix in `xunit.v3` or Microsoft.Testing.Platform unless the spec asks for them: the
`dotnet test` filter syntax differs.

## Platform-specific APIs

Target `net10.0-windows` when the app uses NAudio's WinMM output; it silences the CA1416
platform analyzer without attributes on every call site. A test project that references
such an app must use the same target framework.

## Avalonia desktop apps

Found while building Example Project B (October 2026, .NET SDK 10.0.302, Avalonia 12.1.4).

**Run totals:** a 543-line spec, planned by Opus at `-Effort medium` into 22 tasks (bootstrap
0.75 USD, planner 1.32 USD), built by Opus workers and reviewers with `-MaxParallel 4`: 99.33
USD and about 2.5 hours, including two stalls fixed by hand (below, and the planner's
unparseable acceptance command, now caught by `Test-Plan`). Result: 305 files, 25K lines,
912 tests, 0 warnings.

**Versions that worked together:** `Avalonia`, `Avalonia.Desktop`, `Avalonia.Themes.Fluent`,
`Avalonia.Fonts.Inter` and `Avalonia.Headless.XUnit` 12.1.4; `CommunityToolkit.Mvvm` 8.4.2;
`xunit.v3` 3.2.2 (Avalonia.Headless.XUnit 12.1.4 depends on `xunit.v3.extensibility.core`
3.2.2 exactly); `xunit.runner.visualstudio` 3.1.5; `Microsoft.NET.Test.Sdk` 18.10.1.
xunit v3 under VSTest takes the same `dotnet test --filter` syntax as v2.

**Run headless UI tests serially.** Every `[AvaloniaFact]` runs on the one headless UI
thread. With xunit's collection parallelism on, the whole test project deadlocked once it
had more test classes than parallel threads (one per core, 20 here). Every smaller subset
passed, so each task's filtered acceptance passed, and only the unfiltered integration
check hung, until its 30-minute timeout. The hung test host kept the build output locked,
so the next two merges failed with `MSB3026: Could not copy`. The fix is
`[assembly: Xunit.CollectionBehavior(DisableTestParallelization = true)]` next to
`[assembly: AvaloniaTestApplication(...)]`; 85 headless tests then took 7 seconds.

**For specs:** put that attribute in the test infrastructure the contracts task writes.
**For plans:** add `--blame-hang-timeout 5m --blame-hang-dump-type none` to a `dotnet test`
integration check, so a hang fails in minutes and frees its locks. Kill a leftover test host
(`Get-CimInstance Win32_Process` with `<repo>.worktrees` in the command line) before retrying.

**Other traps:**
- `TreatWarningsAsErrors` turns xUnit1051 into an error: tests must pass
  `TestContext.Current.CancellationToken` to every method that takes a token.
- Avalonia 12 marks `Bitmap.Save(string)` obsolete (CS0618); use the overload with options.
- `RuntimeIdentifier`, `SelfContained` or `PublishSingleFile` in the App's csproj breaks a
  test project that references it (NETSDK1151). Pass them to `dotnet publish` instead.
- PowerShell's `& app.exe` returns at once for a WinExe and leaves `$LASTEXITCODE` unchanged.
  Smoke-test a GUI exe with `Start-Process -PassThru`, `WaitForExit(ms)` and `ExitCode`.
- Give the App project `AssemblyName` early (e.g. `ExampleProject` for `ExampleProject.App`): it decides
  the exe name and the `avares://<assembly>/` resource URIs.

## Silk.NET, SkiaSharp and NAudio desktop apps

Found while building Example Project F (October 2026, .NET SDK 10.0.302): a real-time desktop
app drawn with SkiaSharp on a Silk.NET OpenGL window, with NAudio output.

**Run totals:**
- Spec: 907 lines, planned by Opus at `-Effort medium` into 22 tasks (bootstrap 1.54 USD,
  planner 1.17 USD).
- Build: Opus workers and reviewers with `-MaxParallel 5`, 164.49 USD and about 4 hours 10
  minutes. 21 tasks merged on their first attempt. One reported blocked (the namespace trap
  below) and merged after a hand fix and `-RetryFailed`.
- Follow-up: a 3-task round, added to the same plan after a playtest, cost 24.31 USD and took
  35 minutes.
- Result: 338 C# files (15K lines of source, 21K of tests), 1,690 tests, 0 warnings.

**Versions that worked together:**

| Package | Version |
| --- | --- |
| `SkiaSharp` | 3.119.4 |
| `Silk.NET.Windowing`, `Silk.NET.Input`, `Silk.NET.OpenGL` | 2.23.0 |
| `NAudio` | 2.4.0 |
| `xunit` | 2.9.3 |
| `xunit.runner.visualstudio` | 3.1.5 |
| `Microsoft.NET.Test.Sdk` | 18.10.1 |

SkiaSharp 4.x was available but skipped: models know the 2.x/3.x API.
`GRContext.CreateGl` over the Silk.NET GL context worked first time, with a raster-surface
fallback.

**A test namespace can hide a method of the same name.**
- What happened:
  - The spec named a module `Run`, so its tests lived in `ExampleProject.Tests.Run`.
  - An earlier module's tests, in `ExampleProject.Tests.ModuleA.PartB`, called a helper `Run(...)`
    that they imported with `using static`.
  - C# name lookup finds `ExampleProject.Tests.Run` in an enclosing namespace before it finds
    members imported with `using static`. The other module's tests stopped compiling (CS0118).
  - The fix lay outside the task's `owns`, so the worker correctly reported blocked. The planner
    had spotted the same trap for a test namespace ending in `.System` and avoided it.
- **For specs:** don't use module names that are also common member or type names (`Run`,
  `Task`, `System`, `Action`, `Index`). Otherwise, ban `using static` helpers with those
  names.
- **To recover:**
  1. In the task's worktree, fix the clash.
  2. Commit the work on the task branch: `git add -A -- <owned paths>`, then `git commit`.
  3. Widen the task's `owns` in `tasks.json`.
  4. Rerun with `-RetryFailed`. The task resumes in sync mode, and its checks and review run
     again.

**Publishing:**
- `SkiaSharp.NativeAssets.Win32` puts an 80 MB `libSkiaSharp.pdb` into a self-contained publish.
  `-p:DebugType=none` does not remove it, so delete `*.pdb` from the output after publishing.
  That cut the folder from 214 to 133 MB.
- The `NAudio` meta-package pulls in WinForms. If size matters, reference only the parts you
  use, such as `NAudio.Wasapi` and `NAudio.WinMM`.

**Tests that render to PNG pay off.**
- The renderer drew whole frames on a CPU raster surface in xUnit and wrote PNGs. Workers and
  reviewers opened them and judged the visuals.
- After the run, a throwaway harness drove the finished app through its own scripted smoke
  driver and saved frames. It found integration-level problems that every module's tests
  missed: a banner drawn under an overlay that repeated its title, and an internal path format
  shown to the user. Those became the follow-up round.

**A tuning task meets exactly the metrics it is given.**
- The tuning task was asked for outcome targets only (how far a scripted bot gets). It met them
  by a route that hurt the intended experience.
- The follow-up round added the missing experience metric as a test, and the retune then kept
  both.
- **For specs:** when a task tunes numbers, state the experience it must keep as a measurable
  test, not just the outcome.

### Example Project G: same stack, no human involvement

Found while building Example Project G (October 2026, .NET SDK 10.0.302): a real-time desktop app
with hand-drawn vector art on the stack above. The user asked for no involvement, so `/write-spec`
ran without an interview.

**Run totals:**
- **Spec:**
  - Research subagents gathered the facts; the decisions went into the spec as requirements.
  - Two reviewer passes, then planning.
  - 821 lines, including a 122-row layout table in the contracts.
- **Planning:** Opus at `-Effort medium`, 17 tasks in 4 minutes (bootstrap 0.86 USD, planner
  0.78 USD).
- **Build:** Opus workers and reviewers with `-MaxParallel 5`, 106.21 USD and 2 hours 30 minutes.
  Every task merged on its first attempt.
- **Follow-up:** 2 tasks added after running the app (below), 4.53 USD and 20 minutes.
- **Result:** 116 source files (8.4K lines) and 68 test files (8.7K lines), 1,985 tests, 0 warnings.

**Reference images for art tasks.**
- Images the workers must look at, but which may not be copied into the repo, can live in a
  folder outside it. Add the folder to `settings.additionalDirectories` in `tasks.json` before
  the run; `Plan-Tasks.ps1` does not set it. Workers and reviewers both opened the images.
- Two things made the art tasks match on their first attempt:
  - a **labelled** reference sheet, with every element boxed and named as in the spec's layout
    table;
  - a test in each art module that renders its own sheet at the same scale, so the worker can
    compare the two side by side.
- Workers built their own crop and overlay scripts in `%TEMP%` to compare. They still wrote
  every path by hand, as the spec required.

**A layout table as a contract.** One row per visual element (name and bounding box) in the
contracts let the logic, art, backdrop and rendering tasks run in parallel. The planner split
each art module into two figure tasks plus an assembly task that owns the whole folder and
reviews the full sheet.

**A scripted test player keeps the rules honest.**
- The last engine task wrote a bot that sees only the public display and presses buttons.
- It had to reach a playability target over 10 seeds. Its prompt said to report blocked rather
  than change a rule to make the bot pass.
- It met the target with no engine change, which also showed the rules were consistent.

**GLFW windows are DPI aware.**
- Silk.NET's GLFW backend is per-monitor DPI aware, so window sizes are physical pixels.
- On a 250 % display, a 720 × 965 window filled a sixth of the screen. Silk.NET's default
  placement had already put the title bar above the screen on that display.
- **For specs:** give window sizes in device-independent pixels, scaled by
  `glfwGetWindowContentScale`. Fit and centre the window on `glfwGetMonitorWorkarea`.
- No test caught either problem; running the built app did. Two small follow-up tasks fixed
  them.

**Driving a GLFW window from a script.**
- `SendKeys` arrow keys arrive without the extended-key flag, and GLFW reads them as keypad keys.
  Send `SendInput` key events with `KEYEVENTF_SCANCODE | KEYEVENTF_EXTENDEDKEY` instead.
- Call `SetProcessDPIAware` in the capturing script, otherwise window rectangles come back
  scaled.
- Piping a script's output into `Select-Object -First N` stops the script early. The app it had
  started kept running and locked the build output: MSB3021 on the next build.
- PowerShell 7's `Add-Type` does not resolve `System.Drawing` or `System.Threading.Thread` from
  `-ReferencedAssemblies System.Drawing`. Run the capturing script under Windows PowerShell 5.1
  (`powershell.exe`), or reference `System.Drawing.Common`.

### Example Project H: same stack, designed from scratch, no human involvement

Found while building Example Project H (October 2026, .NET SDK 10.0.302): a new real-time desktop
app on the stack above. The user named Example Project G as its inspiration and asked for no
involvement. The spec therefore reused G's stack and module layout, but every rule, layout and
figure was designed new rather than replicated.

**Run totals:**
- **Spec:**
  - 823 lines and 10 modules, including a 93-row layout table, written without an interview.
  - Two cold reviewer passes, 15 and 18 minutes. They found 5 and 2 blocking issues.
- **Planning:** Opus at `-Effort medium`, 13 tasks in 5 minutes (bootstrap 0.71 USD, planner
  0.75 USD).
- **Build:** Opus workers and reviewers with `-MaxParallel 5`, 71.03 USD and 1 hour 53 minutes.
  Every task merged on its first attempt.
- **Result:** 100 source files (5.9K lines) and 83 test files (9.5K lines), 1,394 tests that run
  in about a second, 0 warnings.

**Auto mode cannot grant itself access to the target folder.**
- Adding the new repo folder to `permissions.additionalDirectories` was refused as
  self-modification. Writing the spec into that folder was refused too.
- Everything after the spec writes there, so the run waited until the user ran `/add-dir`.
- The spec was drafted and reviewed in the scratchpad in the meantime. `Plan-Tasks.ps1` accepts a
  spec outside the repo and copies it in.

**Figures drawn on both screens need a module of their own.**
- The same figures appeared in two art modules that run in parallel. The first review pass saw
  that two workers would draw them two different ways.
- The fix was a small shared module, built before both art modules, with a written-out API
  (pose, facing, box) and a table in the contracts mapping each segment to its call. Both art
  tasks then matched on their first attempt.
- The second review pass found attachment points in the layout table that contradicted the
  figure guide: a held object's box sat away from the hand that holds it. Fixing the boxes before
  planning avoided a likely blocked art task.

**Some platform calls need `unsafe`.** GLFW's content-scale, work-area and frame-size calls take
pointers. The app project needs `AllowUnsafeBlocks`, set by the skeleton, because tasks may not
edit project files. Files that import `Silk.NET.GLFW` also need `using Monitor =
Silk.NET.GLFW.Monitor;`, since ImplicitUsings brings in `System.Threading.Monitor`.

**A test bot with instant reactions proves fairness, not difficulty.**
- The scripted player pressed at most every 200 ms but read the display every 10 ms. It never
  missed, and it met every playability target without retuning.
- A throwaway harness then showed the bot the display 150-450 ms late:
  - at 150 ms, it lost only at top speed;
  - from 250 ms, it lost within seconds.
- A trace showed those losses came from the bot acting on stale state, not from unfair rules.
- **For specs:** when difficulty matters, add a reaction-delay variant of the bot with its own
  target.

**The window lessons of Example Project G held.** The spec gave window sizes in
device-independent pixels, fitted and centred on the work area. A live check on a high-DPI
display with a 3840 × 2280 work area found the window sized, fitted and centred correctly on the
first build.

## Layout that split well

One console project (`src/<App>/<App>.csproj`) with one folder and namespace per module,
one test project (`tests/<App>.Tests/`) with the same folders, a solution file at the
root, `dotnet restore` as setup and `dotnet build && dotnet test --no-build` as the
whole-project check. New `.cs` files are picked up by the SDK globs, so no task needs to
edit a project file and nothing has to go in `settings.shared` except
`**/packages.lock.json` as a safety net.
