# <Feature or project name>

<!-- Guidance comments like this one are for the author. Delete them all in the final spec:
     the whole spec is pasted into the planner's, every worker's and every reviewer's prompt. -->

## 1. Summary

<!-- 3-6 sentences. What is being built, for whom, and why. What "done" looks like from the
     user's point of view. No implementation detail. -->

## 2. Scope

**In scope**
- ...

**Out of scope**
<!-- Anything a capable agent might reasonably add on its own but should not. -->
- ...

## 3. Requirements

<!-- Numbered areas; criteria numbered N.M. Every criterion uses an EARS pattern and describes
     one observable, testable behaviour. Task prompts and reviewers cite these ids. -->

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
<!-- This table becomes the task split: paths become `owns`, "Uses" becomes `deps`.
     Paths are repo-relative globs with forward slashes. Two modules that should be built in
     parallel must not share a path. Tests live inside the module's own paths. -->

| Module | Responsibility | Paths | Uses | Requirements |
| --- | --- | --- | --- | --- |
| contracts | Shared types and interfaces from 4.3 | `src/types/**` | – | – |
| ... | ... | `src/.../**` | contracts | 1.1-1.3 |

**Existing files changed:** `path` – what changes and why. <!-- or "none" -->

### 4.3 Shared contracts
<!-- Everything two or more modules must agree on, written out exactly: type definitions,
     function signatures, API routes with request/response shapes and status codes, DB schema,
     event payloads, file formats, error types. Use real code blocks in the repo's language.
     This section becomes the first task; nothing here may say TBD. -->

```
```

### 4.4 Data model
<!-- Entities, fields, invariants, storage. Delete the section if nothing is stored. -->

### 4.5 Error handling
<!-- How each module reports and handles failure; what the user sees. -->

## 5. Build order

<!-- Hints for the planner. What must exist first (contracts, schema, scaffolding), which
     modules can then be built side by side, and what glue or wiring comes last. -->

1. ...
2. In parallel: ...
3. Last: ...

## 6. Verification

- **Setup command:** `...` <!-- installs dependencies in a fresh worktree, e.g. `npm ci` -->
- **Test runner and layout:** ... <!-- e.g. vitest, tests next to sources as *.test.ts -->
- **Per-module check:** `...` <!-- how to run one module's tests, e.g. `npm test -- src/<module>` -->
- **Whole-project check:** `...` <!-- build + full test suite; becomes integrationCheck -->
- **Manual checks:** ... <!-- only what cannot be automated; keep short -->

## 7. Constraints

- **Stack:** language/runtime versions, frameworks, libraries allowed. New dependencies: which ones, or "none without approval".
- **Conventions:** style, naming, patterns to follow (point to an existing file as the example).
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
