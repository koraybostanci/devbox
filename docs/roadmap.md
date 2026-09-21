# Phased Roadmap

This document is the source of truth for the phased implementation of the
next-generation devbox experience. Each phase is separately deliverable and
must preserve the legacy `devbox` profile, its mounts, the `devbox` SSH alias,
existing data, and all existing commands until explicit migration and default
promotion.

## Phase sequence

This is the planned order. Every phase after Phase 3 depends on the accepted
Phase 3 guest identity and workspace. Phase 4b is optional and may be deferred
or skipped without blocking any later phase.

| Phase | Status | Depends on | Delivery |
|---|---|---|---|
| OpenCode v2 | Complete | — | PR #5 |
| Phase 1: isolation POC | Complete | — | PR #6 |
| Phase 2: no-mount v2 profile | Complete | — | PR #8 |
| Phase 3: guest identity and workspace | Complete | Phase 2 | PR #10 |
| Phase 4a: guest config and secrets | Complete | Phase 3 | PR #14 |
| Phase 4b: optional provider auth | Optional | Phase 3 | — |
| Phase 5: PostgreSQL and Valkey | Complete | Phase 4a | PR #16 |
| Phase 6: signed release distribution | Complete | Phase 5 | PR #18, #19 |
| Phase 7: v2 host dependencies removed | Complete | Phase 6 | PR #21 |
| Phase 8: migration and default promotion | In progress | Phase 7 | PR #23 |

Phase 1 established the isolated-profile proof of concept. It is not a change
to the legacy profile or its default behavior.

## Mandatory process for every phase

Every phase, including a follow-up after a merged phase, uses this process:

1. Start with a new, fresh agent.
2. Fetch and prune `origin`, then fast-forward local `main` from `origin/main`.
3. For a new phase, create a dedicated branch from the updated `main`. To
   resume an in-progress phase, continue its existing branch instead; see
   [`implementation-plan.md`](implementation-plan.md).
4. Use the `implement-review-loop` skill for the implementation and independent
   review.
5. Preserve the phase's approved scope; do not change legacy behavior outside
   that scope.
6. Run the required review and relevant tests before publication.
7. Commit, push, and draft PR creation are preapproved only for the current
   user-authorized session. In future sessions, follow the active repository
   approval policy. The agent must wait for required CI and merge only after
   review and test success and any required approval.
8. After merge, begin the next phase with a new, fresh agent and repeat this
   process.

## Phase details

### Phase 3: Guest devbox identity and workspace

**Purpose.** Establish a stable guest-side devbox identity and workspace for
the v2 profile, independent of the legacy mount-oriented home layout.

**Compatibility guarantee.** No legacy guest identity, workspace, mount,
`devbox` SSH alias, data location, or command behavior is changed.

**Prerequisites.** Phase 2's experimental no-mount v2 profile and bundle.

**Status.** Complete (PR #10). Verified on macOS/Colima with
`scripts/accept-phase3.sh` (15/15 checks).

**Exit criteria.** The v2 guest has a documented, repeatable identity and
workspace that work without host mounts; the legacy profile remains usable
without migration.

### Phase 4a: Guest-local configuration and secret generation

**Purpose.** Define the guest-local v2 configuration location and generate
guest-local secrets so later phases have a stable place for settings and
credentials.

**Status.** Complete (PR #14). Verified on macOS/Colima with
`scripts/accept-phase4a.sh` (12/12 checks).

**Compatibility guarantee.** Existing legacy configuration, guest-local
credentials, mounts, SSH alias, data, and authentication commands remain valid
and untouched.

**Prerequisites.** Phase 3's stable guest identity and workspace.

**Exit criteria.** v2 configuration and generated secrets live only in the v2
guest, survive stop/start, and are removed by rebuild/destroy, without copying
host secrets or changing legacy flows.

### Phase 4b: Optional provider authentication

**Purpose.** Provide optional guest-local authentication for external providers
and a guest-local companion for authentication status and service client
helpers.

**Compatibility guarantee.** Existing legacy configuration, mounts, SSH alias,
data, and authentication commands remain valid and untouched.

**Prerequisites.** Phase 3's stable guest identity and workspace.

**Status.** Optional and deferrable. No later phase requires provider
authentication, so this phase may be skipped without blocking Phase 5 or any
other phase.

**Exit criteria.** A user can authenticate optional providers entirely inside
the v2 guest; authentication is never required for the other phases.

### Phase 5: Root-managed PostgreSQL and Valkey

**Purpose.** Provide PostgreSQL and Valkey as root-managed services for v2
rather than relying on the legacy user-managed container workflow.

**Status.** Complete (PR #16). Verified on macOS/Colima with
`scripts/accept-phase5.sh` (6/6 checks).

**Compatibility guarantee.** The existing PostgreSQL container service,
legacy Docker volumes, ports, data, mounts, SSH alias, and commands keep their
current behavior; no service is silently replaced or started for legacy users.

**Prerequisites.** Phase 4a's guest-local configuration location and
guest-side secret generation. Phase 4b is not required.

**Exit criteria.** The v2 profile can manage PostgreSQL and Valkey as
documented root-managed services with persistent, isolated v2 data, while the
legacy container commands and their data remain functional.

### Phase 6: Signed release distribution

**Purpose.** Publish the v2 bundle through a signed, verifiable release
distribution path.

**Status.** Complete (PR #18, PR #19). Verified with `scripts/accept-phase6.sh`
(11/11) and a published pre-release whose signature verifies against the
committed public key.

**Compatibility guarantee.** Existing clone-and-run installation and all
legacy profile behavior remain supported; release distribution adds an option
and does not change mounts, SSH alias, data, or commands.

**Prerequisites.** Phase 2's bundle and the v2 guest capabilities completed
through Phase 5. Phase 4b is not required.

**Exit criteria.** A v2 release artifact is signed, its verification procedure
is documented and tested, and users can install the experimental v2 path
without affecting a legacy installation.

### Phase 7: Remove v2 host dependencies

**Purpose.** Eliminate host-side dependencies from v2 so the supported v2
workflow is self-contained apart from its explicit virtualization/runtime
requirements.

**Status.** Complete (PR #21). Verified with `scripts/accept-phase7.sh`
(5/5 checks).

**Compatibility guarantee.** This applies only to v2. The legacy `devbox`
profile retains its existing host integration, mounts, `devbox` SSH alias,
data, and commands.

**Prerequisites.** Phase 6's signed release distribution and a v2 workflow
that covers identity, workspace, configuration, and services. Optional provider
authentication (Phase 4b) is not required.

**Exit criteria.** The documented v2 workflow runs with its declared minimal
host requirements and no removed host dependency; regression checks confirm
the legacy workflow is unchanged.

### Phase 8: Explicit migration and default promotion

**Purpose.** Offer a deliberate, reversible migration path and promote v2 to
the default only when the migration criteria are satisfied.

**Status.** In progress. The explicit, opt-in migration command is complete
(PR #23). Default promotion is outstanding and requires separate explicit
approval.

**Compatibility guarantee.** Migration is explicit and opt-in until default
promotion is separately approved. Legacy profiles, mounts, SSH alias, data,
and commands remain available and recoverable throughout migration.

**Prerequisites.** Phase 7 completion, signed distribution, documented data
and credential handling, and successful compatibility validation for legacy
users.

**Exit criteria.** Migration, rollback, and support procedures are documented
and tested; default promotion has explicit approval; and users can retain or
recover the legacy profile without data loss or command breakage.
