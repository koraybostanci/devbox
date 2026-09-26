# Architecture

devbox runs a single Colima VM (the `devbox` profile) and keeps everything
except the repository and your Colima installation on the guest.

## Host / guest boundary

- The host owns the repository, the host configuration (`.env`, mode 0600),
  the Colima profile, and a managed OpenSSH host alias for `devbox`. It needs
  only Colima and the OpenSSH client.
- The guest owns toolchains, project files (`/home/devbox/workspace`), service
  data, and credentials. Colima is configured with `mounts: null`, so no host
  directories are mounted into the guest.
- The VM's virtual disk, including the guest home and credentials, is stored on
  the host under Colima storage (normally below `~/.colima`). Host disk
  permissions, encryption, and backups therefore remain part of the security
  boundary.
- The guest retains ordinary network access and can reach the host gateway and
  host services listening there unless the host or network is separately
  restricted. No host filesystem mount does not mean host-network isolation.
- `COLIMA_HOME` must be the standard `~/.colima`; `LIMA_HOME` must be unset or
  `~/.colima/_lima`. The devbox profile disables automatic Docker context
  activation and agent forwarding, and tells Colima to leave the OpenSSH
  configuration alone (`sshConfig: false`). Add `Include ~/.ssh/devbox.conf` at
  the top of `~/.ssh/config` once; devbox only updates the managed file.

## Identity

Provisioning creates an unprivileged `devbox` account:

- Home `/home/devbox`, writable workspace `/home/devbox/workspace`. The home is
  bind-mounted onto the Colima data disk (`/mnt/lima-*`) so the toolchain and
  caches do not fill the small fixed-size guest root disk. On an existing VM the
  first converge moves the current home contents onto the data disk before
  switching the mount, so nothing is hidden and the root-disk space is freed.
- No sudo, no Docker group membership, and no access to the rootful Docker
  socket. `devbox` has a separate per-user rootless Engine, managed by its
  systemd user service and enabled at boot through root-managed lingering.
- Guest agents run as the same `devbox` account and share its writable files,
  workspace, and provider credentials; there is no per-agent guest-user
  sandbox.
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
  CLI, subordinate UID/GID ranges and lingering for rootless Docker, matching
  rootless tooling from the already-configured Engine source, and ARM64
  Chromium), then `state.sh` (ask the guest user to seed its own configuration
  and generate secrets, validate those files as data, and stage the service
  definition as root).
- unprivileged: `tools.sh` installs and starts the per-user rootless Docker
  service as `devbox`, configures the CLI and shell, then `verify.sh` checks
  both Docker endpoints and the browser before recording the digest marker at
  `~/.local/state/devbox/provision.sha256`.

A matching marker skips the bundle work after re-verifying the installed tree
against its digest. `devbox provision` forces a full run. Direct SSH is only
authorized after `verify.sh` passes; a failed run removes the managed alias.

Guest-local configuration lives under `/home/devbox/.config/devbox/`
(directory 0700, files 0600):

- `config` — non-secret defaults (Git identity, PostgreSQL user/database/port),
  seeded once from the host and then maintained in the guest.
- `secrets` — service secrets generated inside the guest only. The PostgreSQL
  password is not seeded from the host configuration; both service passwords
  persist on the VM disk stored on the host.

Host proxy variables are cleared from Colima invocations by default. Setting
`DEVBOX_USE_HOST_PROXY=true` in the host `.env` explicitly permits exported
host proxy variables to propagate into the guest and the Colima-managed rootful
Docker daemon when the VM starts. If proxy URLs contain credentials, they
persist on the VM disk.
Proxy configuration is not a network boundary. Changes apply on the next VM
start; run `devbox stop` then `devbox start` to apply them.

Agent guidance prohibits using host mounts, host-gateway addresses or services,
SSH, forwarding, or other channels to read, write, or execute anything on the
host. Ordinary external network use is allowed. This is policy guidance for
agents, not technical network enforcement.

## Services

PostgreSQL (`postgres:18.3`) and Valkey (`valkey/valkey:8.1`) are defined by
`provision/config/services/compose.yaml`. Provisioning stages the definition and
credentials at `/var/lib/devbox/services/` (root-owned, mode 0600) with
persistent data below `services/data/`, but does not start the containers.
`devbox services start|stop|status` drives `docker compose` as root in the
guest and explicitly selects the rootful `/var/run/docker.sock`, regardless of
inherited Docker context variables. Both services publish to `127.0.0.1` only;
the `devbox` user reaches them over loopback using the guest-local credentials.
Direct `docker` commands run as `devbox` instead use its rootless daemon at
`/run/user/<uid>/docker.sock`; that daemon and the root-managed services daemon
have separate data and permissions.

## Rootless Docker, Chromium, and guest metrics

The rootless daemon uses the Docker Engine and rootless setup tooling matching
the Engine already installed by Colima. Provisioning may install the matching
rootless-extras package only from the already-configured Engine APT source, and
will not add a repository or upgrade/replace the rootful Engine. It configures
at least 65,536 non-overlapping subordinate UIDs/GIDs for `devbox`, enables
lingering as root, then runs `dockerd-rootless-setuptool.sh` and
`systemctl --user` as `devbox`. The login shell defaults the Docker CLI to the
per-user socket and does not grant access to `/var/run/docker.sock`.

Ubuntu 24.04's `chromium-browser` APT entry is a Snap transition, so system
provisioning installs the actual ARM64 `chromium` snap at
`/snap/bin/chromium`. The managed `.zshenv` block exports
`PUPPETEER_EXECUTABLE_PATH=/snap/bin/chromium` only when the variable is unset
or empty. A non-empty inherited value is retained, and because the managed
block precedes existing `.zshenv` content, a later user/project assignment
overrides it. A project can select another executable for a command with
`PUPPETEER_EXECUTABLE_PATH=/path/to/chromium npm test`, or leave Puppeteer to
use its bundled browser with `env -u PUPPETEER_EXECUTABLE_PATH npm test` (also
use that form for the project's install command if it needs to download the
bundled browser). `PUPPETEER_SKIP_DOWNLOAD` is never set globally and remains a
project-scoped install choice for projects using a system browser.

Finsights' Node Exporter Compose stack uses host networking, host PID/UTS, and
a read-only `/:/host:ro,rslave` mount. With rootful Linux Docker, `host` modes
refer to the daemon host's namespaces. Under rootless Docker, their availability
and meaning depend on the Engine server version and rootless runtime; do not
assume they refer to the guest's initial network, PID, or UTS namespaces, or
that Compose settings alone expose complete guest metrics. Rootless host
networking requires Docker Engine server version **29.5 or newer**; this
Devbox provisioning does not silently upgrade the existing Engine.

The read-only guest-root bind mount is also permission-limited: the rootless
daemon runs as `devbox`, and `:ro` prevents writes but does not elevate access to
files that the daemon or container cannot read. User-namespace mappings and
guest filesystem permissions can therefore limit the view and the metrics
collected. These settings do not make the exporter container root, enable
privileged mode, or expose the macOS host. Keep the exporter non-root and
preserve the read-only `/:/host:ro,rslave` mount.
A VM smoke test against the actual rootless daemon is required to confirm
namespace behavior and the metrics that are actually available. Do not infer
coverage from the Compose file.

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
`init` and the read-only commands do not take the lock. Stale locks
are removed only when their recorded process no longer exists. `devbox stop`
stops the VM; `devbox destroy` requires the profile name to be typed and then
deletes the VM together with its runtime data and the managed SSH alias.
