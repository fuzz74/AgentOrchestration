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

## Layout that split well

One console project (`src/<App>/<App>.csproj`) with one folder and namespace per module,
one test project (`tests/<App>.Tests/`) with the same folders, a solution file at the
root, `dotnet restore` as setup and `dotnet build && dotnet test --no-build` as the
whole-project check. New `.cs` files are picked up by the SDK globs, so no task needs to
edit a project file and nothing has to go in `settings.shared` except
`**/packages.lock.json` as a safety net.
