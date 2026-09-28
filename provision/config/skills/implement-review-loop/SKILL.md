---
name: implement-review-loop
description: Use only when the user explicitly requests an implementation and independent review loop. Uses named OpenCode subagents and a parent-mediated bounded loop.
---

# Implement-Review Loop

Run this loop in the current OpenCode session. The main agent owns the task,
worktree, verification, user communication, and publication approvals. It
launches named child subagents; they are separate sessions, not concurrent
writers to one terminal.

## Invariants

- Inspect `git status --short`, record `BASE_REF=$(git rev-parse HEAD)`, and
  agree explicit repository-relative paths in scope before delegating.
- Never overwrite, stage, revert, or include unrelated changes. An existing
  in-scope change, changed base ref, missing result, malformed result, or
  failed verification is never approval.
- Run only one worker at a time because implementer and reviewer share the
  current worktree.
- The implementer edits only the agreed scope. The reviewer is read-only.
  Neither worker may spawn another agent, commit, push, or create a PR.
- The parent mediates every handoff. Do not let workers message or prompt each
  other directly.
- Limit the loop to five implementation attempts and ten reviewer findings.
  On a blocker, ambiguity, or exhausted limit, stop and ask the user.
- Before the first handoff, verify that every required worker role can launch
  with its effective model.
- Before reviewer dispatch, record a scoped diff fingerprint and worktree
  status. Compare both after the reviewer returns; never accept a result if the
  worktree changed during its review.

## Roles

- `loop-implementer`: implementation subagent. Use it only for the initial
  implementation and bounded revisions.
- `loop-reviewer`: read-only review subagent. Use it by default.
- `loop-reviewer-deep`: deep read-only review subagent. Use it only for
  authentication, migrations, infrastructure, schemas, or explicit deep review.

The roles are visible `mode: subagent` agents. The parent may launch only these
roles; the roles themselves cannot launch child subagents.

## Configuration and Resumption

- When a role cannot launch because its configured model is unavailable, do not
  substitute another role or continue the loop manually. Update the managed
  agent configuration, restart OpenCode, and revalidate the effective
  configuration before resuming.
- Record the base ref, allowed paths, current phase, implementation-attempt
  count, reviewer-finding count, and scoped diff fingerprint before a restart.
  In the new session, revalidate those values and resume at the interrupted
  phase. The existing scoped diff remains unapproved until the required review
  and final checks succeed.
- Count the initial implementation as attempt one; every revision consumes one
  additional attempt. The ten-finding limit spans the entire loop.
- If the attempt limit is reached, ask before any extra work. A user's approval
  for one exception authorizes only that named, bounded pass. A new reviewer
  finding requires a new explicit exception.

## Loop

1. Verify required roles are launchable, then launch `loop-implementer` to perform the task. Include the task, base ref,
   allowed paths, required checks, the round number, and a prohibition on
   publication. Require `IMPLEMENTATION_READY` with changed files and concise
   verification evidence, or `IMPLEMENTATION_BLOCKED` with a reason.
2. Independently run `git diff --check`, inspect `git status --short`, and
   verify the base ref and scope. Record the scoped diff fingerprint and do not
   review if these checks fail.
3. Launch `loop-reviewer` or `loop-reviewer-deep` to review the current scoped
   diff against the recorded base. Include the task, allowed paths, changed
   files, and any relevant test result. Require exactly one of
   `REVIEW_APPROVED`, `REVIEW_CHANGES_REQUESTED`, or `REVIEW_BLOCKED`.
4. A reviewer finding must include severity, path, line, and actionable issue.
   A reviewer approval must contain no findings. The parent verifies the current
   Git state is unchanged since dispatch before accepting either result.
5. On requested changes, confirm that an implementation attempt remains, then
   relay only the bounded findings to a new `loop-implementer` subagent. Do not
   paste full worker history. Repeat from step 2 with a new review.
6. On approval, run final deterministic checks. If they fail or the scoped diff
   changed, invalidate approval and return the evidence to the implementer.
7. Only after final verification may the main agent prepare publication. Follow
   the active repository instructions and obtain explicit user approval for
   every commit, push, and PR action.

## Result Handling

Subagent completion and an idle child session are only lifecycle observations. The
parent accepts a worker result only when it matches the active role and round.
If a worker returns an empty or malformed result, ask that same worker once to
reprint its result without doing more work; otherwise stop for the user.

A task-launch error (for example, an unavailable model) has no worker result.
Treat it as a configuration blocker under Configuration and Resumption; it is
not an implementation attempt or reviewer result, and no other worker may
perform its role.

Do not paste a large diff into a subagent prompt. For a large change, tell the
reviewer to inspect the scoped Git diff and relevant source files directly. If
the changed scope is too broad to review meaningfully, stop and split the work
instead of raising the context limit.
