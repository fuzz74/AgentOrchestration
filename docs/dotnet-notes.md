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

**The fix:** append `-- RunConfiguration.TreatNoTestsAsError=true` to every per-module
`dotnet test`. A filter that matches nothing then exits 1. Two filters join with `|`, as in
`"FullyQualifiedName~A|FullyQualifiedName~B"`. This was verified with xunit 2.9.3, VSTest 18.10.1
and SDK 10.0.302, and used for every task of Example Project J (below). The planner quoted the
separator as `'--'`, so every PowerShell version passes it through.

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

### Example Project L: Avalonia with SkiaSharp drawing, speech output and runtime CLI calls

Found while building Example Project L (October 2026, .NET SDK 10.0.302, C# 14): a new Avalonia 12
desktop app. A custom control draws with SkiaSharp, NAudio plays System.Speech audio, and the app
calls the Claude Code CLI headless at runtime. The user named SkiaSharp, Silk.NET and NAudio as
candidates and left the choice open, and asked for no involvement through `/auto-develop`.

**Run totals:**
- **Spec:**
  - About 1,500 lines and 13 modules, two thirds of it written-out contract code. It was written
    without an interview.
  - CLI behaviour, speech timing and the Avalonia rendering path were checked with probes before
    the spec relied on them.
  - The contract blocks were copied out of the spec and compiled in a scratch skeleton.
  - Two cold reviewer passes, of 10 and 15 minutes, found 4 and 3 blocking issues.
- **Skeleton and planning:** bootstrap by Opus, 1.16 USD. The planner (Opus at `-Effort medium`)
  made 17 tasks in 5 minutes, for 1.24 USD.
- **Build:** Opus workers and reviewers with `-MaxParallel 6`, 94.03 USD and 2 hours. Every task
  merged on its first attempt, with no review rejections, merge conflicts or failed integration
  checks.
- **Result:**
  - 94 source files (8.8K lines) and 114 test files (12.6K lines);
  - 935 tests plus 2 opt-in live tests, which passed against the real CLI;
  - 0 warnings.
  - A live check of the built exe through UI Automation found nothing to fix.

**Avalonia instead of Silk.NET when the app is mostly forms.** Text editing, lists, tabs and
numeric fields come with Avalonia, and it renders with SkiaSharp anyway. Avalonia 12.1.4 pins
`SkiaSharp` 3.119.4, so the drawing library must reference that same version.

**Custom Skia drawing in Avalonia 12, checked by a probe:**
- `context.Custom(ICustomDrawOperation)` gives a direct `SKCanvas` through
  `ImmediateDrawingContext.TryGetFeature<ISkiaSharpApiLeaseFeature>()`.
- It works in headless tests with `.UseSkia().UseHeadless(new AvaloniaHeadlessPlatformOptions {
  UseHeadlessDrawing = false })`.
- `Window.CaptureRenderedFrame()` returns a `WriteableBitmap` in **Rgba8888**, not BGRA. Read
  `Format` from the lock before you index the bytes.
- Compute the per-frame state on the UI thread in `Render(DrawingContext)` and hand immutable values
  to the draw operation, which runs on the render thread.

**xunit.v3 3.2.2 facts:**
- `-- RunConfiguration.TreatNoTestsAsError=true` makes a `--filter` that matches nothing exit 1,
  as with xunit 2.
- The package adds no global `using Xunit;`. The skeleton needs `<Using Include="Xunit" />` in each
  test project.

**System.Speech word timings are scaled wrong when the output is a stream.**
- With `SetOutputToAudioStream`, `SpeakProgressEventArgs.AudioPosition` is off by a factor that
  depends on the sample rate: about 1.15 at 22,050 Hz, 0.84 at 16 kHz and 2.31 at 44.1 kHz. The last
  word started "after" the end of the audio.
- All events have arrived by the time a synchronous `Speak` returns.
- The spec had a calibration step: map the reported times linearly onto the span from the first
  to the last non-silent frame of the audio envelope. Word timings then matched the audio in the
  live check.
- NAudio 2.4.0's `SmbPitchShiftingSampleProvider` (in `NAudio.Core`) gives one SAPI voice several
  distinct pitches. Only two SAPI voices were installed, against three in the OneCore registry.

**What the reviewer passes caught:**
- Pixel-difference thresholds stated as a share of the whole image cannot be met by small features.
  A shape about 13 px across cannot change 0.5 % of a 256 px image. The fix was to measure small
  features inside their own box.
- No line said that one audio player instance is shared. If the composition root had built two,
  the reader of the position would have watched an idle player, and every test (all with fakes)
  would still have passed.
- A timing requirement for one module that named a class from a module built in parallel.
- Settings loaded twice: the second load would have cleared the "bad file" warning set by the first.
- No module was told to create the log, work and output folders. A missing working directory makes
  `Process.Start` throw `Win32Exception`, which the client would have reported as "CLI not found".
- Shared test fakes described in prose only. Later page tasks needed exact members (the engine
  instance the factory created, a settable `Position`). Only the contracts task could edit the
  fakes, so the spec wrote out a table of fakes and their members, and contracts tested them.

**The planner split modules by file-name prefix again.** Three modules each became two tasks with
`owns` such as `ModuleA/Generator*.cs` and `ModuleA/Tools*.cs`. It also split a module into a
"support" task and an "engine" task that owns the whole folder and depends on the first. Every
split merged without conflicts.

**Live check through UI Automation.**
- Avalonia exposes `x:Name` plus `AutomationProperties.AutomationId` to UIA.
- From Windows PowerShell 5.1, these drove the whole flow: `InvokePattern` on buttons,
  `SelectionItemPattern` on tab items, and `ValuePattern` to read and set text.
- `PrintWindow(hwnd, hdc, 2)` captured the Avalonia window cleanly at 250 % scaling.
- The check lowered the speech volume in its own `--data-dir` settings first, because the app
  speaks out loud.

### Example Project L, follow-up round: a local neural voice engine with no human involvement

A second run on the finished Example Project L repo did two things:
- it replaced the SAPI speech with a local neural text-to-speech model, which the app downloads on
  first use;
- it added a progress indicator to every wait.

The user asked for a spec that starts with an investigation of the free options, and for no
involvement (`/auto-develop`).

**Run totals:**
- **Spec:**
  - 613 lines and 9 modules, written without an interview.
  - It opens with the investigation. Twelve free options were compared from published benchmarks,
    and the top candidates were measured on the target PC before the spec relied on them.
  - The contract code was compiled in a scratch clone, and the whole existing suite was run against
    it. Exactly the 2 tests that the spec named as broken failed.
  - Two reviewer passes: the first found 1 blocking issue (below), the second none.
- **Planning:** Opus at `-Effort medium` made 9 tasks in 2 minutes, for 0.60 USD.
- **Build:** Opus workers and reviewers with `-MaxParallel 4`, 34.16 USD and 46 minutes. Every
  task merged on its first attempt, with no review rejections.
- **Result:**
  - 66 files changed (+6.1K lines);
  - 329 new tests, 1,262 in all, plus opt-in live tests;
  - 0 warnings.
  - A live check through UI Automation with a fresh `--data-dir` found nothing to fix. It covered
    the real 350 MB download and a short session that spoke through the new engine.

**Local neural TTS from .NET: Kokoro-82M through sherpa-onnx.**
- `org.k2fsa.sherpa.onnx` 1.13.8 (Apache-2.0) runs Kokoro, Piper, Kitten, Pocket TTS and
  Supertonic models from C# through one API: `new OfflineTts(config)`, then
  `Generate(text, speed, speakerId).Samples` (24 kHz floats for Kokoro).
- Measure both model variants before you pick the small one:
  - on an AMD Ryzen AI 9 365, fp32 Kokoro ran at a real-time factor of 0.20 with 4 threads;
  - the int8 model was 3 times slower (0.59).
- The model is a 350 MB `.tar.bz2` release asset. SharpZipLib's `BZip2InputStream`, read by
  `System.Formats.Tar.TarFile.ExtractToDirectory`, unpacked it in 15 s.

**The sherpa-onnx package copies native libraries for 9 platforms into every bin folder (251 MB
each).**
- `ExcludeAssets="all"` on the runtime packages, set in the library project, does not carry over
  to the projects that reference it. The app and test projects still got all 9.
- What worked for every project: one `PackageReference` per unwanted RID in
  `Directory.Build.props`, such as
  `<PackageReference Include="org.k2fsa.sherpa.onnx.runtime.linux-x64" Version="1.13.8" ExcludeAssets="all" PrivateAssets="all" />`.
  The output dropped to 22 MB, with win-x64 only.
- `RuntimeIdentifier` was not an option, because it breaks test projects (see the traps above).

**A bad model configuration crashes the process instead of throwing.**
- With a missing or garbage model file, `new OfflineTts(config)` logs "Errors in config" and keeps
  a null native handle.
- The first call on that handle is an access violation (`0xC0000005`) that kills the process. No
  `catch` stops it.
- A truncated model file instead throws a catchable `SEHException` from the constructor.
- What the spec told the worker to do:
  - check the files first;
  - read the private `_handle` field (`HandleRef`) by reflection right after construction;
  - refuse a null handle, with `GC.SuppressFinalize` on the instance.
- Default tests reach these paths only through a seam, because building the real wrapper over fake
  files can crash the test host.

**What the reviewer passes caught:**
- A list of required model files was defined in the installer module, but the engine module,
  built in parallel, needed it too. The list moved into the contracts. This is the same pattern as
  the class named across parallel modules in the first run.
- The spec's verification table escaped the filter separator as `\|`. A planner copying it
  literally would have passed `\|` to VSTest. The commands moved out of the table, and the planner
  wrote bare `|` filters that all matched.

### Example Project L, second follow-up round: changing what a runtime LLM call writes

A third run on the same repo changed the style of the text the app gets back from its runtime
`claude -p` calls. It had three parts:
- new default prompt texts;
- a deterministic check of earlier output that adds hints to the next call;
- an upgrade of saved settings files that still held the old defaults.

The user asked for a thorough look at free tools first, and for no involvement (`/auto-develop`).

**Run totals:**
- **Spec:**
  - 430 lines and 5 modules, written without an interview.
  - The new prompts were probed against the real CLI first: old against new, on fixed inputs and
    seeds, scored with simple counts. The probes cost about 3 USD of CLI usage.
  - The contract code was compiled in a scratch clone and the whole suite run against it. That
    found a test break the spec had missed (below).
  - Two reviewer passes: the first found 1 blocking issue, the second none.
- **Planning:** Opus at `-Effort medium` made 5 tasks in 1 minute, for 0.35 USD.
- **Build:** Opus workers and reviewers with `-MaxParallel 3`, 12.62 USD and 30 minutes. Every task
  merged on its first attempt, with no review rejections.
- **Result:**
  - 21 files changed (+1.5K lines);
  - 106 new tests, 1,367 in all;
  - 0 warnings.
  - The new opt-in live test passed against the real CLI on its first run.

**A default text change can break no test outside its module.** Some existing tests asserted
phrases of the old default texts: a first sentence, and a lowercase "never more than N words". The
spec kept those phrases word for word in the new texts. The tests that asserted the replaced
sentences were named one by one and given to the module that changed them.

**A new settings property needs its control in the same task.** The settings page tests require
two things of every settings property: a control, and a value in the "edited" sample that differs
from the default. Adding only the property failed two App tests. The scratch build showed this; the
spec had not. The property, its checkbox and the App test updates were merged into one module.

**Upgrading saved copies of old defaults.** The app saves every prompt template into its settings
file, so new defaults never reached existing users. The upgrade:
- replaces a stored template that equals an old default, after normalizing `\r\n` to `\n` and
  trimming;
- keeps any template the user edited.

The spec did not paste the old texts. It named the commit to copy them from
(`git show <commit>:<path>`), and the worker read them from history in its worktree.

**Prompt probes run in parallel need their own temp files.** Two probe runs wrote the system prompt
to the same temp file, and calls read each other's prompts. Output for one input set showed up in
the other. Use a unique file per call, or run the probes one after another.

**What the reviewer passes caught:**
- The live test would have hung on any CLI error. The engine pauses on a failed turn and waits for
  Resume, so it never raises the "finished" event the test waited for. The spec now says to listen
  for the pause event, stop and fail with its message, with a 10-minute limit.
- The test plan helper turns transcripts off. A live test built on it would have written no
  transcript, with no test failing.

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

### Example Project G, follow-up round: a feature added with no human involvement

A second run on the finished Example Project G repo added a front-end layer drawn over the
existing display and a small JSON file store. The user again asked for no involvement.

**Run totals:**
- **Spec:** 411 lines and 7 modules, written without an interview. Two reviewer passes: the
  first found 1 blocking issue (below), the second none.
- **Planning:** Opus at `-Effort medium`, 7 tasks in 1.5 minutes, 0.44 USD. No skeleton was
  needed: `project.json` supplied the setup and check commands.
- **Build:** Opus workers and reviewers with `-MaxParallel 4`, 24.27 USD and 38 minutes. Six
  tasks merged on their first attempt, one on its second.
- **Result:** 44 files changed, 330 new tests (2,315 in all), 0 warnings, and two hand commits
  after the run (below).

**A replaced signature needs its callers in the same module.** The spec gave a public entry
method new arguments in one module. Its only caller sat in a file owned by a later module, so
the first module could not have built. The reviewer caught it. The fix was to add the caller's
file to the first module's paths; the later module depends on it, so it may still edit the file
afterwards. The write-spec self-review now checks for this.

**Follow-up spec ids.** The code and test names cited the first spec's ids (`2.3`,
`Req11_2_...`). The new spec numbered its areas from 13 and said so in its summary. Workers
named their tests after the new ids, and none confused the two.

**System.Text.Json: catching `JsonException` is not enough.** A string escape holding a lone
UTF-16 surrogate (`"\udc00"`) passes UTF-8 validation and `JsonDocument.Parse`.
`JsonElement.GetString()` then throws `InvalidOperationException`, and so can property lookups
that unescape names. A loader that must never throw on a bad file has to catch both. The reviewer
found this, rejected the first attempt, and the retry fixed and tested it.

**What the run missed and the checks after it found:**
- A panel rectangle that the spec fixed in its contracts covered an existing on-screen element.
  The module's test renders showed it before the merge. A hand commit on `orch/integration`
  moved the rectangle and regenerated the README image.
- No module owned the headline behaviour end to end: a value saved by the real store surviving
  a restart through the real UI layer and engine. Each module tested its part with fakes, and
  the wiring module used an in-memory store. A hand-added test with a temp folder closed the gap.
  **For specs:** give the last wiring module one end-to-end test of the headline behaviour
  across the real modules.
- A live check drove the built window with `SendInput`. The first scripted run lost two key
  presses. A rerun with a 400 ms pause after each key, and a `GetForegroundWindow` check before
  each one, delivered every key; the window had focus each time, so the cause stayed unclear.

**`Complete-Orchestrator.ps1` stopped half way.** The assistant's shell had used a task's log
folder as its working directory, and a monitor still tailed `progress.md`. The script removed
the worktrees and branches, then failed to move the locked folder. The rest was moved by hand;
README step 7 now says how.

### Example Project G, second follow-up round: a large feature with no human involvement

A third run on the same repo added a second presentation layer that can be switched at runtime:
new rendering and audio modules that read only the core's public output, plus a small settings
file. The user again asked for no involvement, and this time also for the result to be pushed.

**Run totals:**
- **Spec:** about 1,000 lines and 12 modules, well over the write-spec guide of 8 modules and
  400 lines, written without an interview. Two cold reviewer passes of about 16 minutes each found
  3 and 2 blocking issues (below).
- **Planning:** Opus at `-Effort medium`, 20 tasks in 4 minutes, 0.94 USD. No skeleton was needed.
- **Build:** Opus workers and reviewers with `-MaxParallel 5`, 148.05 USD and 2 hours 45 minutes.
  Every task merged on its first attempt.
- **Result:** 89 source files (12.8K lines) and 99 test files (16.2K lines), 1,256 new tests
  (3,571 in all), 0 warnings. A live check of the built app found nothing to fix.

**Check the spec against the code before review.**
- The contract code was copied from the spec into a scratch clone of the repo and built
  (0 warnings), with a few contract tests. Later spec edits were checked the same way, by copying
  each code block back out of the spec.
- The new layer infers the core's state from its public output, so the spec's inference rules
  were checked against the real core with a throwaway test before planning: every rule matched over
  12 minutes of play.
- The same probe showed that the scripted test player never lost. The test kit therefore got a
  switch to stop the player, which the failure-state renders needed.

**What the reviewer passes caught:**
- A latched state that a one-frame transition skipped. The fix was to also clear it on a second
  signal that the old state never shows.
- A cache key that two parallel modules could read two ways. The fix was to name the exact value
  in the contract.
- A text size that its panel's margins could not hold.
- The number of existing tests a changed signature breaks was undercounted. The spec listed two to
  replace; the real number was three.
- A module split in the build order without requirement ids for each part.

**Large modules became task chains.** The planner split six modules into tasks that run one after
another and own the same paths: three tasks for one module, two each for five others. That gave
20 tasks for 12 modules, and none needed a retry.

**Timing guards.** Each timing test got its own `DisableParallelization` collection with a
distinct name, and loose limits meant only to catch runaway cost. None failed across the 20
integration checks, which ran while up to five agents built in parallel.

**Watching a run from the assistant.** A `Monitor` on `progress.md`, grepping
`DONE and merged|FAILED|review rejected|Run finished`, gave one event per merge. Each monitor
expires after 30 minutes and has to be re-armed. Looking at each module's render sheets as it
merged was a cheap early check of the art.

**Live check notes.**
- The `SendInput` scancode script from Example Project G worked first time. Under Windows
  PowerShell 5.1, write `[UInt16]`; `[ushort]` is not a type accelerator there.
- The check toggled a per-user setting, which created the app's settings file. It was deleted
  afterwards so that the next real launch behaves like a first launch.

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

## WinForms notification-area apps

Found while building Example Project I (October 2026, .NET SDK 10.0.302, C# 14): a small
WinForms app with a `NotifyIcon` and no main window. It polls a public HTTP API and shows
balloon notifications. The user asked for no involvement beyond granting folder access.

**Run totals:**
- **Spec:**
  - 806 lines and 9 modules, written without an interview.
  - Facts about the external API were checked with live requests while writing.
  - The contract code was compiled in a scratch copy of the skeleton before review.
  - Two cold reviewer passes, 9 and 11 minutes, found 4 and 3 blocking issues.
- **Planning:** Opus at `-Effort medium`, 9 tasks in 2 minutes, 0.52 USD. There was no bootstrap
  (see the next point).
- **Build:** Opus workers and reviewers with `-MaxParallel 6`, 37.88 USD and 66 minutes. Every
  task merged on its first attempt.
- **Result:** 49 source files (2.5K lines) and 42 test files (4.3K lines), 395 tests in about
  1 s plus 3 opt-in live tests, 0 warnings. The framework-dependent single-file exe is 518 KB.

**A repo with commits but no project gets no skeleton.**
- `Initialize-Project.ps1` skips any repo that has commits. This one held only a reference doc;
  earlier code had been removed in a commit.
- The skeleton was built by hand instead, in a scratch folder: solution, `Directory.Build.props`,
  both project files, a smoke test, `.gitignore` and a README.
- The 4.3 contract blocks were compiled into that copy, the files were committed, and the setup
  command and whole-project check passed in a clean worktree. Then `.orchestrator/project.json`
  was written by hand.

**Live API checks found what fakes cannot.** Every module test used a fake HTTP handler. So:
- The first cold reviewer sent the spec's query document to the real API. The API rejected it
  whenever an optional part went unused: GraphQL fails validation on an unused fragment. That
  is the default configuration, so every poll would have failed while every test passed.
- The same reviewer found that matching on a realtime identifier dropped an item whenever that
  identifier changed. Matching on the scheduled identifier fixed it.
- **For specs:** give a module that talks to an external API a few `[LiveFact]` tests (skipped
  unless an environment variable is set). Ask its task to run them once, and run them again
  after the build.

**`FakeTimeProvider` keeps the offset it is given.**
- `new FakeTimeProvider(DateTimeOffset.Parse("...+02:00")).GetUtcNow()` returns the `+02:00`
  offset. The real clock returns offset zero.
- A key built with `:O` from such a time differed from one built from the same instant in UTC.
  The scratch compile of the contracts caught it.
- **For specs:** call `.ToUniversalTime()` in the test clock helper, and build keys from UTC.

**`NotifyIcon` balloons need a visible icon.** `ShowBalloonTip` does nothing while `Visible` is
false. As first written, the spec loaded settings and showed the first-run notification before
showing the icon. The second reviewer pass caught it. Also give the tray class a `Visible`
property in the contracts, so tests can build it without putting an icon on the user's taskbar.

**Requirements that tests cannot check.**
- Docs and visual requirements met "every id needs a named test" and would have reported
  blocked.
- **For specs:**
  - Mark those parts "(checked by review)".
  - Give the docs module a test folder for the mechanical checks: paths that exist, exact file
    contents, required phrases.
  - Number non-functional criteria like the rest (10.1, not N.1), and say which of them only
    the build or the whole-project check verifies.

**Keep the spec in the target repo.** Code comments and test names cite requirement ids. The
docs task wrote "the spec is not in the repo", so the spec was copied to `docs/specs/` and the AI
guide was pointed at it.

**Watching and checking.**
- **Monitor filter:** `progress.md` heartbeat lines quote the agent's latest command, so a grep
  for `error` fired on a heartbeat. Drop lines with ` tool calls, last:` first.
- **Screenshots:** crop live-check screenshots to the notification area. A full-screen capture
  also picks up the user's other windows.
- **A missing notification that was not a bug:** the external data had moved the event's time
  by two minutes, so it arrived one poll later. Check the data before suspecting the code.
- **Folder access:** after the user approved it through a question, adding the target folder to
  `settings.local.json` worked in auto mode and took effect at once. Compare Example Project H,
  where the same edit was refused.

### Example Project I, follow-up round: a window added to a tray app with no human involvement

A second run on the finished Example Project I repo added three things through `/auto-develop`:
- a notification that repeats on a timer;
- per-item states (enabled in the settings file, muted in memory);
- a WinForms main window with three tab pages, opened from the tray.

The target folder was already in the session's directories, so no access step was needed.

**Run totals:**
- **Spec:**
  - About 630 lines and 9 modules (contracts included), written without an interview.
  - The contract code was copied out of the spec into a scratch clone and built. All existing
    tests still passed.
  - Two cold reviewer passes of about 8 minutes each found 2 and 5 blocking issues (below).
- **Planning:** Opus at `-Effort medium`, 12 tasks in 3.5 minutes, 0.83 USD. The repo had no
  `project.json`, so `-Setup` and `-IntegrationCheck` were passed by hand.
- **Build:** Opus workers and reviewers with `-MaxParallel 6`, 25.46 USD and 56 minutes. Every
  task merged on its first attempt.
- **Result:** 65 files changed (+5.8K lines), 234 new tests (629 in all), 0 warnings. One hand
  fix followed a live check of the built window (below).

**A follow-up's contracts task carries the compile fixes.**
- A renamed interface event and a new interface member broke every implementer and fake.
- The spec listed each file and the minimal edit it needed (rename the event, add a throwing
  stub, add a recording fake method) in the contracts module's paths.
- The contracts task left the whole-project check green. The owning modules then replaced the
  stubs.

**New module folders against the docs tests.**
- The repo's docs tests require the AI guide to name every module folder, and every path the guide
  names to exist. So the first merge of a new folder, or of a guide row for a folder not created
  yet, fails the integration check, and the merge is undone.
- The contracts task created each new folder with a real first file: the module's texts class and
  its test.
- It also added the guide rows. The docs task completed them last.
- The spec copy in `docs/specs/` was committed to the base branch before planning, because the
  docs task had to name it and no task may edit it.

**What the reviewer passes caught:**
- The user defined a state word that an existing method already used with a wider meaning. A
  worker reusing that method would have notified outside the intended time range and broken
  existing end-to-end tests. The fix was to define the word against the code and require tests at
  both edges.
- The spec did not say whether a muted item is still polled.
- Pages marshalled background events through their own window handle. Tab pages that were never
  shown have no handle, so their updates would be dropped. The fix was to capture the WinForms
  `SynchronizationContext` in each page's constructor and `Post` to it.
- `NumericUpDown.Maximum` defaults to 100, and setting a larger `Value` throws, so each field's
  range has to be in the spec.
- The first pass found that the window module could not be split along the surface the spec
  offered. The fix was to fix the internal page constructors and action methods, make the form task
  depend on the page tasks, and put a shared `Sta.PumpUntil` helper in TestSupport. The planner
  then ran three page tasks in parallel.

**A layout bug that every test missed.**
- All the window tests built forms that were never shown. A throwaway harness then referenced the
  built dll and opened the real window against the live API.
- On the Settings tab, the time pickers and number fields were 0-1 px wide. A `TableLayoutPanel`
  lays out a hidden tab page while its cells are tiny. It shrinks controls that are anchored only
  `Left`, and they never grow back. Text boxes anchored `Left | Right` recover.
- The fix was `MinimumSize` on those fields. A regression test calls `CreateControl()` and
  `PerformLayout()` on the never-shown form, selects the tab and checks the widths. It fails
  without the fix.
- **For specs:** ask the window module for one such layout test per tab.

**Tooling notes:**
- `Graphics.CopyFromScreen` returned black images from the assistant's shell. `Form.DrawToBitmap`
  worked, and so did dumping control bounds to a file.
- The Bash tool, and with it the `Monitor` tool, could not start (`EPERM` spawning `bash.exe`).
  A background PowerShell loop that exits on the next `DONE and merged`, `FAILED` or
  `Run finished` line of `progress.md` replaced it. The loop was re-armed after each event.

### Example Project I, second follow-up round: four small window features with no human involvement

A third run on the same repo added four small features through `/auto-develop`: a button state
that follows unsaved edits, hover hints on every setting, a read-only help tab, and a second kind
of snooze. The target folder was already in the session's directories.

**Run totals:**
- **Spec:** 456 lines and 6 modules, written without an interview, about 120 lines of it
  user-facing text. The contract code was built in a scratch clone first: 0 warnings, and every
  existing test still passed. Two cold reviewer passes of 8 and 10 minutes found 3 and 2 blocking
  issues (below).
- **Planning:** Opus at `-Effort medium`, 6 tasks in 1.5 minutes, 0.50 USD. The repo had no
  `project.json`, so `-Setup` and `-IntegrationCheck` were passed by hand.
- **Build:** Opus workers and reviewers with `-MaxParallel 4`, 11.05 USD and 18 minutes. Every
  task merged on its first attempt.
- **Result:** 19 files changed (+1.5K lines), 64 new tests (693 in all), 0 warnings. A live check
  of the built window found nothing to fix.

**User-facing text written out in the spec.** The hints and the help text went into the contracts
as verbatim constants of the texts class. The contracts task wrote them, so the three page tasks
never touched that file and ran in parallel. The reviewers checked the text against the code like
any other contract and found three wrong statements: a status said to repeat until the window ends
(it stops once no train is left), a start time true only on some days, and a benefit of a setting
that another setting already gave.

**What the reviewer passes caught:**
- Per-module test filters with `|` inside a markdown table were written as `\|`. Copied literally,
  `dotnet test --filter` gets an escaped pipe, not an OR. Put filters in a fenced block.
- "Enable Save when the user types in a number field" also fires on the page's own updates:
  setting `NumericUpDown.Value` raises `TextChanged` too. The rule had to exclude the page's own
  updates and add re-check points.
- Setting `NumericUpDown.Text` commits the value at once, so a test that sets it never simulates
  typing. Setting the inner edit box (`field.Controls.OfType<TextBox>().Single().Text`) does: it
  raises `TextChanged` with no `ValueChanged` until `Value` is read.
- A layout test for a new tab could not pass on a never-shown form. Until the `TabControl` has a
  handle, every `TabPage` stays 200 x 100 px. An older layout test had passed only because of a
  `MinimumSize`. **For specs:** have tab layout tests create the tab control's handle first
  (`_ = form.Tabs.Handle`).

**Live check notes.**
- A throwaway WinForms project with a `ProjectReference` to the built app created the internal
  form by reflection. It showed the form at `Opacity` 0.01 and drove the internal action methods.
  That gave real layout without a visible window.
- After switching tabs, `Form.DrawToBitmap` returned the previously drawn tab. Calling
  `DrawToBitmap` on the page control itself worked.
- In the assistant's PowerShell, `Set-Content -NoNewline` was rejected as an unknown parameter.
  `[IO.File]::WriteAllText` worked.

## WPF and WebView2 desktop apps

Found while building Example Project J (October 2026, .NET SDK 10.0.302, C# 14): a new WPF desktop
app that hosts several WebView2 controls in one window. The user asked for no involvement through
`/auto-develop`, then added one feature by message while the spec was being written.

**Run totals:**
- **Spec:**
  - 1,417 lines and 11 modules, well over the write-spec guide, written without an interview. Most
    of the length is written-out contract code (types, view-model surfaces, a command table).
  - API facts were checked against the XML docs in the unpacked NuGet package before writing them
    into the spec.
  - The contract blocks were compiled in a scratch project, and again in a clone of the skeleton.
  - Two cold reviewer passes, 11 and 14 minutes, found 6 and 5 blocking issues (below).
- **Skeleton:** bootstrap by Opus, 1.27 USD. Its instructions were written out in spec section 6:
  four projects, a placeholder `App.xaml` for the shell module to replace, and a conditional
  `ApplicationIcon`.
- **Planning:** Opus at `-Effort medium`, 21 tasks in 6 minutes, 1.31 USD.
- **Build:** Opus workers and reviewers with `-MaxParallel 5`, 118.20 USD and 3 hours. Every task
  merged on its first attempt, with no review rejections and no merge conflicts.
- **Result:**
  - 90 source files (8.4K lines) and 103 test files (17K lines);
  - 1,078 Core and 403 App tests, plus 21 opt-in live tests against the real runtime;
  - a two-phase smoke run of the real exe, about 5 s;
  - 0 warnings.

**Versions:** `Microsoft.Web.WebView2` 1.0.4258.31 (runtime 155) and `CommunityToolkit.Mvvm` 8.4.2
(explicit `SetProperty`, no source generators), with the xunit 2.9.3 set above.

**WebView2 shows its own modal dialog when its user data folder is unusable.**
- A live test that started WebView2 on a file path (`<temp>\not-a-folder`) raised a native
  "couldn't create the data directory" message box on the user's desktop. So did a throwaway probe
  with invalid path characters. Two of the three boxes outlived their test host and stayed up.
- `--noerrdialogs`, which WebView2 already passes, does not suppress it. In an unattended run nobody
  clicks OK.
- The worker's final test fails the start another way: a second environment with different browser
  arguments on the same folder. That raises no dialog.
- **For specs:** say how tests simulate an engine start failure: conflicting environment options,
  or an injected environment factory. Forbid unusable data folders.
- **During the run:** a watchdog killed only `msedgewebview2.exe` processes that a test host
  started (`--webview-exe-name=testhost.exe`, no `--type=`) and whose data folder was invalid or
  whose test host was gone. It exited on `Run finished`. The first version checked only for a
  file in the path. It missed a dialog whose test had already deleted its temp folder.

**The WPF control closes its host window on `window.close()`.** Its private handler answers a
page's `window.close()` by closing the WPF `Window` that contains the control. With several
controls in one window, every one of them goes. The engine worker found this with a live test and
removed the handler by reflection on its private name. A unit test fails if a package update
renames it. **For specs:** say what `window.close()` should do.

**Other WebView2 and WPF facts that held:**
- Accelerator keys pressed inside a WebView2 arrive as WPF `PreviewKeyDown`/`KeyDown`, and
  `Handled = true` suppresses the browser's own action. One window-level handler therefore routes
  shortcuts from pages and from WPF controls alike.
- A page handed to `NewWindowRequested.NewWindow` must not have navigated. A deferral covers the
  wait while its control loads. A script `click()` on a `target=_blank` link raised the event with
  no popup blocking.
- A collapsed WebView2 in a loaded window still initializes. The live test asked for in the spec
  confirmed it.
- Placing every control on a `Canvas` at rectangles from a pure arranger meant no control was ever
  re-parented when the layout changed. The arranger got property tests over random layouts.

**WPF projects drop `System.IO` and `System.Net.Http` from implicit usings**
(`Microsoft.NET.Sdk.WindowsDesktop.WPF.props`). Core test-support files were also compiled into
the WPF test project as linked `Compile` items, so the spec required `using System.IO;` in them.
None failed.

**What the reviewer passes caught:**
- No module owned the view side of two states that hide part of the window.
- A restart after an engine crash would have handed off to the dying single instance. The old
  process still held the mutex, so the new one would have sent its arguments there and exited.
- A user-folder default named in the requirements, where the services record held an injectable
  folder. Tests would have written to the real Documents folder.
- A contracts check that matched no test in one of the two test projects.
- A view module that used an asset without depending on the module that makes it.
- A status message that no view showed.
- An icon reproducibility check (`git diff`) that could not fail on new files.
- A suggested partial-class split that left the command dispatch half-wired.
- Change notifications for computed view-model properties that were not part of the contract.

**Re-planning the critical path.** The planner made all three view tasks wait for the last of
four chained view-model tasks: 11 waves. The views needed only the view-model surface from the
contract, plus behaviour from the second chain task. The plan was edited before the run: views
start after the second task, the shell depends on the last one explicitly, and each view prompt got
a note not to test command side effects that later tasks finish. That made 9 waves. Both view tasks
merged first time.

**Live check notes.**
- PowerShell resolves the alias `Type` (`Get-Content`) before a script function of that name, so a
  `Type` helper for `SendKeys` silently did nothing. Name such helpers `SendText`.
- A fixed 1 s pause before answering a confirmation box raced the box: the Enter went to the
  window instead, and a later file dialog never got its keys. Check `GetForegroundWindow` before
  typing into a dialog.
- `Graphics.CopyFromScreen` worked from Windows PowerShell 5.1 with `SetProcessDPIAware`, unlike
  in Example Project I.
- `--data-dir` covered every app file except the default folder for user documents, which sits in
  Documents. The live check's first save created that folder in the user's OneDrive Documents, and
  deleting it from the assistant's shell was denied. **For specs:** give every default folder the
  app writes a test override.
- Before an overnight unattended run, check that the machine will not sleep:
  `powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE`. Here, mains power was set to never sleep.

## WPF and AvalonDock docking apps

Found while building Example Project K (October 2026, .NET SDK 10.0.4xx, C# 14): a new WPF desktop app
with a Visual Studio-style docking workspace and an external REST API behind a sync layer. The user
asked for no involvement through `/auto-develop`.

**Run totals:**
- **Spec:**
  - About 2,160 lines (half of it compiled contract code and the project files) and 16 modules,
    with 167 criteria. It was written without an interview.
  - Research subagents checked the API facts. Small probe programs checked the docking library's
    behaviour before the spec relied on it.
  - Two cold reviewer passes, of 7 and 8 minutes, found 10 and 4 blocking issues.
- **Skeleton and planning:** bootstrap by Opus, 1.27 USD. The contract code was then compiled in a
  clone of the skeleton. The planner (Opus at `-Effort medium`) made 29 tasks in 6.5 minutes, for
  1.63 USD.
- **Build:** Opus workers and reviewers with `-MaxParallel 5`, 186.57 USD and about 4 hours,
  including two hand fixes (below). 28 tasks merged on their first attempt; one needed a second after a
  quality rejection.
- **Result:** 202 source files (20.8K lines) and 225 test files (23.8K lines), 1,659 tests plus 4
  opt-in ones, 0 warnings. A `--smoke-test` mode of the real exe passes in 9 s.

**Versions:** `Dirkster.AvalonDock` and `Dirkster.AvalonDock.Themes.VS2013` 4.74.1 (5.0 existed but
was skipped: models know the 4.x API), `CommunityToolkit.Mvvm` 8.4.2 (explicit `SetProperty`),
`Microsoft.Identity.Client` 4.90.1, `HtmlAgilityPack` 1.12.4, plus the xunit 2.9.3 set above.

**AvalonDock facts that a probe confirmed before the spec relied on them:**
- To let every pane dock anywhere, make every pane a `LayoutAnchorable` with
  `CanDockAsTabbedDocument = true`. An anchorable may sit in a `LayoutDocumentPane`. A
  `LayoutDocument` can never dock in a side pane.
- With `AnchorablesSource` bound, restoring a layout in `XmlLayoutSerializer.LayoutSerializationCallback`
  neither duplicates nor leaks panes. The callback adds the view model to the bound collection and sets
  `e.Content`, or sets `e.Cancel` to drop the entry. The spec gave this pattern as code, and the shell
  task built it first time.
- New panes go through an `ILayoutUpdateStrategy` whose `BeforeInsertAnchorable` picks the container
  and returns true.
- AvalonDock 4.74.1 ships no XML docs. A ten-line probe program answered the API questions faster than
  reading.

**Off-screen test windows break when the display scale changes.**
- The test host showed windows at `Left = -20000` DIP. Windows clamps window positions to -32768
  physical pixels, so at 250 % scaling the window landed at -13107.2, and two tests that compared
  `Left` failed.
- Those tests had passed in every earlier integration check. The display scale changed during the
  run, and the next merge's integration check failed. The merge was undone and the task marked failed.
- The fix, by hand on `orch/integration` followed by `-RetryFailed`, was a shared
  `OffscreenLeft = -8000` constant, which is safe up to 400 % scaling.
- **For specs:** put off-screen windows at no more than about -8000 DIP, and compare against the same
  constant.

**Focus-triggered side effects make timing tests flaky.**
- An editor view saved its content on a 300 ms `TimeProvider` timer, and also at once on
  `LostKeyboardFocus`. A test that checked "not yet written at 299 ms" passed in its task, then failed
  once in a later integration check.
- The test's window is off screen and never activated, so it can lose keyboard focus to anything on
  the desktop, including other test processes.
- The fix was an internal "flush on focus loss" switch that the timing test turns off.
- **For specs:** give every focus- or activation-triggered behaviour a test switch, and state that
  timing tests turn it off.

**What the reviewer passes caught:**
- A round-trip property (`Parse(ToHtml(doc)) == doc`) that could not hold as the two mapping tables
  stood: some elements serialize to plain text or lose attributes. The fix was to write out what
  structural equality normalizes.
- A dialog view model whose implicit template had no dictionary to live in. Dialog windows look up
  templates in `Application.Resources`, not in the main window.
- A maximized-pane overlay that re-templates the same view model, which creates a second view
  instance. Unsaved editor content had to live in the view model, or it would be lost on restore.
- A project enum named `ThemeMode`, which clashes with WPF's `System.Windows.ThemeMode` (.NET 9+) in
  every file with `using System.Windows;`. It was renamed before any code existed.
- Test fixtures under a test folder that no task could copy to the output, because the project files
  were locked. The fix was a `<None Include="…\Fixtures\**" CopyToOutputDirectory="PreserveNewest" />`
  line in the skeleton.
- A view that is closable and reopenable through a factory, with no DI registration for the
  factory. The fix was to write out the exact `AddTransient` and `AddSingleton(sp => …)` lines.
- `HttpListener` with a `localhost` prefix rejects requests whose Host header is a tunnel's public
  name ("400 Invalid Hostname"). A webhook receiver behind a tunnel needs a small `TcpListener`
  server that ignores Host.

**The planner split modules by file-name prefix.** Inside one folder it gave tasks `owns` such as
`Sync/ChatStore*.cs` and `Sync/SyncEngine*.cs`, and those ran in parallel. A glob that starts with a
wildcard (`Organizer/*ItemViewModel.cs`) has the folder as its literal prefix, so it overlaps every
other task in that folder. Those tasks then run one after the other.

**Tooling notes:**
- Piping `Invoke-Orchestrator.ps1` into `Select-Object -Last N` made the background command exit 1
  with an `out-lineoutput` formatting error after a run that had finished cleanly. Read the run's
  result from `progress.md` (`Run finished: …`), not from that exit code.
- An unattended run on a laptop whose mains sleep timeout is 30 minutes was kept awake by a
  background PowerShell loop calling `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)`.
  It changes no settings, and the request ends with the process. The loop exits on the run's
  `Run finished` line.
- `Complete-Orchestrator.ps1` failed once because a worktree folder was in use. The task's
  processes were gone, and the only other dotnet processes belonged to the user's IDE. A rerun 20 s
  later archived the run but left one empty, still-locked folder in `<repo>.worktrees`.
- `PrintWindow(hwnd, hdc, 2)` from Windows PowerShell 5.1, with `SetProcessDPIAware`, captured the
  live WPF window with no other windows in the picture.
- WPF draws emoji in monochrome, because it has no colour-font support. Say so in the spec when
  emoji matter.

## MonoGame DesktopGL apps

Found while building Example Project M (October 2026, .NET SDK 10.0.302, C# 14). It is a new
desktop app built in two runs: a reusable engine first, then content on top of it. The user asked
for no involvement through `/auto-develop`, and named only the language.

### Example Project M, first run: the engine

**Run totals:**
- **Spec:**
  - About 1,940 lines and 13 modules. Two thirds of it is written-out contract code and module APIs,
    compiled in a scratch project and again in a clone of the skeleton. It was written without an
    interview.
  - The windowing library was probed before the spec relied on it: a window, texture upload,
    streamed audio and keyboard input through synthesized `SendInput`.
  - Two cold reviewer passes, of 16 and 15 minutes, found 11 and 7 blocking issues.
- **Skeleton and planning:** bootstrap by Opus, 1.10 USD. The planner (Opus at `-Effort medium`)
  made 26 tasks.
- **Build:** Opus workers and reviewers with `-MaxParallel 5`, 176.99 USD and 5 hours, including
  two stalls (below). 22 tasks merged on their first attempt, and 4 needed a second.
- **Result:**
  - 2,640 tests, 0 warnings.
  - A smoke-test mode of the real exe passes.
  - A live check drove the built window with `SendInput` and the app's own screenshot key, and
    found nothing to fix.

**MonoGame.Framework.DesktopGL 3.8.5.1 facts, checked by probes:**
- It runs on `net10.0`, although the package targets `net8.0`.
- `DynamicSoundEffectInstance.BufferNeeded` fires on the game thread, like `Update`.
- `Window.TextInput` also delivers Enter, Backspace, Tab and Escape as control characters, and
  Alt+Enter as `'\r'`. The host must drop control characters and take those keys from the keyboard
  state.
- A numpad digit with NumLock on arrives as a text event whose `Key` is `D8`, not `NumPad8`. To use
  the numpad for movement, drop the first text event of that digit in the same frame.
- A key held with synthetic `SendInput` produces no repeats, so the host repeats Backspace itself.
- A self-contained win-x64 publish, not single-file, is 196 files and 81 MB, and runs. The native
  files are `SDL2.dll` and `openal.dll`.
- A per-monitor-v2 DPI manifest keeps the window sharp on scaled displays.

**SDK 10.0.302 makes `.slnx` by default.** `dotnet new sln` now writes `<name>.slnx`, so every
command in a spec that names `<name>.sln` fails. The second reviewer found this. Write
`dotnet new sln --format sln` into the skeleton instructions.

**Spec changes after the run starts do not reach it.** The runner reads the spec and `tasks.json`
once, at start. While a story document was being written in parallel, it showed engine needs that
were folded into the spec between planning and the run:
- Each change was merged into an existing requirement id, so the planner's id ranges still covered
  it.
- A short "spec amendment" paragraph was appended to the prompt of every affected task.
Later needs were saved for the second run instead of restarting the first.

**Two tasks reported blocked because earlier tasks' tests pinned what later tasks change.**
- In the first case, a core task's tests asserted the behaviour of a stub that a later task
  replaced.
- In the second, a test asserted the exact list of discovered rooms, and a later task added one.
- Both workers stopped with the exact edit to make. Recovery for each:
  1. apply the edit in the task's worktree;
  2. run the task's acceptance check;
  3. commit the work on the task branch;
  4. add the test file to the task's `owns`;
  5. rerun with `-RetryFailed`. Each task then merged in sync mode on the first try.
- **For specs:** tell early modules not to pin stub behaviour, or exact sets that later modules
  extend. Or list the test files that later modules may edit.

**The review gate caught a copied font.** The spec asked for an original 8x8 font. The reviewer
compared the glyphs from memory with the IBM PC ROM font and found about 30 bit-identical ones. The
worker redrew them in its own squared style and passed on the second attempt.

**An art probe before the content spec.**
- One subagent drew one reference scene and one sprite with the engine's merged picture API, in
  five draw, look and improve rounds (20 minutes).
- Its rules went into the second spec as art rules, and its code and PNG were committed as the
  quality bar:
  - geometry constants first;
  - a black outline on everything;
  - one dithered plane at most;
  - no flood fill on dithers;
  - one shared box helper for all furniture.
- The probe's helpers became a small shared drawing kit that the core module builds first.

**Writing the story with a second model.**
- The user asked for the story to be written by a named model and to read as human-written.
- A writer agent produced the story document, and a second pass by the same model looked only for
  machine-sounding prose.
- The banned-word list was almost clean already. The real tells were structural:
  - sentences ending in ", which is [joke]";
  - the same joke in two rooms;
  - overworked punchline words.
- About 13 % of the lines changed.

**Tooling notes:**
- The keep-awake loop must exit on a *new* `Run finished` line. A resumed run appends to the same
  `progress.md`, and a loop that exits on any such line stops at once.
- In the Bash tool, a long heredoc that contained quotes sometimes failed with "unexpected EOF". Write such files with the
  Write tool and run them.
- Synthesized `SendInput` with `MapVirtualKey` scan codes drove the SDL window reliably, arrow keys
  included with the extended flag.

## Layout that split well

One console project (`src/<App>/<App>.csproj`) with one folder and namespace per module,
one test project (`tests/<App>.Tests/`) with the same folders, a solution file at the
root, `dotnet restore` as setup and `dotnet build && dotnet test --no-build` as the
whole-project check. New `.cs` files are picked up by the SDK globs, so no task needs to
edit a project file and nothing has to go in `settings.shared` except
`**/packages.lock.json` as a safety net.
