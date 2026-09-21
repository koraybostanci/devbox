# Architecture

devbox runs a single Colima VM (the `devbox` profile) and keeps everything
except the repository and your Colima installation on the guest.

## Host / guest boundary

- The host owns the repository or the installed release, the host
  configuration (`.env` in a checkout, `~/.config/devbox/env` for release
  installs), the Colima profile, and a marked OpenSSH host alias for `devbox`.
  It needs only Colima and the OpenSSH client.
- The guest owns toolchains, project files (`/home/devbox/workspace`), service
  data, and credentials. There are no host filesystem mounts.
- `COLIMA_HOME` must be the standard `~/.colima`; `LIMA_HOME` must be unset or
  `~/.colima/_lima`. The devbox profile disables Docker auto-activation,
  automatic SSH config edits, and agent forwarding, and sets `sshConfig: false`.

## Identity

Provisioning creates an unprivileged `devbox` account:

- Home `/home/devbox`, writable workspace `/home/devbox/workspace`. The home is
  bind-mounted onto the Colima data disk (`/mnt/lima-*`) so the toolchain and
  caches do not fill the small fixed-size guest root disk. On an existing VM the
  first converge moves the current home contents onto the data disk before
  switching the mount, so nothing is hidden and the root-disk space is freed.
- No sudo, no Docker group membership, no Docker-socket access, no access to
  root-managed bundle state.
- Direct IDE/CLI access uses the separate `devbox` SSH alias, authorized
  through root-managed guest SSH material rather than the bootstrap account.

A root-owned privilege preflight rejects unsafe identity or privilege state
before direct SSH access is authorized.

## Provisioning

The host computes a SHA-256 digest over the sorted `provision/` tree and streams
it over Colima SSH when stale. The bundle is installed root-owned below
`/var/lib/devbox`, and the system, tools, and verify scripts run against a
root-owned, read-only provisioning input.

Guest-local configuration lives under `/home/devbox/.config/devbox/`
(directory 0700, files 0600):

- `config` — non-secret defaults (Git identity, PostgreSQL user/database/port),
  seeded once from the host and then maintained in the guest.
- `secrets` — service secrets generated inside the guest only. The PostgreSQL
  password never touches the host.

## Services

PostgreSQL (`postgres:18.3`) and Valkey (`valkey/valkey:8.1`) run as a
root-owned Compose project (`devbox`) defined by
`provision/config/services/compose.yaml`, with persistent data below
`/var/lib/devbox/services/data/`. Both publish to `127.0.0.1` only; the
`devbox` user reaches them over loopback using the guest-local credentials.

## Guest companion

Provisioning installs a small guest-local `devbox` companion at
`/usr/local/bin/devbox`. It reports optional provider authentication state
(`devbox auth status`), starts provider logins inside the guest
(`devbox auth login <provider>`), and prints PostgreSQL connection settings
(`devbox db info`). It never reads host credentials.

## Release distribution

`VERSION` is the source of truth for release builds; the `Release` workflow
refuses a tag or dispatch version that does not match it. `scripts/release.sh`
builds `dist/devbox-<version>/devbox-<version>.tar.gz` with a per-file
`MANIFEST` and sibling `SHA256SUMS`, signs `SHA256SUMS`, and verifies
fail-closed before extracting into the install root: checksum, signature
(against the committed `release-signing-key.pub.pem`, overridable with
`DEVBOX_RELEASE_PUBKEY`), exactly one `devbox-<version>` top-level directory,
regular-file/directory entry types, and every MANIFEST path and hash. The
staged tree is re-validated from the exact bytes that are installed. `VERSION`
is optional inside the tree (legacy archives predate it) but must match the
release directory name when present.

Installs go below the canonical data root
`${XDG_DATA_HOME:-$HOME/.local/share}/devbox`: releases at
`releases/<version>`, activation through `current`. The data root is
canonicalized physically (without creating anything) before it is compared with
launcher-reported paths, so a symlinked `$HOME` such as a macOS sandbox below
`/var` still detects release trees and ownership markers. Upgrades install a new
version alongside the old one and leave the other version directories in
place; an existing version directory is replaced only when its tree no longer
matches its `MANIFEST`, or when `install --force` is passed. A legacy in-tree
`.env` is copied to the stable host configuration path before its release
directory is replaced. Release installs keep host configuration at
`~/.config/devbox/env` (mode 0600) instead of inside the
versioned tree, and the Colima ownership marker records the install root (the
data root for releases, the checkout directory for checkouts), so a release
upgrade does not invalidate it. The `Release` workflow builds, signs with the
`RELEASE_SIGNING_KEY` secret, verifies against the committed
`release-signing-key.pub.pem`, and publishes the archive, `SHA256SUMS`, and
`SHA256SUMS.sig`.

## Lifecycle

A PID-bearing `mkdir` lock serializes mutating commands. Stale locks are removed
only when their recorded process no longer exists.
