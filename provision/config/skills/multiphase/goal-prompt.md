Claude Code (type it yourself; `/goal` must come first):

```text
/goal Follow the multiphase skill using "<PLAN_PATH>" until it stops for done, a question, a review or approval handoff, a halt, or a denied permission. Before stopping, print the state path, status, and next step or reason. Never answer your own question.
```

OpenCode V2 (no `/goal`; plain prompt):

```text
Follow the multiphase skill using "<PLAN_PATH>". Stop when it reaches done,
pauses for human input, or halts.
```

`/goal` can only be typed by the user, and its evaluator reads only the transcript, so the line above makes the controller print its status before stopping. Every stop clears the goal; to resume, recall the line (up arrow) and append the answer.
