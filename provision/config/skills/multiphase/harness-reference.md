# Harness reference

## Planning → build

Use `plan-prompt.md` in Claude plan mode or OpenCode's Plan agent. After approval,
paste the path-only handoff into Claude outside plan mode or OpenCode Build.
Both discover `~/.claude/skills/multiphase`. Claude also supports
`/multiphase <plan-path>`; OpenCode supports `@multiphase` with the plan path.
The plain `goal-prompt.md` works in both; only Claude supports a `/goal` prefix.

## Native review

Use the harness's native reviewer from the worktree root with the controller's
model: Claude's built-in `/review` or OpenCode's `reviewer` subagent. Request a
report only: no fixes, posting, or cloud review. Never launch another CLI session
or a substitute reviewer. If the controller cannot invoke the native reviewer, use
the skill's human-handoff procedure with the exact request.

For both review stages, require a completed report for the recorded scope, no
tool/permission failures, and an unchanged diff fingerprint and HEAD. Whole-branch
review also requires the recorded base SHA and a still-clean worktree. Save the
full output; an acknowledgement is not a completed review.

### Claude Code

Invoke bundled `review` through the **Skill** tool. `/review` is the built-in
`/code-review` alias, even when a custom skill overrides `code-review`.

```text
/review medium uncommitted changes only against HEAD (git diff HEAD); exclude earlier commits
/review max <recorded-base-sha>...HEAD
```

The first command targets the phase; the second targets the whole branch.
Wait for the native review to finish, including when it runs in the background.
Without an explicit target, Claude also reviews earlier branch commits.

### OpenCode V2

Built-in `/review` always runs in the calling session, so use the global
`reviewer` subagent from `scripts/sync.sh`. Run it in the foreground with the
`subagent` tool, `agent: reviewer`, and the exact scope:

- phase: uncommitted changes, `git diff HEAD -- <quoted-phase-paths>`;
- whole branch: `git diff <recorded-base-sha>...HEAD`.

Missing `reviewer` agent → HALT and ask the user to run `scripts/sync.sh`.

References: [Claude review](https://code.claude.com/docs/en/code-review-local),
[OpenCode commands](https://opencode.ai/v2/docs/commands/).
