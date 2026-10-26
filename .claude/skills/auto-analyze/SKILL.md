---
name: auto-analyze
description: Run an analysis fully autonomously, from spec to a checked result, by running auto-develop in analysis mode. It stops before merging. Use when the user invokes /auto-analyze, or asks for an investigation to be run from spec to finished result without involving them.
---

# Auto-analyze

You run the [auto-develop](../auto-develop/SKILL.md) skill on the user's request in analysis
mode. It owns the autonomy directive and the stop-before-merge behaviour.

## Steps

1. Take the user's request (the skill arguments, or the message that asked for it) word for
   word.
2. Append this text to the end of it, word for word, on a new paragraph:

   ```
   mode: analysis
   ```

3. Run the auto-develop skill with the combined text as its input. In Claude Code, invoke it
   with the Skill tool (`skill: auto-develop`, `args`: the combined text). In other assistants, read
   [../auto-develop/SKILL.md](../auto-develop/SKILL.md) and follow it with the combined text as the user's
   request.
