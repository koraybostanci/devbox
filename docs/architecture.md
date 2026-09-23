# Architecture

devbox runs a single Colima VM (the `devbox` profile) and keeps everything
except the repository and your Colima installation on the guest.

## Host / guest boundary

- The host owns the repository, the host configuration (`.env`, mode 0600),
  the Colima profile, and a marked OpenSSH host alias for `devbox`. It needs
  only Colima and the OpenSSH client.
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
- No sudo, no Docker group membership, no Docker-socket access.
- Direct IDE/CLI access uses the separate `devbox` SSH alias: the host's Colima
  public key is authorized for the unprivileged account in
  `/home/devbox/.ssh/authorized_keys`. Colima's own administrative access is
  untouched.

## Provisioning

The host computes a SHA-256 digest over the sorted `provision/` tree and streams
it over Colima SSH when stale. The tree is installed root-owned, read-only, and
readable by the guest user at `/var/lib/devbox/provision`; the digest is
re-computed inside the guest before anything executes. Provisioning then runs in
two guest phases:

- root: `system.sh` (packages, the guest account, the companion, the Databricks
  CLI), then `state.sh` (seed the guest configuration, generate secrets, stage
  the service definition).
- unprivileged: `tools.sh` and `verify.sh`; `verify.sh` records the digest
  marker at `~/.local/state/devbox/provision.sha256` once every check passes.

A matching marker skips the bundle work after re-verifying the installed tree
against its digest. `devbox provision` forces a full run. Direct SSH is only
authorized after `verify.sh` passes; a failed run removes the managed alias.

Guest-local configuration lives under `/home/devbox/.config/devbox/`
(directory 0700, files 0600):

- `config` — non-secret defaults (Git identity, PostgreSQL user/database/port),
  seeded once from the host and then maintained in the guest.
- `secrets` — service secrets generated inside the guest only. The PostgreSQL
  password never touches the host.

## Services

PostgreSQL (`postgres:18.3`) and Valkey (`valkey/valkey:8.1`) are defined by
`provision/config/services/compose.yaml`. Provisioning stages the definition and
credentials at `/var/lib/devbox/services/` (root-owned, mode 0600) with
persistent data below `services/data/`, but does not start the containers.
`devbox services start|stop|status` drives `docker compose` as root in the
guest. Both services publish to `127.0.0.1` only; the `devbox` user reaches
them over loopback using the guest-local credentials.

## Guest companion

Provisioning installs a small guest-local `devbox` companion at
`/usr/local/bin/devbox`. It reports optional provider authentication state
(`devbox auth status`), starts GitHub and OpenCode logins inside the guest
(`devbox auth login github|opencode`), prints next-step instructions for
Claude Code and Databricks (`devbox auth login claude|databricks`), and prints
PostgreSQL connection settings (`devbox db info`). It never reads host
credentials.

## Lifecycle

Mutating lifecycle commands serialize on a PID-bearing `mkdir` lock under
`~/.local/state/devbox/locks`: `start`, `provision`, `stop`, and `destroy`.
`init`, `install`, and the read-only commands do not take the lock. Stale locks
are removed only when their recorded process no longer exists. `devbox stop`
stops the VM; `devbox destroy` requires the profile name to be typed and then
deletes the VM together with its runtime data and the managed SSH alias.
