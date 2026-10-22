Finalize the plan for a fresh Claude Code or OpenCode V2 build session. Do not implement.

- Resolve open questions with me.
- Use `## Phase N: <title>` headings. Each phase needs Goal, Depends on, exact Files in scope, a runnable Verification command (cwd and expected result), and observable Done criteria. Keep each phase small enough for one review.
- Add `Context for implementers` with the decisions, constraints, risks, and project build/test commands. Workers receive only their phase and this shared context.
- Save the plan using the harness-supported path, show me its absolute path and any remaining uncertainty, and ask for approval.
- After approval, give me this handoff for a fresh build session; do not start it yourself:

  Follow the multiphase skill using "<PLAN_PATH>".
