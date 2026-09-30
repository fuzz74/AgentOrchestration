# GitRepoMonitor

## 1. Summary

Build a read-only, full-screen .NET 10 terminal application for people who want to keep a Git worktree in view while working. At startup the user supplies a repository folder. The dashboard continuously shows status, history, branches, remotes and worktrees, with keyboard navigation, color and a restrained animated refresh indicator. Each vertical slice must leave a runnable, useful application; no unattended worker may ask for clarification.

## 2. Scope

**In scope**
- Local, non-bare Git worktrees; a folder inside a worktree resolves to its root.
- Live status, recent commits, local/remote branches, configured remotes and linked worktrees.
- Full-screen terminal layout using available cells, including a maximized window on a 2560x1440 display.

**Out of scope**
- Staging, checkout, commit, fetch, push, configuration changes or any repository mutation.
- File diff viewer, commit detail view, tags, stash, reflog, repository statistics, persistence and telemetry.
- Network calls, remote authentication, bare repositories and submodule recursion.

## 3. Requirements

### 1. Folder selection (StatusSlice)
**Objective:** As a developer, I want to select a local worktree so I can monitor the correct repository.

1.1 When GitRepoMonitor starts, the application shall prompt for a repository folder before opening the dashboard.
1.2 If the supplied folder is missing, unreadable, bare or outside a Git worktree, the application shall show a specific validation error and prompt again without exiting.
1.3 If the Git executable is unavailable, the application shall print a diagnostic and exit with a nonzero code.
1.4 The Git reader shall collect data without modifying the monitored repository, contacting remotes or running hooks.

### 2. Live status (StatusSlice)
**Objective:** As a developer, I want changes and branch state to update while I work.

2.1 When a valid worktree is selected, the dashboard shall open with its root path, HEAD identity, upstream and staged, unstaged and untracked files.
2.2 If HEAD is detached or unborn, the dashboard shall label that state and shall not present a nonexistent branch or commit.
2.3 If no usable upstream exists, the dashboard shall show ahead/behind as unavailable; otherwise it shall show both counts.
2.4 When a path is staged and unstaged at the same time, the dashboard shall show both change kinds; renames shall retain the original path.
2.5 While the dashboard is open, the application shall start a new read no later than one second after the previous read completes.
2.6 When a repository change occurs and each Git read takes under 500 ms, the dashboard shall display the change within two seconds.
2.7 If a refresh fails, the application shall retain the last successful snapshot and show the refresh error.
2.8 When a refresh succeeds after a failure, the application shall clear the refresh error.
2.9 When the user presses Q or Ctrl+C, the application shall stop refreshing, release the terminal and exit without changing the repository.

### 3. History and branches (HistorySlice)
**Objective:** As a developer, I want nearby history and branch context without leaving the dashboard.

3.1 When a snapshot is displayed, the dashboard shall show up to 20 recent commits, newest first, with short hash, subject, author and authored time.
3.2 When a snapshot is displayed, the dashboard shall show local and remote-tracking branches separately and identify the checked-out local branch.
3.3 If a repository has no commits or no remote-tracking branches, the dashboard shall show an explicit empty state in the corresponding view.

### 4. Worktrees and terminal experience (WorktreeSlice)
**Objective:** As a developer, I want repository context and a legible display at my terminal's current size.

4.1 When a snapshot is displayed, the dashboard shall show each configured remote's name and every configured fetch/push URL, or an explicit empty state.
4.2 When a snapshot is displayed, the dashboard shall show each linked worktree's path and branch/detached state and identify the selected worktree.
4.3 When the terminal is resized, the dashboard shall use the available rows and columns without overlapping text, including at 80x24 cells and in a maximized 2560x1440 display; overflowing lists shall scroll or truncate visibly.
4.4 When the user presses Tab, Shift+Tab or arrow keys, the dashboard shall move focus among visible views or scroll the focused list; Q shall remain available to exit.
4.5 While a refresh is in progress, the dashboard shall animate a refresh indicator at least every 250 ms without changing panel dimensions or obscuring data.
4.6 If the terminal lacks color support, the dashboard shall preserve readable labels and state distinctions without relying on color alone.

## 4. Design

### 4.1 Approach

Use a .NET full-screen terminal UI library for layout and keyboard input, with local Git subprocesses producing immutable snapshots. The application owns validation and refresh scheduling; the UI consumes updates and draws the current state. Build sequential vertical slices: status first, then history/branches, then remotes/worktrees and final navigation polish. A scrolling live console would limit navigation; a custom ANSI renderer would add unnecessary terminal compatibility work.

### 4.2 Modules and boundaries

Bootstrap is performed by `Initialize-Project.ps1` before the planner runs; its row documents pre-plan ownership, not an extra worker task. The slices intentionally extend the same application source paths **sequentially**, never in parallel. Contracts is a non-runnable prerequisite, not a vertical slice; it requires a passing build and test check only. Each of the three feature slices must compile, pass the whole-project check and remain runnable before its successor starts. Within each feature slice, Git reading, presentation, wiring and tests are delivered together.

| Module | Responsibility | Paths (repo-relative) | Uses | Requirements |
| --- | --- | --- | --- | --- |
| Bootstrap (pre-plan, not worker task) | Create skeleton and smoke test; run section 6 setup and whole-project check | `GitRepoMonitor.slnx`, `src/GitRepoMonitor/GitRepoMonitor.csproj`, `tests/GitRepoMonitor.Tests/GitRepoMonitor.Tests.csproj`, `tests/GitRepoMonitor.Tests/SmokeTests.cs`, `.gitignore`, `README.md` | none | none (skeleton only) |
| Contracts | Shared snapshot/update types and interfaces from 4.3 | `src/GitRepoMonitor/Contracts/**` | bootstrap | 1.2, 2.1-2.8, 3.1-3.3, 4.1-4.2 |
| StatusSlice | Prompt, validation, read-only status, refresh, initial full-screen UI and exit | `src/GitRepoMonitor/Git/**`, `src/GitRepoMonitor/Ui/**`, `src/GitRepoMonitor/App/**`, `src/GitRepoMonitor/Program.cs`, `src/GitRepoMonitor/GitRepoMonitor.csproj`, `tests/GitRepoMonitor.Tests/StatusSlice/**` | Contracts | 1.1-1.4, 2.1-2.9 |
| HistorySlice | Add history and branch views to the running dashboard | `src/GitRepoMonitor/Git/**`, `src/GitRepoMonitor/Ui/**`, `src/GitRepoMonitor/App/**`, `tests/GitRepoMonitor.Tests/HistorySlice/**` | StatusSlice | 3.1-3.3 |
| WorktreeSlice | Add remotes/worktrees and complete responsive navigation/animation | `src/GitRepoMonitor/Git/**`, `src/GitRepoMonitor/Ui/**`, `src/GitRepoMonitor/App/**`, `tests/GitRepoMonitor.Tests/WorktreeSlice/**` | HistorySlice | 4.1-4.6 |

**Existing files changed:** None; this is a new project. Bootstrap builds the app project as a library with no entrypoint; StatusSlice changes its project file to a console executable and adds `Program.cs`. Subsequent slices may change prior slice source files only after their dependency completes.

### 4.3 Shared contracts

Place the following public API in `src/GitRepoMonitor/Contracts/**`. Use implicit .NET usings. List order is display order: commits newest first, file changes by path, branches by local/remote then name, remotes by name, worktrees by path. A null `HeadName` means detached or unborn HEAD; null `HeadCommit` means unborn. Null `Ahead`/`Behind` means upstream unavailable. `DashboardUpdate.Snapshot` is null only before the first successful read; afterward it is the last successful snapshot even on errors. `RefreshError` is null on success.

```csharp
namespace GitRepoMonitor.Contracts;

public enum ChangeKind { Added, Modified, Deleted, Renamed, Copied, TypeChanged, Unmerged, Untracked }

public sealed record FileChange(string Path, string? OriginalPath,
    ChangeKind? Staged, ChangeKind? Unstaged);
public sealed record CommitInfo(string Hash, string Subject, string Author,
    DateTimeOffset AuthoredAt);
public sealed record BranchInfo(string Name, bool IsRemote, bool IsCurrent);
public sealed record RemoteInfo(string Name, IReadOnlyList<string> FetchUrls,
    IReadOnlyList<string> PushUrls);
public sealed record WorktreeInfo(string Path, string? Branch,
    bool IsCurrent, bool IsDetached);

public sealed record RepositorySnapshot(
    string Root, DateTimeOffset CapturedAt,
    string? HeadName, string? HeadCommit, string? Upstream,
    int? Ahead, int? Behind,
    IReadOnlyList<FileChange> Changes,
    IReadOnlyList<CommitInfo> RecentCommits,
    IReadOnlyList<BranchInfo> Branches,
    IReadOnlyList<RemoteInfo> Remotes,
    IReadOnlyList<WorktreeInfo> Worktrees);

public sealed record DashboardUpdate(
    RepositorySnapshot? Snapshot, DateTimeOffset CheckedAt,
    string? RefreshError);

public sealed class RepositoryReadException : Exception
{
    public RepositoryReadException(string message, Exception? innerException = null)
        : base(message, innerException) { }
}

public interface IRepositoryReader
{
    Task<string> ResolveWorktreeRootAsync(string folder, CancellationToken cancellationToken);
    Task<RepositorySnapshot> ReadAsync(string root, CancellationToken cancellationToken);
}

public interface IDashboardView
{
    Task RunAsync(IAsyncEnumerable<DashboardUpdate> updates, CancellationToken cancellationToken);
}
```

`RemoteInfo.FetchUrls` and `PushUrls` contain all configured URLs in Git configuration order (empty list if none); no URL is discarded. `ResolveWorktreeRootAsync` throws `RepositoryReadException` for invalid folders or non-worktrees; `ReadAsync` throws it on a failed read rather than returning partial data. Missing Git is diagnosed by the application separately. `RunAsync` returns on Q or cancellation, disposes the update stream and restores the terminal. Each Git invocation uses an argument list (no shell), non-interactive settings and `GIT_OPTIONAL_LOCKS=0`; do not run Git commands that fetch, lock, write or invoke hooks.

### 4.4 Error handling

Reject bad startup paths in the prompt with an actionable message and allow retry. After entering the dashboard, publish `DashboardUpdate` with the previous snapshot and a short refresh error on any read failure, then retry at the next interval. Do not replace a successful snapshot with partially collected data. Ctrl+C, Q and process cancellation restore terminal state; errors must not leave the alternate screen active.

## 5. Build order

1. Bootstrap the .NET solution, projects, test runner and smoke test; implement 4.3 as a non-runnable prerequisite and check build and tests before feature slices.
2. StatusSlice: deliver a runnable full-screen live status dashboard. Run setup and whole-project check; verify prompt, refresh, errors and exit.
3. HistorySlice depends on StatusSlice: extend the same runnable app with recent commits and branch views. Run whole-project check again.
4. WorktreeSlice depends on HistorySlice: extend the same app with remotes, worktrees, navigation, color fallback and animation. Run whole-project check again. Do not schedule overlapping slice source paths concurrently.

## 6. Verification

- **Setup command:** `dotnet restore GitRepoMonitor.slnx` (PowerShell 7, repository root; .NET 10 SDK and Git on PATH).
- **Test runner and layout:** xUnit in `tests/GitRepoMonitor.Tests/`; bootstrap creates `SmokeTests.cs`; slice tests use namespace names containing `StatusSlice`, `HistorySlice` or `WorktreeSlice`. Tests create disposable Git repositories under the OS temp directory; Git author identity is set only in those repos.
- **Per-module check:** Contracts: `dotnet build GitRepoMonitor.slnx`; StatusSlice: `dotnet test GitRepoMonitor.slnx --filter 'FullyQualifiedName~StatusSlice'`; HistorySlice: `dotnet test GitRepoMonitor.slnx --filter 'FullyQualifiedName~HistorySlice'`; WorktreeSlice: `dotnet test GitRepoMonitor.slnx --filter 'FullyQualifiedName~WorktreeSlice'`.
- **Whole-project check after each slice:** `dotnet build GitRepoMonitor.slnx && dotnet test GitRepoMonitor.slnx`.
- **Automated cases:** Valid/invalid/nested folder, missing Git, clean/dirty/staged and unstaged changes, renames, detached/unborn HEAD, absent upstream, refresh failure/recovery and cancellation; commits/branches and empty history; multiple fetch/push URLs per remote and worktrees; layout at 80x24 and large cell grids, navigation and color fallback. Use fakes for timed refresh/UI tests; do not require an attached terminal in CI.
- **Manual checks:** In a maximized terminal on a 2560x1440 display, verify all available terminal cells are used, resize reflows, colors and animation remain legible, and Q restores the shell. Pixel size is not a fixed cell count.

## 7. Constraints

- **Stack:** C# with .NET SDK 10, `net10.0` console app; Terminal.Gui stable 1.x for the full-screen UI; xUnit 2.x for tests; NuGet and `dotnet` CLI as package manager/build tool. The bootstrap pins compatible stable package versions and creates `GitRepoMonitor.slnx` and both project files. No other dependencies without approval.
- **Conventions:** File-scoped C# namespaces, nullable enabled, implicit usings, async cancellation-aware I/O, no interactive terminal dependency in unit tests. The bootstrap-generated project and smoke test are the conventions to follow; no existing application files exist.
- **Shared files:** Bootstrap creates solution/project manifests, `.gitignore`, `README.md` and smoke test. StatusSlice alone also changes `src/GitRepoMonitor/GitRepoMonitor.csproj` from a library to an executable after bootstrap. StatusSlice, HistorySlice and WorktreeSlice intentionally reuse `src/GitRepoMonitor/Git/**`, `Ui/**` and `App/**` in dependency order; no two such slices run in parallel. Contracts public API is written once and must not be silently changed by later slices.

**Always**
- Keep the application read-only with respect to the selected repository; use argument-safe local Git calls, cancel subprocesses on shutdown, and test with disposable temporary repositories.
- Leave a runnable application and passing whole-project check at the end of each slice.

**Stop and report blocked**
- .NET 10 SDK, Git or a compatible stable terminal library is unavailable, or a requirement would require a public-contract change or repository mutation.

**Never**
- Fetch, push, stage, checkout, commit, modify configuration, execute repository hooks, store credentials or contact a remote from the monitor.
- Replace the approved .NET stack, write to the user's monitored repository, or implement out-of-scope views without approval.

## 8. Open questions

None.