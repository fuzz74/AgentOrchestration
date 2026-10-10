# .NET notes

Reference notes for projects the orchestrator builds on .NET. Found while building Beatfall
(October 2026, .NET SDK 10.0.302, C# 14).

## A test filter that matches nothing passes

`dotnet test --filter "FullyQualifiedName~Some.Namespace"` under VSTest prints a warning
and exits 0 when no test matches. An acceptance command with a misspelled namespace or a
module name that differs from the test folder therefore passes vacuously.

**For specs:** name the test folders and namespaces exactly in section 6, and make the
module names in 4.2 match them. **For plans:** pin the test class in the filter when a
task creates only one (`~Beatfall.Tests.Play.JudgeTests`).

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

Found while building Kinfolio (October 2026, .NET SDK 10.0.302, Avalonia 12.1.4).

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
- Give the App project `AssemblyName` early (e.g. `Kinfolio` for `Kinfolio.App`): it decides
  the exe name and the `avares://<assembly>/` resource URIs.

## Layout that split well

One console project (`src/<App>/<App>.csproj`) with one folder and namespace per module,
one test project (`tests/<App>.Tests/`) with the same folders, a solution file at the
root, `dotnet restore` as setup and `dotnet build && dotnet test --no-build` as the
whole-project check. New `.cs` files are picked up by the SDK globs, so no task needs to
edit a project file and nothing has to go in `settings.shared` except
`**/packages.lock.json` as a safety net.
