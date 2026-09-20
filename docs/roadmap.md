# Phased Roadmap

This document is the source of truth for the phased implementation of the
next-generation devbox experience. Each phase is separately deliverable and
must preserve the legacy `devbox` profile, its mounts, the `devbox` SSH alias,
existing data, and all existing commands until explicit migration and default
promotion.

## Completed work

| Phase | Status | Delivery |
|---|---|---|
| OpenCode v2 | Complete | PR #5 |
| Phase 1: isolation POC | Complete | PR #6 |

Phase 1 established the isolated-profile proof of concept. It is not a change
to the legacy profile or its default behavior.

## Mandatory process for every phase

Every phase, including a follow-up after a merged phase, uses this process:

1. Start with a new, fresh agent.
2. Fetch and prune `origin`, then fast-forward local `main` from `origin/main`.
3. Create a dedicated branch for that phase from the updated `main`.
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

## Remaining phases

### Phase 2: Experimental no-mount v2 profile and bundle

**Purpose.** Deliver an opt-in v2 profile and distributable bundle that starts
without host project or data mounts, building on the isolation POC.

**Status.** Implementation is in progress and remains unmerged. The no-mount
profile is independent of Phase 1's unresolved Colima `user-v2` network
limitation; it makes no strict-isolation claim.

**Compatibility guarantee.** The existing `devbox` profile, its mounts,
`devbox` SSH alias, persisted data, and commands remain unchanged; the v2
profile is separate and explicitly selected.

**Prerequisites.** OpenCode v2 and the completed Phase 1 isolation POC.

**Exit criteria.** A user can install and run the documented experimental v2
bundle with no host mounts, while the legacy profile continues to start and
operate unchanged.

### Phase 3: Guest devbox identity and workspace

**Purpose.** Establish a stable guest-side devbox identity and workspace for
the v2 profile, independent of the legacy mount-oriented home layout.

**Compatibility guarantee.** No legacy guest identity, workspace, mount,
`devbox` SSH alias, data location, or command behavior is changed.

**Prerequisites.** Phase 2's experimental no-mount v2 profile and bundle.

**Exit criteria.** The v2 guest has a documented, repeatable identity and
workspace that work without host mounts; the legacy profile remains usable
without migration.

### Phase 4: Guest-local configuration and authentication

**Purpose.** Make v2 configuration and service authentication guest-local,
with lifecycle and recovery behavior defined for the isolated workspace.

**Compatibility guarantee.** Existing legacy configuration, guest-local
credentials, mounts, SSH alias, data, and authentication commands remain
valid and untouched.

**Prerequisites.** Phase 3's stable guest identity and workspace.

**Exit criteria.** v2 configuration and authentication can be initialized,
used, and recovered entirely within the v2 guest, without copying host secrets
or changing legacy authentication flows.

### Phase 5: Root-managed PostgreSQL and Valkey

**Purpose.** Provide PostgreSQL and Valkey as root-managed services for v2
rather than relying on the legacy user-managed container workflow.

**Compatibility guarantee.** The existing PostgreSQL container service,
legacy Docker volumes, ports, data, mounts, SSH alias, and commands keep their
current behavior; no service is silently replaced or started for legacy users.

**Prerequisites.** Phase 4's guest-local configuration and authentication,
including a defined v2 configuration location for service settings.

**Exit criteria.** The v2 profile can manage PostgreSQL and Valkey as
documented root-managed services with persistent, isolated v2 data, while the
legacy container commands and their data remain functional.

### Phase 6: Signed release distribution

**Purpose.** Publish the v2 bundle through a signed, verifiable release
distribution path.

**Compatibility guarantee.** Existing clone-and-run installation and all
legacy profile behavior remain supported; release distribution adds an option
and does not change mounts, SSH alias, data, or commands.

**Prerequisites.** Phase 2's bundle and the v2 guest capabilities completed
through Phase 5.

**Exit criteria.** A v2 release artifact is signed, its verification procedure
is documented and tested, and users can install the experimental v2 path
without affecting a legacy installation.

### Phase 7: Remove v2 host dependencies

**Purpose.** Eliminate host-side dependencies from v2 so the supported v2
workflow is self-contained apart from its explicit virtualization/runtime
requirements.

**Compatibility guarantee.** This applies only to v2. The legacy `devbox`
profile retains its existing host integration, mounts, `devbox` SSH alias,
data, and commands.

**Prerequisites.** Phase 6's signed release distribution and a v2 workflow
that covers identity, workspace, configuration, authentication, and services.

**Exit criteria.** The documented v2 workflow runs with its declared minimal
host requirements and no removed host dependency; regression checks confirm
the legacy workflow is unchanged.

### Phase 8: Explicit migration and default promotion

**Purpose.** Offer a deliberate, reversible migration path and promote v2 to
the default only when the migration criteria are satisfied.

**Compatibility guarantee.** Migration is explicit and opt-in until default
promotion is separately approved. Legacy profiles, mounts, SSH alias, data,
and commands remain available and recoverable throughout migration.

**Prerequisites.** Phase 7 completion, signed distribution, documented data
and credential handling, and successful compatibility validation for legacy
users.

**Exit criteria.** Migration, rollback, and support procedures are documented
and tested; default promotion has explicit approval; and users can retain or
recover the legacy profile without data loss or command breakage.
