# Repo-based analysis

Analysis is a run objective in the existing orchestrator, not a separate runner or finish
path. Start `/analyze` for an interactive interview, spec and plan approvals, run, and
finish decision. `/auto-analyze` delegates to the same flow with no involvement,
including autonomous fixes when possible, but stops before merging. `/write-spec-analyze`
interviews and reviews the spec only, stopping at the planning hand-off. These wrappers
delegate to `/orch`, `/auto-develop` and `/write-spec` respectively, passing `mode: analysis`.
The ordinary `/orch`, `/auto-develop` and `/write-spec` entry points also accept an
explicit analysis mode; development is coding by default.

## Specify and plan

The spec identifies analysis mode in its Summary. The interview establishes the
question, scope, relevant sources and access limits, success criteria and requested
result. The user's prompt determines the output representation when specified;
otherwise the AI chooses a suitable format, records its choice and reason in the
spec, and presents it during interactive review. The spec names repo-relative
destinations and applicable checks. Software design, contracts, setup or tests belong
in the spec when the requested work needs software, not by default.

Both interactive `/plan-tasks` and scripted `Plan-Tasks.ps1 -WorkerType Analysis`
use the shared planning rules and initializer. Plans store the run default as
`settings.workerType: "analysis"` in `.orchestrator/tasks.json`; a task's `workerType`
can override it (for example, `coding` for a substantial tool or prototype that
the investigation depends on). Dependencies ensure consumers see the tool's
committed files. The planner chooses ownership and acceptance checks appropriate
to each deliverable rather than prescribing a task graph. A missing mode defaults
to coding. Resuming an existing run uses its plan's effective mode; conflicting
requests must not silently retag tasks or paused sessions.

For a new analysis repo, `Initialize-Project.ps1 -WorkerType Analysis` creates a
minimal Git baseline with a neutral README and no software bootstrap, stack,
dependency installation or invented commands. New `project.json` setup and
integrationCheck default to null. Initialization preserves existing files and
configuration, and leaves a repo with commits unchanged. Coding initialization
keeps its existing software bootstrap.

## Execute and finish

Tasks use the normal worktrees, ownership checks, acceptance commands, reviewer,
retries and integration branch. Analysis workers and reviewers check evidence,
uncertainty and inaccessible sources without treating unsupported conclusions
as completed work. A coding task in an analysis run uses coding worker and reviewer
roles. Results must be saved and committed inside the target repo under owned
paths; chat-only and external-only results do not pass the committed-change gate.
Approved source access is distinct from the repo paths a task may change.

After the run, `orch try` opens the integration worktree to inspect the requested
result. `orch finish` checks and merges into the base branch, archives the run and
removes its worktrees; it does not push. The existing offers to update applicable
project commands still apply. A repo-local database is possible only when its
commits, validation and concurrent edits meet ordinary Git and ownership constraints.
There is no new external-directory API, binary merge mechanism or alternate finish.

## Safety and verification boundary

Only explicitly approved sources may be inspected. `settings.additionalDirectories`
grants file access outside a worktree, not read-only enforcement or ownership of
those directories; do not treat it as authorization to change them. Headless
Claude and Copilot runs block the three interactive analysis entry skills, using
their existing provider-specific skill restrictions.

The static skill check verifies delegation and mode hand-offs. Fake-agent smoke
scenarios cover minimal analysis initialization, coding defaults, mixed task roles,
committed-result integration and headless restrictions for both providers. They
do not prove live conversational behaviour: interactive interviews with specified
and unspecified outputs, a tool-building interview, spec-only stopping, and
existing-plan conflicts still require manual checks. No live conversational
checks are claimed here.
