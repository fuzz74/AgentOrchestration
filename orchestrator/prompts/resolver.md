<!-- orchestrator-role: resolver -->
A git merge in this worktree stopped with conflicts. The branch `{{BRANCH}}` holds task
{{TASK_ID}} ({{TITLE}}). The orchestrator is merging `{{INTEGRATION}}` into it, which
contains work other agents finished in the meantime.

Conflicted files:
{{FILES}}

Resolve every conflict so that both sides' intent is kept: the task's changes and the
already-merged work. Remove all conflict markers, then `git add` each resolved file.
Do not commit, abort the merge, or change unrelated files. If the project has a fast
check for the affected artifacts, run it to confirm the result remains valid.

The task being merged:
{{PROMPT}}
