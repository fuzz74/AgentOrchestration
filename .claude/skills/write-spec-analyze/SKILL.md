---
name: write-spec-analyze
description: Write a spec for an analysis run of the agent orchestrator together with the user, by interview. It is the write-spec skill in analysis mode and stops after the spec. Use when the user invokes /write-spec-analyze, or wants to write or improve a spec for an investigation.
---

# Write a spec for an analysis

You run the [write-spec](../write-spec/SKILL.md) skill on the user's request, in analysis
mode. It stops at its hand-off: planning and running are not part of this skill (`/analyze`
does the whole flow).

## Steps

1. Take the user's request (the skill arguments, or the message that asked for it) word for
   word.
2. Append this text to the end of it, word for word, on a new paragraph:

   ```
   mode: analysis
   ```

3. Run the write-spec skill with the combined text as its input. In Claude Code, invoke it
   with the Skill tool (`skill: write-spec`, `args`: the combined text). In other assistants,
   read [../write-spec/SKILL.md](../write-spec/SKILL.md) and follow it with the combined text
   as the user's request.
