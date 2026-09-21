# Architecture

devbox runs a single Colima VM (the `devbox-v2` profile) and keeps everything
except the repository and your Colima installation on the guest.

## Host / guest boundary

- The host owns the repository, `.env`, the Colima profile, and a marked
  OpenSSH host alias for `devbox-v2`. It needs only Colima and the OpenSSH
  client.
- The guest owns toolchains, project files (`/home/devbox/workspace`), service
  data, and credentials. There are no host filesystem mounts.
- `COLIMA_HOME` must be the standard `~/.colima`; `LIMA_HOME` must be unset or
  `~/.colima/_lima`. The v2 profile disables Docker auto-activation, automatic
  SSH config edits, and agent forwarding, and sets `sshConfig: false`.

## Identity

Provisioning creates an unprivileged `devbox` account:

- Home `/home/devbox`, writable workspace `/home/devbox/workspace`.
- No sudo, no Docker group membership, no Docker-socket access, no access to
  root-managed bundle state.
- Direct IDE/CLI access uses the separate `devbox-v2` SSH alias, authorized
  through root-managed guest SSH material rather than the bootstrap account.

A root-owned privilege preflight rejects unsafe identity or privilege state
before direct SSH access is authorized.

## Provisioning

The host computes a SHA-256 digest over the sorted `provision/` tree and streams
it over Colima SSH when stale. The bundle is installed root-owned below
`/var/lib/devbox-v2`, and the system, tools, and verify scripts run against a
root-owned, read-only provisioning input.

Guest-local configuration lives under `/home/devbox/.config/devbox-v2/`
(directory 0700, files 0600):

- `config` — non-secret defaults (Git identity, PostgreSQL user/database/port),
  seeded once from the host and then maintained in the guest.
- `secrets` — service secrets generated inside the guest only. The PostgreSQL
  password never touches the host.

## Services

PostgreSQL (`postgres:18.3`) and Valkey (`valkey/valkey:8.1`) run as a
root-owned Compose project (`devbox-v2`) defined by
`provision/config/services/compose.yaml`, with persistent data below
`/var/lib/devbox-v2/services/data/`. Both publish to `127.0.0.1` only; the
`devbox` user reaches them over loopback using the guest-local credentials.

## Guest companion

Provisioning installs a small guest-local `devbox` companion at
`/usr/local/bin/devbox`. It reports optional provider authentication state
(`devbox auth status`), starts provider logins inside the guest
(`devbox auth login <provider>`), and prints PostgreSQL connection settings
(`devbox db info`). It never reads host credentials.

## Release distribution

`scripts/release.sh` builds a deterministic, versioned archive with a per-file
`MANIFEST` and `SHA256SUMS`, signs `SHA256SUMS`, and verifies checksums and
signature before extracting with path-traversal protection. Installs go below
`~/.local/share/devbox/releases/<version>` and are activated through
`~/.local/share/devbox/current`. The `Release` workflow builds, signs with the
`RELEASE_SIGNING_KEY` secret, verifies against the committed
`release-signing-key.pub.pem`, and publishes the artifacts.

## Lifecycle

A PID-bearing `mkdir` lock serializes mutating commands. Stale locks are removed
only when their recorded process no longer exists.
