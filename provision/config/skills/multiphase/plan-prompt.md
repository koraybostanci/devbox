Finalize the plan for a fresh Claude Code or OpenCode V2 build session. Do not implement.

Resolve open questions with me.
Use ## Phase N: <title> headings. Each phase needs Goal, Depends on, exact Files in scope, a runnable Verification command (cwd and expected result), and observable Done criteria. Keep each phase small enough for one review.
Add Context for implementers with the decisions, constraints, risks, and project build/test commands. Workers receive only their phase and this shared context.
Unless every phase meets the skip rule in the multiphase skill's panel-reference.md, run a planning panel on the draft; show me the roster and ask whether to add or remove experts.
Give each phase Panel: none or 2–3 <aspect>: <agent|default>[, skills: <names>] entries. Record the panel's decisions and dissent in ## Planning panel.
Save the plan using the harness-supported path, show me its absolute path and any remaining uncertainty, and ask for approval.
After approval, give me the handoff for a fresh build session; do not start it. Use my harness's line from the skill's goal-prompt.md with the absolute plan path.
