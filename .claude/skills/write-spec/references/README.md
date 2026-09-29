# Upstream references for write-spec

Unmodified copies of the upstream material that `/write-spec` borrows from. The skill itself
(`../SKILL.md`, `../spec-template.md`, `../reviewer-prompt.md`) is adapted to this orchestrator;
these files are kept so the source is at hand when the skill is revised. Both projects are MIT
licensed; their licenses sit next to the copies.

| Folder | Source | Commit | Taken for |
| --- | --- | --- | --- |
| `superpowers/` | [obra/superpowers](https://github.com/obra/superpowers) `skills/brainstorming/` | `8ca22dba9a94f28898bbce59f2537ff4d87c747d` | Interview flow: one question at a time, 2-3 approaches, design approved section by section, spec self-review, approval gate, decomposing oversized projects. |
| `cc-sdd/` | [gotalab/cc-sdd](https://github.com/gotalab/cc-sdd) `.kiro/settings/` | `e2a0c671aef37a482404905b409ab5c27092b25b` | EARS acceptance criteria, numeric requirement IDs, File Structure Plan as the source of task boundaries, contracts first, review gates with mechanical checks, parallel-safety rules. |

`brainstorming-SKILL.md` is renamed from `SKILL.md` so Claude Code does not load it as a
separate skill.

Other sources consulted but not copied:

- [GitHub Spec Kit](https://github.com/github/spec-kit): `[NEEDS CLARIFICATION]` markers instead of guesses.
- [Harper Reed, "My LLM codegen workflow atm"](https://harper.blog/2025/02/16/my-llm-codegen-workflow-atm/): "Ask me one question at a time so we can develop a thorough, step-by-step spec."
- [Addy Osmani, "How to write a good spec for AI agents"](https://addyosmani.com/blog/good-spec/): what and why over how; always / ask first / never boundaries; checks the agent can run itself.
