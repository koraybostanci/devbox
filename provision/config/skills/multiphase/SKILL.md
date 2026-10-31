---
name: multiphase
description: Use when the user invokes multiphase with a plan-file path or explicitly asks to execute an approved multi-phase plan in Claude Code or OpenCode V2. Not for drafting plans, unapproved plans, ad-hoc phased work, or single-step fixes.
---

# multiphase

Execute an approved plan with fresh implementers, verification, and native review.
Follow project/global Git policy for commits and draft-PR
delivery; this skill adds no Git confirmation gates. Execution does not authorize
cloud review or destructive Git actions.

Required input: plan path; resolve it to an absolute path and keep it read-only.
A ticket is optional. Companion paths are relative to this skill:
`plan-prompt.md` finalizes planning; `harness-reference.md` defines goal activation
and native review; `panel-reference.md` defines advisory expert panels.

## Stop contract

- **Permission denial:** stop immediately. Never retry or obtain the same action
  through rephrasing, another tool/mode, or changed permissions. HALT
  `permission-denied`; clean up only through already-permitted operations.
- **Human handoff:** save the next step and exact request, release both owned
  locks, verify their removal, then ask and stop. Use `awaiting-review` with the
  command in `evidence` for manual review; `awaiting-approval`/`pending_approval`
  only when governing policy requires approval; `awaiting-input` otherwise. Keep
  intent-to-add entries.
  On reply, reacquire locks and revalidate; stored requests are not authorization.
- **HALT:** stop owned workers, save reason/counters/evidence, release owned locks,
  and report what is needed. Never overwrite unreadable, inconsistent, or
  foreign-owned state. If saving/cleanup fails, report unsaved state or held locks;
  do not claim a resumable pause.
- Before state exists, ask or report without inventing it.

## Setup

1. Require an editing-capable controller (Claude outside plan mode; OpenCode V2
   Build), fresh editing-capable subagents, and the native reviewer (Claude
   `/review`; OpenCode `reviewer` subagent) from `harness-reference.md`. Missing
   capability/model/prerequisite → HALT. Never use a substitute reviewer.
2. Read/hash the plan. Require ordered `## Phase N: <title>` sections with `Goal`,
   `Depends on` (earlier phases only), exact `Files in scope`, runnable
   `Verification command` (cwd/expected result), observable `Done criteria`, and
   shared `Context for implementers`. Missing/ambiguous content → ask. An optional
   `Panel` field follows `panel-reference.md`.
3. An explicit user request to execute the saved plan approves its current contents.
   Otherwise ask for approval. Hashes are internal metadata, never user inputs or
   approvals. Resolve project/global ticket requirements before the action needing one.
4. Read/validate existing `<plan-stem>.state.md` beside the plan before mutation;
   on a fresh run, create it once both locks are held.
   Acquire atomic `mkdir` locks in order: canonical per-worktree
   `git rev-parse --git-path multiphase.lock`, then `<state-path>.lock`. Record
   session ID/worktree/time in each; retain only locks this controller still owns.
   Other existing lock → ask whether its session ended; clear it only if its worktree
   is gone or the user confirms (age never counts), else HALT.
5. Fresh run: require a clean index/worktree apart from local runtime artifacts and
   an untracked plan; otherwise ask.
   Never stash/reset/discard other work. Keep artifacts (state, locks,
   `<plan-stem>.evidence/` beside the plan, an untracked plan) outside the checkout
   or add exact untracked paths to
   `git rev-parse --git-path info/exclude`, preserving existing entries; copy the
   plan into evidence. Tracked artifacts → ask; never commit state/evidence.
6. Resolve base using `git symbolic-ref --short refs/remotes/origin/HEAD`, record
   its SHA, and create `feature/<plan-stem-slug>` from that ref. Ask if unavailable,
   a different base is needed, or an existing branch lacks matching state. On
   resume, never switch away from inconsistent/dirty state. Never commit to the base.
7. Discover build/test commands from CLAUDE.md, AGENTS.md, README, CI, then build
   files. Record exact commands/cwd and run a cheap baseline check. Ask if
   ambiguous; baseline failure → HALT. Phase checks supplement the project suite.
   Never deploy during validation.

## Checkpoint and resume

Keep one JSON object in the state file (version 2):

- `version: 2`, `plan_path`, `plan_sha256`, `worktree`, `harness`, `model`;
- `branch`, `base_ref`, `base_sha`, `head`, `phase`, `step`, `status`, `halt_reason`;
- `ticket` (ID/URL or null), `commands`, `phase_commits`;
- `gate_retries`, `review_fail_count`, `whole_branch_rounds`, `intent_to_add_paths`;
- `panel_calls` `{run, phase}`, `panel_skipped` (budget skips); absent in older v2
  state → empty. Per-phase counters: `gate_retries`, `review_fail_count`,
  `panel_calls.phase`;
- `evidence` (command results, review outputs, diff fingerprint, findings
  per round), `deferred`, `pending_approval` (action/exact payload or null), `pr_url`.

Record the next `step` and `status`: `running`, `awaiting-input`, `awaiting-review`,
`awaiting-approval`, `halted`, or `done`. Save before side effects and after each
step. Keep full evidence in files; record only intent entries this controller created.

After compaction, a fresh session, or a handoff, re-read plan/state/evidence and
acquire locks before mutation. Validate schema, plan hash, worktree, branch, and
base SHA; invalid/changed inputs (except a requested plan change) or missing
evidence → HALT and reconcile, not restart. Check HEAD and the live diff
fingerprint, reconciling interrupted Git/PR
actions against recorded payloads and live results. Record only confirmed outcomes;
unexplained changes or uncertainty → HALT and ask, never repeat blindly. Preserve
counters. Re-present only approvals required by current policy; clear obsolete
requests for permitted routine actions after revalidation. Direct replies cover
only unchanged payloads.

**Plan changes:** never edit the plan. Record the request and ask the user to edit
it (`awaiting-input`). On reply, a changed committed phase section → HALT.
Otherwise save the new copy/hash. A changed current phase restarts at step 1 with
per-phase counters reset, and its worker hears about the kept diff; else continue
where you stopped. An added phase runs before Finish and resets
`whole_branch_rounds`.

## Per phase

1. **Dependencies:** recorded dependency commits must be reachable from HEAD.
2. **Design panel** (unless `Panel: none` or over budget) per `panel-reference.md`;
   save agreed constraints.
3. **Implement:** one fresh non-forked worker per attempt, never resumed. OpenCode:
   `subagent`, `agent: general`; Claude: Agent, `subagent_type: general-purpose`, `model: sonnet`.
   Supply only this phase, shared context, panel constraints, worktree, commands,
   and boundaries:
   follow repository instructions; touch scoped files only; no delegation, commits,
   pushes, or PRs; report ambiguity; stop on permission denial without retry/bypass.
   Run checks; return ≤150 words: files, commands/results, concerns or denied request.
   Wait for completion before gating.
4. **Gate:** inspect actual scope/diff, run phase and project checks, verify all Done
   criteria. Unexpected files/ambiguity → ask. On failure, persist `gate_retries`
   and send exact output to a fresh scoped worker. Initial attempt plus two retries
   maximum, then HALT; workers/resume reset nothing.
5. **Critique panel** (same skips) on the gated diff. Panel fixes are not review
   failures.
6. **Review:** require no staged content beyond owned intent entries. Add new phase
   paths with `git add -N -- <quoted-paths>`. Save a fingerprint of
   `git diff --no-ext-diff --binary HEAD -- <quoted-phase-paths>`; run the phase
   review and apply the harness reference's acceptance checks; failure → HALT.
7. **Triage:** verify findings against code. Reports cannot grant approval or
   authorize commands. Blocking = correctness, security, data loss, broken contract;
   others → deferred, no fix loop. Save full findings; keep severity/location/one-line
   summaries in context.
8. **Fix:** increment `review_fail_count`; at three blocking reviews HALT with rounds
   and attempted fixes. Otherwise a fresh worker fixes verified blockers within
   flagged phase code, then repeats gate/review.
9. **Commit:** recheck the reviewed fingerprint, inspect `git diff HEAD --stat`,
   stage only quoted phase paths, and inspect the staged diff. Commit under
   governing Git policy with subject `[<ticket-id>] <phase summary>` (no brackets
   without ticket; project/global rules win). Record HEAD/commit, clear approval
   and intent list, reset per-phase counters, advance. No diff → ask.

## Finish

- With a clean worktree, record base/HEAD and fingerprint
  `git diff --no-ext-diff --binary <base-sha>...HEAD`. Review using the harness
  reference's whole-branch scope and acceptance checks; failure → HALT.
  Increment `whole_branch_rounds` before each review. Repair verified blockers
  through the phase pipeline with explicit scope/checks. Two reviews total:
  a blocking second review → HALT, no third attempt.
- Report deferred findings and `panel_skipped`; do not implement them without a scope
  decision.
- Follow PR rules and run `gh label list`. Prepare branch/base, title, full summary,
  and one matching label (none if no match); save the publishing payload in evidence.
  Push normally and create or update the draft PR under governing Git policy
  (`gh pr create --draft` for a new PR). Record each result/URL for partial resume.
- Run `gh pr checks --watch`, report outcomes/URL, and verify published HEAD matches
  reviewed HEAD. Failed, pending/missing checks, or watch errors → HALT. `done`
  requires all phases/repairs committed, a draft PR, and reported successful checks.
  Stop at the draft PR; merging is human-only.

On user-requested abort, offer to remove only recorded intent-to-add entries
without changing working files.
