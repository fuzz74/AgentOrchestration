# Analysis work with the orchestrator: how it works today, and a fix

Reference note. It answers: why does a run meant for analysis still behave like a
development run, and what is the smallest change that makes analysis as seamless as
development? Nothing here is built yet; it is the design to build.

## Short answer

The **engine already supports analysis**. The **skills do not**, and the skills are the path you
actually use. `/orch` -> `write-spec` -> `plan-tasks` never says "analysis" anywhere, so an
interactive run always ends up as a coding run. Only the scripted route
(`orch plan <spec> -WorkerType Analysis`) switches the engine over.

So the fix is not new skills. It is one **mode** that the existing skills carry from the first
message to the last step, written into the plan, where the engine already reads it.

## How it works today

### The engine (works)

| Piece | Where | What it does |
| --- | --- | --- |
| `settings.workerType` and per-task `workerType` (`coding` or `analysis`) | `schemas/tasks.schema.json`, `Orchestrator.psm1` (default `coding`; task value wins) | The only switch. It is read when a task starts. |
| `Plan-Tasks.ps1 -WorkerType Analysis` | `Plan-Tasks.ps1` | Tells the planner the run default and writes `settings.workerType`. The planner may override single tasks. |
| `prompts/analysis-worker.md`, `prompts/analysis-reviewer.md` | chosen in `Orchestrator.psm1` (`Invoke-Review`, the worker loop) | Evidence-first role: cite source, query or measurement; separate observation from interpretation; record access gaps; no placeholders. The reviewer fails fabricated or unsupported conclusions and does not demand code or tests. |
| `settings.additionalDirectories` | `tasks.json` only | Folders outside the worktree (sources, exports, reference material) passed as `--add-dir`. Grants access, not read-only enforcement. |
| Acceptance, owns, waves, merge to `orch/integration` | unchanged | Same gates. An analysis task still has to leave **files** in its `owns`, pass its acceptance command, and pass review. |

The smoke test covers the engine side (`tests/Run-SmokeTest.ps1`: analysis default, coding
override, analysis prompts used).

### The skills (the gap)

| Skill | What it assumes | Effect on an analysis request |
| --- | --- | --- |
| `orch` | Idea -> build -> `orch try` -> merge. Step 3 hands to `plan-tasks`. No mode. | Nothing carries "analysis" forward. |
| `auto-develop` | Appends only the no-involvement directive. | Same, and the name says "develop". |
| `write-spec` | Interview for purpose, scope, constraints; **EARS requirements, modules with paths, shared contracts, stack, test runner**; reviewer checks modules, contracts, parallel-build conflicts. | The agent is steered to invent modules, contracts and unit tests for work that has none. Questions that matter for analysis (what is the question, which sources, what counts as evidence, what must not be touched) are never asked. |
| `plan-tasks` | Writes `tasks.json` interactively. The example and its steps never set `workerType`. | `settings.workerType` stays at its default, `coding`. **This is the root cause.** |
| `plan-tasks` step 2 / `Initialize-Project.ps1` | A repo with no commits gets a bootstrap agent that creates a manifest, test runner and smoke test (`prompts/bootstrap.md`). | Wrong for analysis: it scaffolds a code project and blocks if no stack is named. |

### Other places that still talk like development

Even with `workerType: analysis`, some shared text is coding-flavoured:

- `Orchestrator.psm1` (~line 1073): when a worker leaves no changes the feedback is "Implement
  the task in the worktree". An analysis task whose answer lives only in chat is told to
  implement something.
- `prompts/retry.md`: "Fix the problems", generic enough, but has no evidence wording.
- `schemas/worker-result.schema.json`: `done` is described as "implemented"; summary as
  "what was changed".
- `prompts/bootstrap.md`: code-only (see above).
- `prompts/planner.md` and `planning-rules.md`: mostly neutral, but give no analysis planning
  guidance (see below).
- `orch` step 7 and `README`: the finish is "merge result into the base branch", and `orch try`
  opens the branch for trying code. For analysis the deliverable is a report plus evidence.
- Source safety (credentials, databases, read-only access) is only in the reviewer prompt. The
  worker has full `Bash`/`PowerShell` tools and nothing tells it about read-only sources
  except what the spec says.

## What analysis needs that development does not

1. **A question, not a feature.** Success is "the question is answered, with evidence",
   not "requirements pass".
2. **Sources and access.** What may be read, where it lives (often outside the repo), what is
   inaccessible, and what must never be changed or exposed.
3. **A different split.** Development splits by module. Analysis splits by source or slice
   (fan-out), then one synthesis task (fan-in) that depends on all of them. The contract
   between tasks is an **artifact format** (findings catalog, evidence file layout), written
   out like a code contract.
4. **Different acceptance.** A validator that the artifacts exist, have the agreed columns or
   headings, cover every source or slice, and cite evidence. Not unit tests.
5. **Different "done" review.** Coverage, evidence, uncertainty, source fidelity. The analysis
   reviewer already does this.
6. **A different ending.** Review the report, then keep the artifacts (merge, or archive
   without merging). No "try the app".

## The fix: one `mode` parameter, carried by the existing skills

### The parameter

Skills take free text, not flags, so the parameter is a phrase the skill recognises, with a
confirmation as backup:

- `/orch mode: analysis <topic or spec>`; `/auto-develop mode: analysis ...`;
  `/write-spec mode: analysis ...`; `/plan-tasks mode: analysis ...`. Same for plain wording
  such as "this is an analysis, not a development run".
- Values: `development` (default, today's behaviour) and `analysis`. An unset mode is
  development, so nothing existing changes.
- If the request reads like analysis but has no `mode`, `orch` asks once, at the start
  ("This looks like an analysis. Run it as one?"). With no involvement it takes analysis only
  when the request says so plainly, otherwise development.
- Mixed work (analysis first, then a build): mode is the run default; tasks may override with
  `workerType`, which the engine already allows. Prefer two runs when the second depends on
  the first's conclusions.

### One source of truth after planning

The chat can end and `/orch` can resume in another chat, so the mode must live in the plan:
`tasks.json` -> `settings.workerType`. Before a plan exists, the skill passes the mode down in
its hand-off text. When `orch` resumes at step 1 with an existing `tasks.json`, it **reads the
mode from the plan** and uses it for its wording in steps 4-7.

### Changes, file by file

**Skills**

| File | Change |
| --- | --- |
| `orch/SKILL.md` | Add a **Mode** rule (parse, default, ask-once, read from plan on resume). Pass the mode to `write-spec` and `plan-tasks`. In step 7, analysis wording: say the artifacts and report are on the integration branch; offer to open them (not "try the app"); ask whether to merge them or archive without merging; skip the `project.json` check-copy offer. In step 6, point to the analysis reviewer's issues and the acceptance validator. |
| `auto-develop/SKILL.md` | Pass the mode through unchanged. Optional: a three-line `auto-analyze` alias that appends `mode: analysis`, if you prefer a distinct command name. It would be a thin wrapper like `auto-develop`, not a new process. |
| `write-spec/SKILL.md` | In analysis mode use `spec-template-analysis.md` and an analysis interview: question and decision it feeds, sources and how to reach them, what counts as evidence, access gaps to report, safety rules (read-only, credentials, data sensitivity), deliverables and layout, coverage definition. No EARS, modules or unit tests. Keep the blank-canvas rule and the hard gates. |
| `write-spec/spec-template-analysis.md` (new) | Sections: Summary and question; Scope and out of scope; Sources (location, access, read-only?); Method and evidence rules; Deliverables and artifact layout (paths become `owns`); Shared artifact contracts (catalog schema); Slices and order (fan-out, then synthesis); Verification (validator commands); Constraints (Always / Stop and report blocked / Never); Open questions. |
| `write-spec/reviewer-prompt.md` | Add an analysis branch: sources named and reachable, coverage defined and checkable, every deliverable has a path, artifact formats written out, safety rules present, validators runnable. Skip module and contract checks that do not apply. |
| `plan-tasks/SKILL.md` | Step 6: set `settings.workerType` from the mode; add an analysis example (fan-out shards, a contract task for the catalog format, a synthesis task). Step 5: for analysis, show the table with `owns` as artifact folders and `acceptance` as validators. Add `additionalDirectories` for sources outside the repo, after asking. Step 7: dry-run prints the type. Step 2: for analysis in a repo with no commits, do the analysis skeleton (below), not the code skeleton. |

**Scripts and prompts**

| File | Change |
| --- | --- |
| `Initialize-Project.ps1` + `prompts/bootstrap.md` | Add `-WorkerType`. For `Analysis`, `git init`, a README, an artifacts folder and a `.gitignore`, one commit; no bootstrap agent, no setup or check commands (both may be null in a plan). `Plan-Tasks.ps1` passes its `-WorkerType` through. |
| `Plan-Tasks.ps1` | Add `-AdditionalDirectories` and write them to `settings.additionalDirectories`, so the scripted route matches the skill. |
| `Orchestrator.psm1` | Make the "no file changes" feedback depend on the worker type: for analysis, "Save your findings as files in your owned paths; chat-only answers are not kept". |
| `prompts/analysis-worker.md` | Add a short safety block: read sources only through read access, never write to a source or database, never copy credentials or secrets into artifacts. Keep it short; the reviewer already checks it. |
| `prompts/planning-rules.md` / `planner.md` | Add an analysis section: split by source or slice, contract task for the artifact format, one synthesis task depending on all shards, validator-style acceptance, `owns` per shard folder. Shown only when the run type is analysis. |
| `schemas/worker-result.schema.json` | Neutral wording: "the task's deliverable is complete" instead of "implemented". |
| `README.md` | Document `mode`, the analysis flow end to end, and the finish choice (merge or archive). Update the `workerType` table rows. |
| `tests/Run-SmokeTest.ps1` | Cover analysis init (no bootstrap agent), the analysis no-change feedback, and `-AdditionalDirectories`. |

### Finish for analysis

Analysis output often contains data you may not want in the base branch's history. In analysis
mode `orch` asks at the end: **merge** the artifacts (today's `orch finish`) or **archive
only** (the run folder under `<repo>.runs` already keeps the record). If archive-only is
common, that is a small `orch finish -NoMerge` option; for now, `Complete-Orchestrator.ps1`
does the archive.

## Order of work

1. **Mode plumbing**, the real fix: `orch`, `plan-tasks`, `auto-develop` (mode parse, set
   `workerType`, read it back on resume). Small, and it alone removes the "thinks it's
   development" symptom for runs that already have a spec.
2. **Analysis spec path**: `write-spec` interview, template, reviewer branch.
3. **Engine polish**: analysis skeleton, no-change feedback, `-AdditionalDirectories`,
   safety block, planner guidance, schema wording.
4. **Finish choice and README**, smoke test additions.

Steps 1 and 2 are skill text only and can ship without touching PowerShell.

## Open questions for you

- Keep the free-text `mode: analysis` convention, or also add a distinct `/auto-analyze`
  command?
- Should analysis finish default to merge or to archive-only?
- Where do your analysis sources usually live: inside the repo, in sibling folders, or in a
  database or service? That decides how much of `additionalDirectories` and the safety block
  must be built.
