# Model reference

The controller picks each worker's model. Use the light model (Claude `haiku`;
OpenCode agent `worker-light`) for mechanical, low-risk work: docs, config, renames,
small fixes, tests for existing behavior. Use the strong model (`sonnet`;
`worker-strong`) for new logic, multi-file design, or security, data, concurrency,
migration, or public-contract risk. When unsure, use strong. Gate failures and verified
review blockers follow the repair rule in SKILL.md, Per phase step 3.

Claude passes `model` with `subagent_type: general-purpose`. OpenCode agents are
optional entries in the user's own `opencode.jsonc`; this repository never pins a
model. A missing model or agent → use the controller's model, note it in `metrics`,
and never HALT for it. Record each attempt's model in `metrics`.
