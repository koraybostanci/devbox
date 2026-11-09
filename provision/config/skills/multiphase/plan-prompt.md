Finalize the plan for a fresh Claude Code or OpenCode V2 build session. Do not implement.

- Resolve open questions with me.
- Use `## Phase N: <title>` headings. Each phase needs Goal, Depends on, exact Files in scope, a runnable Verification command (cwd and expected result), and observable Done criteria. Keep each phase small enough for one review.
- Add `Context for implementers` with the decisions, constraints, risks, and project build/test commands. Workers receive only their phase and this shared context.
- Before asking for approval, run one fresh read-only subagent (Claude `Explore`; OpenCode `explore`) on the draft. Ask it for blocking defects only, checking each item: dependencies point to earlier phases only; scopes are exact files and do not overlap; each verification is runnable with cwd and expected result and proves its own Done criteria; Done criteria are observable; shared context is sufficient; unsafe data, public-contract, concurrency or operational changes; consumers or writers the plan does not list; phase size fits one review. Fix what it finds once; do not run further rounds.
- Save the plan using the harness-supported path, show me its absolute path and any remaining uncertainty, and ask for approval.
- After approval, give me the handoff for a fresh build session; do not start it. Use my harness's line from the skill's `goal-prompt.md` with the absolute plan path.
