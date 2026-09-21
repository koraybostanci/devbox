# Next-generation devbox implementation plan

This is the handoff plan for the non-breaking devbox modernization. It expands
the phased roadmap with the decisions recovered from the original OpenCode v1
planning session. The authoritative high-level roadmap remains
[`roadmap.md`](roadmap.md).

## Product contract

- devbox is v2 only: no host mounts, an unprivileged guest `devbox` user, and
  root-managed guest services. The legacy mounted profile has been removed.
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

1. Phase 8 — explicit migration and default promotion.

Phase 3 (guest `devbox` identity and workspace) is complete and merged as
PR #10, Phase 4a (guest-local configuration and secret generation) as PR #14,
Phase 5 (root-managed PostgreSQL and Valkey) as PR #16, Phase 6 (signed release
distribution) as PR #18 and PR #19, and Phase 7 (remove v2 host runtime
dependencies) as PR #21. Phase 8's explicit migration tooling is complete as
PR #23; its default promotion remains outstanding and requires separate
explicit approval. Phase 4b (optional provider authentication) depends only on
Phase 3 and is deliberately off the critical path: no later phase requires
provider authentication, so it may be deferred or skipped.

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

### Phase 3: guest devbox identity and workspace — complete (PR #10)

- Added the unprivileged `devbox` account at `/home/devbox` with a writable
  `/home/devbox/workspace`, and a separate `devbox-v2` SSH alias authorized
  through root-managed guest SSH material rather than the bootstrap socket.
- Root-managed bundle state lives below `/var/lib/devbox-v2`; the guest
  privilege preflight rejects any sudo privilege, Docker-socket access is
  denied, and no legacy mounts exist in v2.
- The real `./devbox provision` lifecycle exposed and fixed several
  provisioning defects: a literal `''` inside a host single-quoted remote
  payload, an exact-match SSH `IdentityFile` check that broke on `Host *`, a
  validator querying Colima's prefixed source host name, and authorized-keys
  written unreadable by the target user.
- Verified on macOS/Colima with `scripts/accept-phase3.sh` (15/15 checks).

### Phase 4a: guest-local config and secrets — complete (PR #14)

- Guest-local configuration lives under `/home/devbox/.config/devbox-v2/`
  (directory 0700, files 0600): a seed-once `config` for non-secret defaults and
  guest-generated `secrets`.
- `POSTGRES_PASSWORD` is generated inside the guest and is never read from or
  written to the host; the superseded host-seeded `env` file is removed.
- Legacy `.env`, `service.env`, `rotate`, and host authentication commands are
  unchanged.
- Verified on macOS/Colima with `scripts/accept-phase4a.sh` (12/12 checks).

### Phase 5: root-managed PostgreSQL and Valkey — complete (PR #16)

- Pinned `postgres:18.3` and `valkey/valkey:8.1` run as a root-owned Compose
  project (`devbox-v2`) under `/var/lib/devbox-v2/services/`, with persistent
  data in `services/data/`.
- Both services publish to `127.0.0.1` only; the `devbox` user reaches them over
  loopback using the guest-local credentials and cannot control Docker or read
  the root-only service env file.
- `VALKEY_PASSWORD` is generated in-guest alongside `POSTGRES_PASSWORD`; the
  legacy `devbox` Compose project, volume, and ports are untouched.
- `devbox services status` reports container health.
- Verified on macOS/Colima with `scripts/accept-phase5.sh` (6/6 checks).

### Phase 6: signed release distribution — complete (PR #18, PR #19)

- `scripts/release.sh` builds a deterministic, versioned archive with a
  per-file `MANIFEST` and `SHA256SUMS`, signs `SHA256SUMS`, and verifies both
  checksums and signature before installing.
- Archives are extracted with path-traversal protection; `install` places a
  release under `~/.local/share/devbox/releases/<version>` and activates
  `~/.local/share/devbox/current` without a repository checkout.
- The `Release` workflow builds, signs with the `RELEASE_SIGNING_KEY` secret,
  verifies against the committed `release-signing-key.pub.pem`, and publishes
  the archive, `SHA256SUMS`, and `SHA256SUMS.sig`.
- Verified with `scripts/accept-phase6.sh` (11/11) and a published pre-release
  whose signature verifies locally against the committed public key.

### Phase 7: remove v2 host runtime dependencies — complete (PR #21)

- v2 now requires only Colima, the OpenSSH client, and macOS built-ins; host
  `jq`, `yq`, Homebrew, Docker, and Docker Compose are not needed.
- `check_v2_dependencies` requires only `colima` and `ssh`; `v2_state` and
  `show_v2_status` parse `colima list` with `awk`; the generated Colima
  configuration is validated by a shell `validate_v2_colima_config`.
- Services still run inside the guest; contributor tooling (`scripts/check.sh`)
  remains separate and continues to use `brew`, `jq`, `yq`, and `docker`.
- Verified with `scripts/accept-phase7.sh` (5/5 checks).

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

## Phase 8: v2 is the default

### Status

Complete (PR #25). The legacy mounted profile and its legacy-only code were
removed, so v2 is the default and only path. The interim migration command
added earlier in this phase was removed along with legacy support; there is no
longer a legacy profile to migrate from.

### Outcome

- The launcher exposes a single command surface (`init`, `install`, `start`,
  `connect`, `exec`, `status`, `services`, `provision`, `stop`, `destroy`).
- Host requirements are Colima, OpenSSH, and macOS built-ins only; `.env`
  parsing no longer needs `jq`.
- Runtime dependencies common to every mode are covered by a v2-only
  `scripts/check.sh`.
