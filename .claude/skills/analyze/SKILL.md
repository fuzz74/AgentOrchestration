---
name: analyze
description: Run an analysis (not a development run) with the agent orchestrator, from interview to checked result, with the user answering questions and approving each step. It is the orch skill in analysis mode. Use when the user invokes /analyze, or wants an investigation run by the orchestrator with an interview.
---

# Analyze

You run the [orch](../orch/SKILL.md) skill on the user's request, in analysis mode, with the
user involved.

## Steps

1. Take the user's request (the skill arguments, or the message that asked for it) word for
   word.
2. Append this text to the end of it, word for word, on a new paragraph:

   ```
   mode: analysis
   ```

3. Run the orch skill with the combined text as its input. In Claude Code, invoke it with the
   Skill tool (`skill: orch`, `args`: the combined text). In other assistants, read
   [../orch/SKILL.md](../orch/SKILL.md) and follow it with the combined text as the user's
   request.
4. From then on, follow orch in analysis mode: `write-spec` runs the analysis interview, and
   every checkpoint in orch applies.
