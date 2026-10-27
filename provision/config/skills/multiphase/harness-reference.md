# Harness reference

## Planning → build

Use `plan-prompt.md` in Claude plan mode or OpenCode's Plan agent. After approval,
paste the `goal-prompt.md` line into Claude outside plan mode or OpenCode Build.
Both discover `~/.claude/skills/multiphase`. Claude also supports
`/multiphase <plan-path>`; OpenCode supports `@multiphase` with the plan path.

## Goal activation

Only the user can type `/goal`, so hand off the Claude line from `goal-prompt.md`.
Its evaluator reads only the transcript, so print the status before stopping. Every
stop clears the goal; to resume, recall the `/goal` line (↑) and append any answer.
Use auto mode for unattended runs. Without `/goal` or in OpenCode, use the plain
prompt.

## Panels

Members: Claude `Agent` with a listed `subagent_type`, else `Explore`; OpenCode
`subagent` with a configured `agent`, else `explore`. Use `general-purpose`/`general`
only for a skill the read-only type cannot load. Run members in the foreground.

## Native review

Use the harness's native reviewer from the worktree root with the controller's
model: Claude's built-in `/review` or OpenCode's `reviewer` subagent. Request a
report only: no fixes, posting, or cloud review. Never launch another CLI session
or a substitute reviewer. If the controller cannot invoke the native reviewer, use
the skill's human-handoff procedure with the exact request, then save the report
from the transcript.

For both review stages, require a completed report for the recorded scope, no
tool/permission failures, and an unchanged diff fingerprint and HEAD. Whole-branch
review also requires the recorded base SHA and a still-clean worktree. Save the
full output; an acknowledgement is not a completed review.

### Claude Code

Invoke the bundled review with the Skill tool as `review`, never `code-review` or a
custom/plugin review skill: `/review` always runs the bundled one.

```text
/review medium uncommitted changes only: git diff HEAD -- <quoted-phase-paths>; exclude earlier commits
/review max <recorded-base-sha>...HEAD
```

The first command targets the phase; the second targets the whole branch.
Wait for the native review to finish, including when it runs in the background.
Without an explicit target, Claude also reviews earlier branch commits.

### OpenCode V2

Built-in `/review` always runs in the calling session, so use the global
`reviewer` subagent that devbox provisioning syncs (`provision/config/opencode/
agents`, delivered to `~/.config/opencode/agents` on `devbox start`/`provision`).
Run it in the foreground with the `subagent` tool, `agent: reviewer`, and the
exact scope:

- phase: uncommitted changes, `git diff HEAD -- <quoted-phase-paths>`;
- whole branch: `git diff <recorded-base-sha>...HEAD`.

Missing `reviewer` agent → HALT and ask the user to run `devbox provision`.

References: [Claude review](https://code.claude.com/docs/en/code-review-local),
[OpenCode commands](https://opencode.ai/v2/docs/commands/).
