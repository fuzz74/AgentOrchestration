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

## Layout that split well

One console project (`src/<App>/<App>.csproj`) with one folder and namespace per module,
one test project (`tests/<App>.Tests/`) with the same folders, a solution file at the
root, `dotnet restore` as setup and `dotnet build && dotnet test --no-build` as the
whole-project check. New `.cs` files are picked up by the SDK globs, so no task needs to
edit a project file and nothing has to go in `settings.shared` except
`**/packages.lock.json` as a safety net.
