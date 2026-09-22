# Architecture

devbox runs a single Colima VM (the `devbox` profile) and keeps everything
except the repository and your Colima installation on the guest.

## Host / guest boundary

- The host owns the repository or the installed release, the host
  configuration (`.env` in a checkout,
  `${XDG_CONFIG_HOME:-$HOME/.config}/devbox/env` for release installs), the
  Colima profile, and a marked OpenSSH host alias for `devbox`.
  It needs only Colima and the OpenSSH client.
- The guest owns toolchains, project files (`/home/devbox/workspace`), service
  data, and credentials. There are no host filesystem mounts.
- `COLIMA_HOME` must be the standard `~/.colima`; `LIMA_HOME` must be unset or
  `~/.colima/_lima`. The devbox profile disables automatic Docker context
  activation and agent forwarding, and tells Colima to leave the OpenSSH
  configuration alone (`sshConfig: false`); the marked `devbox` host alias is
  written by devbox itself.

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
(`devbox auth status`), starts GitHub and OpenCode logins inside the guest
(`devbox auth login github|opencode`), prints next-step instructions for
Claude Code and Databricks (`devbox auth login claude|databricks`), and prints
PostgreSQL connection settings (`devbox db info`). It never reads host
credentials.

## Release distribution

`VERSION` is the source of truth for release builds. Merging a bump of
`VERSION` to `main` triggers the `Release` workflow, which first runs the
`Check` workflow and then checks out the commit that last changed `VERSION`,
builds the archive from it, signs it with the `RELEASE_SIGNING_KEY` secret,
verifies against the committed `release-signing-key.pub.pem`, and creates a
draft release targeting that commit with the archive, `SHA256SUMS`, and
`SHA256SUMS.sig` plus generated release notes; suffixed versions are drafted as
prereleases. Publishing the draft creates the `v<version>` tag, so an open draft
usually has no tag yet. The draft is the approval gate: a maintainer reviews the
notes and assets and publishes it from the GitHub UI, and the workflow never
publishes a release on its own. A `workflow_dispatch` run is recovery-only: its
input must match the version already in `VERSION`, and it completes a partial
draft in place without publishing it. Operational recovery rules are in
[docs/release-checklist.md](release-checklist.md).

`scripts/release.sh build` produces
`dist/devbox-<version>/devbox-<version>.tar.gz` with a per-file `MANIFEST` and
sibling `SHA256SUMS`; signing is a separate
`scripts/release.sh sign <archive> --key <key>` invocation. `install` verifies
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
`${XDG_CONFIG_HOME:-$HOME/.config}/devbox/env` (mode 0600) instead of inside the
versioned tree, and the Colima ownership marker records the install root (the
data root for releases, the checkout directory for checkouts), so a release
upgrade does not invalidate it. `scripts/release.sh prune [--keep N]` bounds
the installed `releases/` tree: it keeps the active release plus the `N` most
recently modified non-active releases (default 0) and removes staging
directories older than 24 hours; the active release is never removed. Prune
skips version-named symlinks and refuses a releases directory that is itself a
symlink.

## Lifecycle

Mutating lifecycle commands serialize on a PID-bearing `mkdir` lock: `start`,
`provision`, `stop`, and `destroy` (`run_devbox`), plus `install --adopt`,
which writes the ownership marker. `init`, `install`, and the read-only
commands do not take the lock. Stale locks are removed only when their recorded
process no longer exists.
