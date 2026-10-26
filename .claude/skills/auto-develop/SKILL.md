---
name: auto-develop
description: Build a project or feature fully autonomously, from spec to a checked result, by running the orch skill with a prime directive of no user involvement. It stops before merging. Use when the user invokes /auto-develop, or asks for something to be built from spec to finished result without involving them.
---

# Auto-develop

You run the [orch](../orch/SKILL.md) skill on the user's request, with one fixed addition: the
prime directive below. `orch` then writes the spec, plans, runs and fixes failed tasks without
asking, and stops before the merge.

## Steps

1. Take the user's request (the skill arguments, or the message that asked for it) word for
   word.
2. Append this text to the end of it, word for word, on a new paragraph:

   ```
   Prime directive: You work 100% autonomously. I want you to do everything from spec to finished result, with no involvement from me. Simply tell me when it's done.
   ```

3. Run the orch skill with the combined text as its input. In Claude Code, invoke it with the
   Skill tool (`skill: orch`, `args`: the combined text). In other assistants, read
   [../orch/SKILL.md](../orch/SKILL.md) and follow it with the combined text as the user's
   request.
   If the request contains `mode: analysis`, keep it word for word: orch passes the mode on.
4. From then on, follow orch and the prime directive. Always append the directive, even when
   the request is empty or already asks for autonomy. The finished result is the checked run
   on the integration branch: merging it stays the user's decision, as orch says.
