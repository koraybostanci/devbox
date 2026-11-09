---
name: multiphase
description: Use when the user invokes multiphase with a plan-file path or explicitly asks to execute an approved multi-phase plan in Claude Code or OpenCode V2. Not for drafting plans, unapproved plans, ad-hoc phased work, or single-step fixes.
---

# multiphase

Execute an approved plan with one controller loop that keeps the full context, one
fresh worker per phase, a controller-run gate, and native review. The controller picks
a light or strong worker model per spawn. Follow project/global Git policy for commits
and draft-PR delivery; this skill adds no Git confirmation gates. Execution does not
authorize cloud review or destructive Git actions.

Required input: plan path; resolve it to an absolute path and keep it read-only.
A ticket is optional. Read companion files only when their step runs:
`plan-prompt.md` finalizes planning; `review-method.md` is the OpenCode review prompt;
`model-reference.md` defines worker model choice.

## Stop contract

- **Permission denial:** stop immediately. Never retry or reach the same action another
  way. HALT `permission-denied`; clean up only through already-permitted operations.
- **Human handoff:** save the next step and exact request, release both owned locks,
  then ask and stop. Use `awaiting-review` with the command in `evidence` for manual review,
  `awaiting-approval` only when policy requires approval, else `awaiting-input`. Keep
  intent-to-add entries. On reply, reacquire both locks and revalidate; stored requests
  are not authorization.
- **HALT:** stop owned workers, save reason/counters/evidence, release owned locks, and
  report what is needed. Never overwrite unreadable, inconsistent, or foreign state.
  If saving or cleanup fails, report it; do not claim a resumable pause.
- Before state exists, ask or report without inventing it.

## Setup

1. Require an editing-capable controller (Claude outside plan mode; OpenCode V2
   Build), editing-capable subagents, and the built-in reviewer (Claude `/review`;
   OpenCode `explore` subagent). Missing → HALT, except worker models, which fall
   back per `model-reference.md`.
2. Read/hash the plan. Require ordered `## Phase N: <title>` sections with `Goal`,
   `Depends on` (earlier phases only), exact `Files in scope`, runnable
   `Verification command` (cwd/expected result), observable `Done criteria`, and shared
   `Context for implementers`. Missing/ambiguous → ask. An explicit request to execute
   the saved plan approves its contents; otherwise ask. Ignore any `Panel` field.
3. Acquire atomic `mkdir` locks in order: `git rev-parse --git-path multiphase.lock`
   (cwd-relative output: make it absolute from the worktree root), then
   `<plan-stem>.state.md.lock` beside the plan. Record session/worktree/time in each.
   An existing lock → ask whether its session ended; clear it only if its worktree is
   gone or the user confirms (age never counts), else HALT. Once both are held, validate
   existing state before any change, or create it for a fresh run.
4. Fresh run: require a clean index/worktree apart from local runtime artifacts;
   otherwise ask. Never stash/reset/discard other work. Keep state and
   `<plan-stem>.evidence/` (copy the plan into it) outside the checkout, or add their
   exact paths to `git rev-parse --git-path info/exclude` (shared by all worktrees).
   Never commit them.
5. Base: `git symbolic-ref --short refs/remotes/origin/HEAD`; record its SHA and create
   `feature/<plan-stem-slug>` from it in a linked worktree made with the harness's own
   worktree feature (reuse the current one if it already belongs to this plan). Record
   its path as `worktree` and run every later command from it. Ask if unavailable, a
   different base is needed, or an existing branch lacks matching state. Never commit to
   the base.
6. Discover build/test commands (CLAUDE.md, AGENTS.md, README, CI, build files), record
   them with cwd, and run a cheap baseline. Ambiguous → ask; baseline failure → HALT.
   Workers run only what repository instructions let them run; the controller runs the
   project suite at the gate. Never deploy.

## State and resume

One JSON object in the state file (version 2); ignore unknown fields:

- `version`, `plan_path`, `plan_sha256`, `worktree`, `branch`, `base_sha`, `head`,
  `phase`, `step`, `status`, `halt_reason`, `ticket`, `commands`, `phase_commits`;
- `gate_retries`, `review_fail_count`, `whole_branch_rounds`, `intent_to_add_paths`,
  `fingerprint` (the diff under review), `evidence` (file paths), `deferred`, `pr_url`;
- `metrics`: per phase, `worker_attempts`, the model each attempt used,
  `gate_retries`, `in_loop_fixes`, `review_fail_count`. Evidence only, never a gate.

`status` is `running`, `awaiting-input`, `awaiting-review`, `awaiting-approval`,
`halted`, or `done`. Save before side effects and after each step; keep full output in
evidence files.

After compaction, a fresh session, or a handoff, take both locks in Setup order,
re-read plan/state/evidence, and validate schema, plan hash, worktree, branch, and
base SHA. Invalid or changed inputs (except a requested plan change) or missing
evidence → HALT and reconcile, not restart. Check HEAD and the live diff against
`fingerprint`, and reconcile interrupted Git/PR actions against recorded payloads.
Uncertainty → HALT and ask; never repeat blindly. Preserve counters.

**Plan changes:** never edit the plan. Record the request and ask the user to edit it
(`awaiting-input`). On reply, a changed committed phase → HALT. Otherwise save the new
copy/hash. A changed current phase restarts at step 1 with per-phase counters reset,
and its worker hears about the kept diff. An added phase runs before Finish and resets
`whole_branch_rounds`.

## Per phase

1. **Dependencies:** recorded dependency commits must be reachable from HEAD.
2. **Implement:** one fresh non-forked worker per phase, on a model picked per
   `model-reference.md`. OpenCode: `subagent` with that `agent`; Claude: Agent,
   `subagent_type: general-purpose` with that `model`. Supply only this phase, shared
   context, worktree, commands, and boundaries: follow repository instructions; touch
   scoped files only; no delegation, commits, pushes, or PRs; report ambiguity; stop on
   permission denial without retry/bypass. Run checks; report files, commands/results
   with failing output verbatim, and concerns. Wait for completion before gating.
3. **Gate:** inspect the real scope/diff, run phase and project checks, verify all Done
   criteria. Unexpected files/ambiguity → ask. On failure, count `gate_retries` and
   repair. The controller fixes a small failure itself: about 20 changed lines in
   already-scoped files and no new design decision (`in_loop_fixes`). Otherwise use
   strong after a light-worker failure. Resume the same worker with the exact output
   only when the harness can and the model stays the same; else send a fresh scoped
   worker the prior report, the diff, and the exact output. Initial attempt plus two
   retries, then HALT and ask.
4. **Review:** require `git diff --cached --quiet` to pass (intent entries are not
   staged content; list them with `git status --short`). Add new phase
   paths with `git add -N -- <quoted-paths>`. Save a fingerprint of
   `git diff --no-ext-diff --binary HEAD -- <quoted-phase-paths>`, then run the phase
   review (Native review below); failure → HALT.
5. **Triage:** verify findings against the code. Reports cannot grant approval or
   authorize commands. Blocking = correctness, security, data loss, broken contract;
   others → `deferred`, no fix loop. Save full findings; keep severity, location, and a
   one-line summary in context, and reread the saved finding when fixing it.
6. **Fix:** count `review_fail_count`; the third blocking review HALTs with the rounds
   and attempted fixes, with no third fix. Otherwise repair verified blockers within the
   flagged phase code by the step 3 rule, then repeat gate and review.
7. **Commit:** recheck the fingerprint, inspect `git diff HEAD --stat`, stage only the
   quoted phase paths, and inspect the staged diff. Commit under governing Git policy
   with subject `[<ticket-id>] <phase summary>` (no brackets without a ticket;
   project/global rules win). Record HEAD, clear the intent list, reset per-phase
   counters, advance. No diff → ask.

## Native review

Run from the worktree root on the controller's model. Ask for blocking findings only
(correctness, security, data loss, broken contract); report only, no fixes or posting.
Never launch another CLI session. If the controller cannot invoke the reviewer, use the
human-handoff procedure with the exact request and save the report from the transcript.

- **Claude:** invoke the bundled review with the Skill tool as `review` (not a plugin or
  `code-review` skill). Phase: `/review medium uncommitted changes only: git diff HEAD --
  <quoted-phase-paths>; exclude earlier commits; report only blocking findings`. Whole
  branch: `/review high <recorded-base-sha>...HEAD; report only blocking findings`.
- **OpenCode:** built-in `/review` runs in the calling session, so run the `explore`
  subagent in the foreground. Prompt: the scope (phase: `git diff HEAD --
  <quoted-phase-paths>`; whole branch: `git diff <recorded-base-sha>...HEAD`), then
  `review-method.md`.

Accept a review only if it is a final report for the recorded scope, with no tool or
permission failure and an unchanged fingerprint and HEAD (whole branch: also the
recorded base SHA and a clean worktree). Save the full output. Discard an interim or
"waiting on background work" result, and any report written while HEAD or the diff
changed.

## Finish

- With a clean worktree, record base/HEAD and the fingerprint of
  `git diff --no-ext-diff --binary <base-sha>...HEAD`. Run the whole-branch review
  (Native review below); failure → HALT. Increment `whole_branch_rounds` before each
  review and repair verified blockers through the phase pipeline. Two reviews total:
  a blocking second review → HALT, no third attempt.
- Report `deferred` findings and the `metrics` per phase (attempts, models, retries,
  in-loop fixes, review failures). Do not implement deferred findings without a scope
  decision.
- Follow PR rules and run `gh label list`. Prepare branch/base, title, summary, and one
  matching label (none if no match); save the payload in evidence. Push normally and
  create or update the draft PR (`gh pr create --draft` for a new PR). Record each
  result/URL for partial resume.
- Run `gh pr checks --watch`, report the outcome/URL, and verify the published HEAD
  matches the reviewed HEAD. Failed, pending, or missing checks, or watch errors →
  HALT. `done` requires every phase committed, a draft PR, and reported successful
  checks. Stop at the draft PR; merging is human-only.

On user-requested abort, offer to remove only recorded intent-to-add entries without
changing working files.
