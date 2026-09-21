# Next-generation devbox implementation plan

This is the handoff plan for the non-breaking devbox modernization. It expands
the phased roadmap with the decisions recovered from the original OpenCode v1
planning session. The authoritative high-level roadmap remains
[`roadmap.md`](roadmap.md).

## Product contract

- The legacy `devbox` profile, its host mounts, `devbox` SSH alias, data,
  commands, `.env` flow, and PostgreSQL container workflow remain available
  until an explicit migration and separately approved default promotion.
- New behavior is opt-in under `devbox v2` / `devbox-v2`, with namespaced
  state, services, volumes, and SSH configuration.
- v2 repositories live on the guest disk in `/home/devbox/workspace`; they
  persist across stop/start and are deliberately removed only by v2 rebuild or
  destroy.
- No-mount v2 is not a strict network-isolation claim. Phase 1 found that
  stock Colima 0.10.3 retains a host-reachable Lima `user-v2` network; do not
  claim full host-network isolation unless that POC is resolved.
- Authentication is optional. Tools are installed by default, but provider
  credentials must be guest-local and never persisted in host configuration,
  logs, command arguments, or release artifacts.
- Phases are ordered by dependency. Optional phases are off the critical path
  and may be deferred or skipped without weakening any later phase's exit
  criteria.

## Delivery protocol

For each phase:

1. Start with a fresh agent, fetch/prune `origin`, fast-forward `main`, and
   create a dedicated branch.
2. Scope the phase so that it cannot change legacy behavior.
3. Use the `implement-review-loop` skill with an implementation worker and
   independent reviewer.
4. Run static checks and the relevant real lifecycle checks before publication.
5. Commit, publish, merge, and only then begin the next phase from updated
   `main`, subject to the active repository approval policy.

When a phase is already committed on a dedicated branch and published as a
draft PR, resume it instead of starting over: do not branch from `main` for
that phase. Fetch `origin`, check out the phase branch, fast-forward it from
the current `origin/main`, and continue there. Keep the PR in draft, and do not
promote the phase until the real acceptance checks pass. Each phase's "Current
status" section below records the exact branch, base, and next step.

Optional phases may be deferred or skipped. Skipping an optional phase must not
weaken any later phase's exit criteria.

## Phase order

The phases form this sequence; each later phase builds on the accepted
identity, workspace, and configuration established earlier.

1. Phase 3 — guest `devbox` identity and workspace (in progress, draft PR #10).
2. Phase 4a — guest-local configuration location and guest-side secret
   generation.
3. Phase 5 — root-managed PostgreSQL and Valkey.
4. Phase 6 — signed release distribution.
5. Phase 7 — remove v2 host runtime dependencies.
6. Phase 8 — explicit migration and default promotion.

Phase 4b (optional provider authentication) depends only on Phase 3 and is
deliberately off the critical path: no later phase requires provider
authentication, so it may be deferred or skipped. Phase 3 is the gate for every
later phase and must be accepted first.

## Completed phases

### OpenCode v2 migration — complete (PR #5)

- OpenCode v1 installation, configuration, filesystem MCP, and remote skill
  installation were removed.
- A pinned standalone OpenCode v2 binary, v2 agents, skills, and guest-local
  authentication flow were introduced.

### Phase 1: isolation feasibility POC — complete (PR #6)

- Added a separate, no-mount bridged-network POC profile.
- It fails closed when the external quarantine-network prerequisites or
  topology checks are not met.
- Current limitation: stock Colima 0.10.3 keeps the Lima `user-v2` network, so
  the POC cannot certify strict host-network isolation.

### Phase 2: experimental no-mount v2 profile and bundle — complete (PR #8)

- Added opt-in `devbox v2` lifecycle commands and a separate `devbox-v2`
  Colima profile without host filesystem mounts.
- Provisioning is streamed as a content-addressed guest-local bundle rather
  than read from `/provision`.
- Phase 2 intentionally retained the generated Colima account as the
  bootstrap transport; guest identity and direct user access belong to Phase 3.

## Phase 3: guest devbox identity and workspace — in progress

### Goal

For v2 only, establish an unprivileged `devbox` account with:

- Home: `/home/devbox`
- Workspace: `/home/devbox/workspace`
- No sudo, Docker group membership, Docker-socket access, root-bundle access,
  or bootstrap-admin identity access
- Direct IDE/CLI access through a separate `devbox-v2` SSH alias

The generated Colima account remains a restricted bootstrap/admin transport
for bundle transfer and root provisioning. It is not the daily development
identity.

### Intended implementation decisions

- Root-managed bundle state lives below `/var/lib/devbox-v2`; user-readable
  staged provisioning input is root-owned and not user-writable.
- The host key is authorized through root-managed guest SSH material. Direct
  v2 access must not reuse Colima's bootstrap SSH control socket.
- The v2 SSH configuration is separate from the legacy alias, does not forward
  the host agent, uses the dedicated identity, and must validate its effective
  OpenSSH configuration against inherited host settings.
- Root-to-`devbox` dispatch must explicitly set `HOME` and the initial working
  directory to `/home/devbox`, preserve required v2 environment variables,
  and avoid granting sudo.
- v2 and legacy lifecycle/SSH configuration changes use a shared lifecycle
  lock.

### Current status (branch published as draft PR #10)

- Branch: `phase-3-guest-identity-workspace`
- Base: `7b99d43` (merged Phase 2)
- The Phase 3 changes in the launcher, provisioning scripts, checks, and
  documentation are committed on the branch and published as **draft PR #10**;
  they are no longer an uncommitted worktree.
- Static checks and several independent reviews have run, but **Phase 3 is not
  accepted or publishable**, so the draft PR must not be merged.
- The guest-side privilege preflight in `lib/v2.sh` originally used a nested
  double-quoted `bash -c`/AWK implementation. That parser was found to be valid
  when executed directly in a Linux/mawk sandbox, so the earlier
  `./devbox v2 provision` runtime syntax error could not be reproduced from the
  committed source; the failure most likely originated in the SSH transport's
  quoting rather than in the parser body.
- The preflight has since been rewritten on the PR #10 branch as a
  single-quoted guest script with no nested quoting, and it now rejects any
  sudo privilege, not only passwordless sudo, to match the no-sudo contract.
- The real `./devbox v2 provision` lifecycle has still not been re-run against
  the rewritten preflight.
- Phase 3 is the gate for every later phase; do not begin Phase 4a or later
  work until Phase 3 is accepted.

### Required next step

Re-run the real `./devbox v2 provision` lifecycle against the rewritten
preflight and confirm that the exact no-sudo guest output:

```text
User devbox is not allowed to run sudo on <host>.
```

is the only accepted state, while unsafe or unparseable sudo state fails. Then
verify all of the following before accepting Phase 3:

```sh
./devbox v2 provision
./devbox v2 exec id -un              # devbox
./devbox v2 exec pwd                 # /home/devbox
ssh devbox-v2 id -un                 # devbox
ssh devbox-v2 pwd                    # /home/devbox
./devbox v2 exec test -w /home/devbox/workspace
```

Also verify that `devbox` has no sudo privileges or Docker socket write
access, root bundle state is unreadable, no legacy mount exists in v2, and the
legacy profile is unchanged.

## Phase 4a: guest-local configuration and secret generation

### Prerequisite

Phase 3's stable guest identity and workspace.

### Scope

- Define the guest-local v2 configuration location for settings, secrets, and
  service configuration.
- Move v2 Git identity and non-secret defaults into guest-local v2
  configuration.
- Generate v2 service secrets inside the guest only, and never on the host, in
  logs, command arguments, or release artifacts.

### Exit criteria

- v2 configuration and generated secrets live only in the v2 guest, survive
  stop/start, and are removed by rebuild/destroy.
- Legacy `.env`, `rotate`, and host authentication commands remain legacy-only
  and unchanged.

## Phase 4b: optional provider authentication

Optional and off the critical path. This phase may be deferred or skipped
without blocking Phase 5 or any later phase.

### Prerequisite

Phase 3's stable guest identity and workspace.

### Scope

- Add a guest-local `devbox` companion for authentication status and service
  client helpers.
- Keep GitHub, Claude Code, OpenCode, and Databricks authentication optional
  and performed inside the guest.

### Exit criteria

- v2 needs no host-stored provider credentials when a provider is configured.
- Optional provider authentication is never required by another phase.
- Legacy `.env`, `rotate`, and host authentication commands remain legacy-only
  and unchanged.

## Phase 5: root-managed PostgreSQL and Valkey

### Prerequisite

Phase 4a's guest-local configuration location and guest-side secret
generation. Phase 4b is not required.

### Scope

- Provide PostgreSQL and Valkey as root-managed, guest-only services for v2.
- Use pinned guest-side container images/Compose definitions or an equivalently
  root-managed service layer; the `devbox` user must not control Docker.
- Bind services to guest loopback, namespace persistent data by v2
  installation/profile, and generate credentials in the guest.
- Expose only constrained management commands; do not replace or mutate the
  legacy PostgreSQL Compose project, volumes, or ports.

### Exit criteria

- Both services are healthy, isolated from host/LAN access, and inaccessible
  through the v2 user's Docker privileges.
- Their v2 data lifecycle is documented, including explicit export/import.

## Phase 6: signed release distribution

### Prerequisite

Phase 2's provisioning bundle and the v2 guest capabilities completed through
Phase 5. Phase 4b is not required.

### Scope

- Build deterministic, versioned GitHub Release archives with manifests,
  checksums, safe extraction, installation, activation, and verification.
- Install releases under `~/.local/share/devbox/releases/<version>` without a
  repository checkout.
- Reuse the verified provisioning-bundle protocol with release artifacts.

### Hard prerequisite

A release-signing public key must be committed and the matching private key
must be configured as a GitHub Actions secret. Do not generate or retain a
private release-signing key without an explicit user decision.

## Phase 7: remove v2 host runtime dependencies

### Prerequisite

Phase 6's signed release distribution and a v2 workflow that covers identity,
workspace, configuration, and services. Optional provider authentication
(Phase 4b) is not required.

### Scope

- Remove v2 requirements for host Docker, Compose, jq, yq, Homebrew, and
  Docker configuration.
- Retain only the declared virtualization/runtime, OpenSSH, and macOS built-in
  requirements.
- Split contributor tooling from the supported release-install workflow.

### Exit criteria

A clean account can install and operate v2 without host developer tooling;
legacy prerequisites remain supported for legacy users.

## Phase 8: explicit migration and default promotion

### Prerequisite

Phase 7 completion, signed distribution, documented data and credential
handling, and successful compatibility validation for legacy users.

### Scope

- Provide an explicit mounted-profile migration command and documented,
  confirmed export/import procedures for projects, data, and PostgreSQL.
- Never mount legacy host directories into v2 or silently delete legacy state.
- Make v2 the default only for new installations after compatibility,
  migration, rollback, and destructive-lifecycle acceptance tests pass.

### Approval gate

Default promotion requires separate explicit approval. Legacy mode remains
available for a documented support window and must remain recoverable.
