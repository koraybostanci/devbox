# Panel reference

A panel is a few read-only expert subagents advising on one question. It never
edits, commits, or replaces the native reviewer. The controller runs every round.

**Skip** (`Panel: none`) a phase or plan that is single-concern, touches ≤2 files,
and has no security, data, concurrency, migration, or public-contract risk.

## Roster

One member per distinct aspect: planning 2–4, implementation 2–3. Match only agents
and skills the session lists; else use the read-only fallback in
`harness-reference.md`, briefed "act as a <aspect> expert". Planning shows the roster
and asks once whether to add or remove experts. Implementation never asks: it uses
`Panel`, or applies the skip rule and auto-detects when the field is missing.

## Subjects

- **Planning:** is the draft plan viable and complete?
- **Design:** the controller's short proposal (approach, files, risks, tests). Changes
  may only narrow the phase; anything wider is a plan change (SKILL.md).
- **Critique:** does the gated phase diff have a blocking defect?

## Members and rounds

Brief each fresh member with the question, excerpt, shared context, and paths (not
file bodies). Members may only read files and run `git diff/status/log/show`. Output
≤200 words (≤100 later): `verdict` (`approve`/`approve-with-changes`/`block`),
`blocking` items (claim, `file:line`, change) for correctness, security, data loss,
or a broken contract only, and ≤3 `notes`.

1. Round 1 runs members in parallel, independently. The controller verifies each
   blocker; refuted ones are dismissed. None left → agreed.
2. The controller resolves verified blockers: revise the plan or proposal, or
   (critique) a fresh scoped worker fixes them and the gate reruns (a failure counts
   toward `gate_retries`).
3. The next round sends only open blockers and the change to the members who raised
   them.
4. Caps: planning 3 rounds, design and critique 2. A blocker open at the cap → ask
   the user (planning) or HALT `panel-deadlock`.

Panels run once per phase (again after a plan-change restart), not for review fixes
or repairs. Save member output to
evidence; keep only verdicts and blockers in context. Prefer a cheaper member model
except for security, data, and concurrency.

**Budget:** planning 12 member calls; implementation 8 per phase and 40 per run.
If a round does not fit: no open blocker → skip, record in `panel_skipped`; open
blocker → deadlock.

**Safety:** if HEAD, `git status --short`, or the diff changes during a round, a
member wrote → HALT.
