Claude Code (type it yourself; `/goal` must come first):

```text
/goal Follow the multiphase skill using "<PLAN_PATH>" until it stops for done, a question, a review or approval handoff, a halt, or a denied permission. Before stopping, print the state path, status, and next step or reason. Never answer your own question.
```

OpenCode V2 (no `/goal`; plain prompt):

```text
Follow the multiphase skill using "<PLAN_PATH>". Stop when it reaches done,
pauses for human input, or halts.
```
