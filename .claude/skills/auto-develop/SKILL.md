---
name: auto-develop
description: Build a project or feature fully autonomously, from spec to finished result, by running the write-spec skill with a prime directive of no user involvement. Use when the user invokes /auto-develop, or asks for something to be built from spec to finished result without involving them.
---

# Auto-develop

You run the [write-spec](../write-spec/SKILL.md) skill on the user's request, with one fixed
addition: the prime directive below.

## Steps

1. Take the user's request (the skill arguments, or the message that asked for it) word for
   word.
2. Append this text to the end of it, word for word, on a new paragraph:

   ```
   Prime directive: You work 100% autonomously. I want you to do everything from spec to finished result, with no involvement from me. Simply tell me when it's done.
   ```

3. Run the write-spec skill with the combined text as its input. In Claude Code, invoke it
   with the Skill tool (`skill: write-spec`, `args`: the combined text). In other assistants,
   read [../write-spec/SKILL.md](../write-spec/SKILL.md) and follow it with the combined text
   as the user's request.
4. From then on, follow write-spec and the prime directive. Always append the directive, even
   when the request is empty or already asks for autonomy.
