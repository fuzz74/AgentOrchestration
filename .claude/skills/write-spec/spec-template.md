# <Feature, project or investigation name>

<!-- Guidance comments like this one are for the author. Delete them all in the final spec:
     the whole spec is pasted into the planner's, every worker's and every reviewer's prompt. -->

## 1. Summary

<!-- 3-6 sentences. What is being built or investigated, for whom, and why. What "done"
     looks like from the user's point of view. For analysis, identify analysis mode
     explicitly; otherwise coding is the default. No implementation detail. -->

## 2. Scope

**In scope**
- ...

**Out of scope**
<!-- Anything a capable agent might reasonably add on its own but should not. -->
- ...

## 3. Requirements

<!-- Numbered areas; criteria numbered N.M. Every criterion uses an EARS pattern and describes
     one observable, testable behaviour. Task prompts and reviewers cite these ids.
     For analysis, specify the question, sources and access limits, scope, success
     criteria, requested outputs, repo-relative destinations and appropriate acceptance.
     Preserve the user's output representation, or choose and record one if unspecified.
     Require supported conclusions and honest uncertainty, including inaccessible sources. -->

### 1. <Requirement area>
**Objective:** As a <role>, I want <capability>, so that <benefit>.

1.1 When <event>, the <component> shall <response>.
1.2 If <error or unwanted condition>, the <component> shall <response>.
1.3 While <state>, the <component> shall <response>.

### 2. <Requirement area>
...

**Non-functional** (only if they change what gets built; make them measurable)
- N.1 ...

## 4. Design

### 4.1 Approach
<!-- The chosen approach in a short paragraph, and one line on the alternatives rejected and
     why. Add a plain Mermaid diagram only if 3+ components interact. -->

### 4.2 Modules and boundaries
<!-- This table informs the task split: paths become `owns`, "Uses" informs `deps`.
     For analysis, rows may represent deliverables or work areas instead of software
     modules; include coding tool/prototype work where needed. Distinguish sources
     approved for inspection from paths tasks may change. All outputs are in the target
     repo. Paths are repo-relative globs with forward slashes. Parallel work must not
     share owned paths. Tests live inside the relevant module's own paths. -->

| Module | Responsibility | Paths | Uses | Requirements |
| --- | --- | --- | --- | --- |
| <module or deliverable> | <responsibility> | `<repo-relative/path/**>` | <actual dependencies or none> | 1.1-1.3 |

**Existing files changed:** `path` – what changes and why. <!-- or "none" -->

### 4.3 Shared contracts
<!-- Include only if multiple tasks must agree on an interface: types, function signatures,
     routes, schemas or shared file formats, written out exactly in the repo's language.
     Do not force a contract task or shared artifact format for analysis that needs none.
     Delete this section if inapplicable; nothing here may say TBD. -->

```
```

### 4.4 Data model
<!-- Entities, fields, invariants, storage if applicable. Delete if not needed. -->

### 4.5 Error handling
<!-- How each module reports and handles failure; what the user sees. -->

## 5. Build order

<!-- Hints for the planner. State only real dependencies: tools before consumers of their
     committed files, shared contracts before dependents if needed. Do not prescribe a
     fixed graph, additional slices or synthesis where the work needs none. -->

1. <actual dependency or independent work>

## 6. Verification

- **Setup command:** `...` <!-- only when applicable; for analysis without software,
     state "none" rather than inventing a stack or dependencies -->
- **Test runner and layout:** ... <!-- only when software needs tests; delete otherwise -->
- **Per-deliverable check:** `...` <!-- runnable acceptance suited to each requested output;
     software tests where applicable, not a fixed report validator -->
- **Whole-project check:** `...` <!-- if applicable; software build + tests when needed -->
- **Manual checks:** ... <!-- only what cannot be automated; keep short -->

## 7. Constraints

- **Stack:** language/runtime versions, frameworks, test runner, package manager, libraries allowed. New dependencies: which ones, or "none without approval". <!-- include only if software is needed; for a new coding project, the skeleton is generated from this and section 6. For a new analysis-only project, delete this line -->

- **Conventions:** style, naming, patterns to follow (point to an existing file when applicable).
- **Shared files:** files every task may touch, e.g. lock files, route or DI registries. <!-- become settings.shared -->

**Always**
- ...

**Stop and report blocked** <!-- agents run unattended: "ask first" means "don't do it; report blocked with the reason" -->
- ...

**Never**
- ...

## 8. Open questions

<!-- Must be empty (or say "None") before planning. Anything unresolved elsewhere is marked
     inline as [NEEDS CLARIFICATION: question] and listed here. -->
None.
