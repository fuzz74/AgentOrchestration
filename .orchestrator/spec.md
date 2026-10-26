# Repo-based analysis mode

## 1. Summary

Make analysis a first-class objective of the existing agent orchestrator, with the same
Git repository, worktrees, gates and finish lifecycle as development. Add discoverable
entry skills for interactive analysis, autonomous analysis and an analysis-spec interview.
The user's prompt defines the analysis output; when it does not, AI chooses a suitable
format and records the choice in the spec. All deliverables are created in the target
repository, and coding tasks may build tools or prototypes needed for the investigation.
Reuse the existing implementation: avoiding duplicated logic and instructions is a
mandatory acceptance condition.

## 2. Scope

**In scope**
- `/analyze`, `/auto-analyze`, `/write-spec-analyze` and shared analysis-mode handling.
- Deliverable-appropriate interview, spec guidance, planning, worker and reviewer prompts.
- Minimal initialization of new analysis repositories.
- Compatibility with existing development runs and mixed analysis/coding task graphs.
- Documentation, skill-contract checks and fake-agent regression coverage for both providers.

**Out of scope**
- A separate analysis runner, scheduling system, persistence format or finish command.
- External-only deliverables or bypassing the existing committed-change completion gate.
- New database adapters, binary merge mechanisms, external-directory parameters or sandboxes.
- Provider/model changes, automatic pushing, or weakened ownership/access protections.
- Implementing an example investigation as part of this change.

## 3. Requirements

### 1. Discoverable entry points

**Objective:** Start analysis without remembering a mode parameter.

1.1 When the user invokes `/analyze`, the skill shall delegate to `orch` in analysis mode,
preserving the interactive interview and existing approval checkpoints.
1.2 When the user invokes `/auto-analyze`, the skill shall delegate to `auto-develop` in
analysis mode, reusing its autonomy directive and stopping before the merge.
1.3 When the user invokes `/write-spec-analyze`, the skill shall delegate to `write-spec`
in analysis mode and stop at its spec hand-off.
1.4 While executing headlessly, the orchestrator shall prevent invocation of all three
new entry skills through the existing provider-specific skill restrictions.

### 2. Shared mode and lifecycle

**Objective:** Carry analysis intent without creating a parallel workflow.

2.1 When handing off a new analysis request, the shared skills shall carry analysis mode
through spec writing and planning into `settings.workerType: "analysis"`.
2.2 When resuming an existing plan, `orch` shall read its effective run mode from
`settings.workerType`, defaulting to coding when absent.
2.3 If an entry skill or new request conflicts with an existing run's mode, `orch` shall
identify the conflict and retain the existing plan without silently retagging its tasks or
resuming sessions with a different role; interactive users choose how to proceed, and
autonomous invocations stop and explain the conflict.
2.4 While running analysis, the orchestrator shall retain the existing worktree, ownership,
acceptance, review, retry, integration, try and finish behaviour and approval protections.
2.5 When no analysis mode is selected, the orchestrator shall preserve the existing
development defaults and new-project software bootstrap.

### 3. Output and interview

**Objective:** Investigate the user's question and produce the requested result in the repo.

3.1 When the prompt defines the result's representation, the spec-writing flow shall retain
that representation and establish its repo-relative destinations and acceptance criteria.
3.2 If the prompt leaves the representation unspecified, AI shall choose a suitable format
and record it in the spec, presenting it during interactive review without requiring a
separate format-choice question; autonomous runs make the choice without asking.
3.3 While specifying analysis, the interview shall establish the question, relevant sources,
access limits, scope, success criteria and requested outputs, asking only for unresolved gaps.
3.4 When an analysis deliverable requires software design, contracts, setup or tests, the
shared spec guidance and reviewer shall include those sections; otherwise they shall not
demand them solely because development specs use them.
3.5 When an analysis spec is handed to planning, it shall identify its analysis mode,
deliverables, ownership boundaries, dependencies and applicable verification clearly.
3.6 While specifying or executing analysis, the skills and prompts shall keep all
deliverables in the target Git repository and distinguish approved source inspection from
the repo paths the task may change.

### 4. Planning and task roles

**Objective:** Build only the tools and dependencies the investigation actually needs.

4.1 When planning analysis, both interactive and scripted planning shall use the existing
shared planning rules and choose dependencies and ownership from the requested work.
4.2 When substantial tool or prototype implementation is needed, the planner shall permit
one or more tasks with `workerType: "coding"` within the analysis run, ordering consumers
after the tasks whose committed files they need.
4.3 When choosing acceptance checks, the planner shall use checks appropriate to each
deliverable, including software tests when applicable, rather than a fixed output format.
4.4 While planning analysis, the planner shall avoid imposing a fixed graph shape or
additional tasks that the investigation and its deliverables do not need.

### 5. Minimal analysis initialization

**Objective:** Establish the same Git baseline without inventing a software stack.

5.1 When initializing a new analysis target, `Initialize-Project.ps1` shall create the Git
repository when necessary, initialize the existing orchestration metadata, and make a
minimal baseline commit containing a neutral README without invoking a bootstrap agent.
5.2 When initializing analysis, the initializer shall not require a stack, install
dependencies, scaffold application code, or invent setup/integration commands; new
`project.json` setup and integrationCheck defaults shall be null.
5.3 If the target already has commits, initialization shall leave its tracked files and
project configuration unchanged, as the existing initializer does.
5.4 When planning analysis interactively or through `Plan-Tasks.ps1`, the flow shall invoke
the same initializer with the selected worker type, rather than implement Git setup twice.
5.5 When planning with existing project configuration, the flow shall retain its setup,
integrationCheck and unrelated keys, preserving the existing explicit-command precedence
and plan-only overrides for commands that depend on work not yet merged.

### 6. Execution quality and compatibility

**Objective:** Check the investigation and deliverable without confusing analysis with coding.

6.1 When working on or reviewing analysis, the prompts shall require supported conclusions,
honest uncertainty and explicit inaccessible-source handling in a way appropriate to the
requested result, without prescribing its representation.
6.2 When a coding task supports analysis, its existing coding worker/reviewer shall check
the tool or prototype against that task and the shared spec.
6.3 If an analysis task leaves no committed repo changes, the failure feedback shall explain
that the requested result must be saved within its owned repo paths instead of demanding
software implementation.
6.4 While reporting completion, shared result-schema descriptions and retry instructions
shall describe completed work neutrally without changing the schema's fields or gate order.
6.5 When the run finishes, the shared flow shall present the requested result and use normal
`orch try` / `orch finish` semantics, retaining applicable project-command update offers.

### 7. Reuse, documentation and coverage

**Objective:** Keep the implementation maintainable and the behaviour verifiable.

7.1 While implementing the entry skills, each wrapper shall contain only request forwarding,
its mode addition and delegation; autonomy rules shall remain owned by `auto-develop`.
7.2 While adapting the workflow, lifecycle, access, provider selection, interview mechanics,
planning rules and Git setup shall each remain shared rather than copied into analysis variants.
7.3 When documenting analysis, README and reference guidance shall describe the approved
entry points, output choice, repo-based lifecycle and optional coding tasks consistently.
7.4 When running regression checks for either provider, the tests shall cover minimal
analysis initialization, coding initialization, mixed task-role routing, committed result
integration, legacy coding defaults and headless blocking of the new skills.
7.5 When validating skill instructions, the checks shall cover wrapper delegation, mode
handoffs and instruction consistency without presenting static checks as proof of real-agent
interview or output-selection behaviour.

## 4. Design

### 4.1 Approach

Extend the existing flow using its existing `workerType` contract. Three wrappers provide
discoverability; existing skills own their mechanics and load analysis-specific differences
only as needed. Adapt the current spec template/reviewer instead of copying their common
sections. Preserve the existing analysis worker/reviewer templates, changing only necessary
wording and guidance. Use one initializer with a small analysis baseline branch.

Separate full analysis skills/runners are rejected because they duplicate the lifecycle.
Prompt-only worker changes are insufficient because spec writing and initialization also
shape the run.

### 4.2 Modules and boundaries

Paths in this table are repo-relative globs.

| Module | Responsibility | Paths | Uses | Requirements |
| --- | --- | --- | --- | --- |
| skills | Thin wrappers; shared mode handling, interview/spec review and hand-offs | `.claude/skills/**` | Existing runtime contracts in 4.3 | 1.1-1.3, 2.1-2.5, 3.1-3.6, 4.1-4.4, 5.4-5.5, 6.5, 7.1-7.2 |
| runtime | Initializer, caller, task prompts, neutral feedback and headless restrictions | `orchestrator/Initialize-Project.ps1`, `orchestrator/Plan-Tasks.ps1`, `orchestrator/Orchestrator.psm1`, `orchestrator/prompts/**`, `orchestrator/schemas/**` | Existing runtime contracts in 4.3 | 1.4, 2.1, 2.4-2.5, 3.6, 4.1-4.4, 5.1-5.5, 6.1-6.4, 7.2 |
| verification | Fake-agent scenarios and focused skill-contract assertions | `tests/Run-SmokeTest.ps1`, `tests/fake-claude.ps1`, `tests/Test-AnalysisSkills.ps1` | skills, runtime | 1.1-1.4, 2.1-2.5, 3.1-3.6, 4.1-4.4, 5.1-5.5, 6.1-6.5, 7.1-7.2, 7.4-7.5 |
| documentation | Usage, installer help and replacement of stale reference advice | `README.md`, `Install-Orch.ps1`, `docs/analysis-mode.md` | skills, runtime | 7.3 |

**Existing files changed:** the four existing skill instructions and `write-spec` template/
reviewer guidance; the initializer and its planning caller; the core module's headless list
and no-change feedback; affected existing prompts/schema descriptions; fake-agent test
fixture and smoke runner; README, installer help and the analysis reference note.

New wrappers already exist as uncommitted drafts. The core deny list also has an uncommitted
edit. Later implementation must integrate these drafts rather than discard or blindly commit
them; in particular, the autonomous wrapper must reuse `auto-develop`.

### 4.3 Shared contracts

**Entry delegation**

| Entry | Delegate | Input addition |
| --- | --- | --- |
| `analyze` | `orch` | `mode: analysis` |
| `auto-analyze` | `auto-develop` | `mode: analysis` |
| `write-spec-analyze` | `write-spec` | `mode: analysis` |

Each wrapper preserves the original request and delegates through the assistant-appropriate
invocation already used by existing skills. It does not copy its delegate's rules.

**Mode persistence**

```json
{
  "settings": { "workerType": "analysis" },
  "tasks": [
    { "id": "build-tool", "workerType": "coding" },
    { "id": "investigate", "deps": ["build-tool"] }
  ]
}
```

This is a field illustration, not a complete valid plan. The existing task fields remain
required as defined in `tasks.schema.json`. User-facing development maps to `coding`;
analysis maps to `analysis`. Task override wins over the run default; missing values default
to coding. No new persisted mode field or `project.json` mode default is introduced.
Before planning, the spec identifies analysis mode in its Summary.

**Initializer extension**

```powershell
[ValidateSet('Coding', 'Analysis')][string]$WorkerType = 'Coding'
```

Add this optional parameter to `Initialize-Project.ps1`; keep its existing parameter names,
defaults and script result behaviour. `Plan-Tasks.ps1` forwards its existing `WorkerType`.
Interactive planning calls the initializer using that same parameter. Analysis does not call
the bootstrap agent, so `bootstrap-result.schema.json` does not need a new response shape.

For a newly initialized analysis project, configuration defaults are:

```json
{ "setup": null, "integrationCheck": null }
```

Merge these defaults without overwriting existing keys/commands in a pre-existing
`project.json`, including one present before the first Git commit. The planner retains its
existing provider persistence. The README baseline must not overwrite a pre-existing README;
if necessary, use an empty initial commit rather than stage unrelated pre-existing files.
Do not stage user data or existing unrelated files to satisfy initialization.

**Result and ownership**

Retain `worker-result.schema.json` fields (`status`, `summary`, `notes_for_dependents`,
optional `blocked_reason`) and `tasks.schema.json` ownership/acceptance semantics. A
repo-local database is a repo deliverable; its validation and concurrent-edit constraints
must fit existing ownership/scheduling and Git integration. This update does not add binary
merging or allow chat-only or external-only results through the committed-change gate.

### 4.4 State

No new run-state model. Existing tasks.json, state.json and project.json lifetimes remain.
Existing paused sessions are not reinterpreted by changing modes.

### 4.5 Error handling

Use existing thrown errors, progress logs, blocked results and skill checkpoint behaviour.
Report Git/setup/check failures with their existing diagnostics. Distinguish inaccessible
sources from completed investigation; never invent findings to pass review. Mode conflicts
follow 2.3, without automatic plan replacement or forced cleanup.

## 5. Build order

1. Implement skills and runtime changes independently against section 4.3; keep initializer
   and its caller in the same runtime ownership boundary.
2. Update verification after those surfaces exist; retain old scenarios while adding new ones.
3. Reconcile documentation with the resulting behaviour and run the combined checks.

The planner chooses task sizes. No separate interface-only task is required: section 4.3
already defines the shared interfaces.

## 6. Verification

- **Setup command:** none; use the installed PowerShell, Git and existing fake-agent harness.
- **Test runner/layout:** PowerShell scripts in `tests`; fake CLI responses spend no AI tokens.
- **Skill check (created by verification):** `& .\tests\Test-AnalysisSkills.ps1`.
- **Runtime checks:** `& .\tests\Run-SmokeTest.ps1 -Provider Claude` and
  `& .\tests\Run-SmokeTest.ps1 -Provider Copilot`, executed sequentially because the existing
  fake-agent harness shares temporary state.
- **Whole-project check:** run the skill check and both provider checks, stopping and returning
  nonzero on the first failure.

The existing smoke scenario currently selects Analysis while expecting software bootstrap
and inherited bootstrap commands. Preserve its coding-bootstrap failure/fix coverage in an
explicit Coding scenario; add a separate Analysis scenario rather than weakening assertions.
Check no analysis bootstrap invocation, initial commit with no invented stack, preservation
of existing files/config (including unrelated files already staged in the Git index), mixed
worker and reviewer roles, normal integration and existing
ownership/retry/finish protections. Update `fake-claude.ps1`'s explicit skill-block list
alongside the runtime list. Do not create test fixtures with real project identifiers.

Static skill checks cover delegate names, mode additions, shared autonomy ownership and
absence of contradictory unconditional instructions. They must not be the sole check for
semantic requirements.

**Manual checks:** exercise an interactive analysis interview with specified output, one
with unspecified output, and one requiring a coding tool; confirm the chosen format is
reviewable, unnecessary questions are skipped, applicable software sections remain, and the
spec-only wrapper stops before planning. Check an existing-plan mode conflict and a resume
without mode fields. If live checks are not run, report that limit explicitly.

## 7. Constraints

- **Stack:** existing PowerShell 7.2+, Git, Markdown skills/prompts and JSON schemas.
  No new runtime dependencies or test framework.
- **Conventions:** follow existing thin wrappers, `Initialize-RunDir`, `Invoke-Git`,
  `Format-Template` and the fake-agent harness. No copied runner or lifecycle.
- **Shared files:** none beyond files assigned to one module; dependency ordering controls
  cross-module integration.

**Always**
- Preserve existing development behaviour, provider/model resolution and permissions.
- Keep all analysis outputs in the target repo and appropriate owned paths.
- Reuse common instructions; isolate only actual analysis differences.
- Treat the latest approved requirements here as replacing stale analysis-design advice.

**Stop and report blocked**
- A requested result or source access cannot be achieved within approved boundaries.
- A deliverable cannot satisfy the existing Git/worktree integration constraints.

**Never**
- Duplicate autonomy, access, interview mechanics, lifecycle or Git initialization logic.
- Introduce a second analysis execution/finish lifecycle.
- Read unrelated projects, expose secrets, silently retag paused tasks or weaken gates.

## 8. Open questions

None.
