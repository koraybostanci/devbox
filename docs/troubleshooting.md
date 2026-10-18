# Troubleshooting

Start with:

```sh
devbox status
devbox services status
```

## Missing prerequisites

devbox needs macOS 13+, Apple Silicon, Colima 0.10.3+, and the OpenSSH client.
Install Colima from <https://colima.run>. No other host tooling is required.

## `.env` rejected

Run `devbox init` to rewrite the configuration interactively; it keeps the
current values as defaults. To keep the configuration somewhere other than the
checkout's `.env`, run devbox with `DEVBOX_ENV_FILE=/path/to/env` in its
environment. `.env` must be mode 0600 and contain only supported
`KEY=value` assignments (single or double quotes are stripped):

```sh
chmod 600 .env
```

Supported keys: `GIT_NAME`, `GIT_EMAIL`, `POSTGRES_USER`, `POSTGRES_DB`,
`POSTGRES_PORT`, `DEVBOX_CPU`, `DEVBOX_MEMORY`, `DEVBOX_DISK`, and
`DEVBOX_USE_HOST_PROXY`. `POSTGRES_PORT` must be 1–65535. Unsupported keys are
ignored with a warning. `POSTGRES_PASSWORD` is generated inside the guest and
is never read from the host. `POSTGRES_USER` and `POSTGRES_DB` accept 1–63 ASCII
letters, digits, dots, dashes, or underscores.

Guest proxy propagation is opt-in via `DEVBOX_USE_HOST_PROXY="true"` and is
applied at the next VM stop/start; see
[architecture.md](architecture.md#host--guest-boundary) for what that exposes.

## VM state or SSH

```sh
devbox status
colima list
ssh devbox true
```

The IDE/CLI host is `devbox`; Colima assigns its localhost port dynamically.
`devbox start` refreshes the managed SSH configuration and re-authorizes the
host key for the guest account. Agent forwarding is disabled by design:

```sh
ssh -G devbox | grep -i forwardagent
```

If provisioning fails before direct SSH is authorized, `devbox connect` is
unavailable; inspect the VM with `colima ssh -p devbox`, which uses Colima's
generated administrative account.

## SSH configuration conflicts

Add `Include ~/.ssh/devbox.conf` at the top of `~/.ssh/config` once. The
`devbox start` command updates `~/.ssh/devbox.conf` and checks that its
generated endpoint is reachable. The Include should come before other `Host`
blocks so its values take precedence.

If the alias does not work, inspect the effective result with:

```sh
ssh -G devbox
```

If a system-wide or user-level SSH setting overrides the alias, move the
Include above the conflicting user-level options and rerun `devbox start`.

## Another command is running

Mutating commands serialize on a lock, so a concurrent command fails with:

```text
another devbox command is running (PID ...)
```

Wait for the running command to finish, or stop it if it is stuck. A stale lock
is removed automatically when the recorded process no longer exists; do not
delete the lock directory by hand.

## Provisioning failure

Provisioning errors name the failing stage and leave the VM running for
diagnosis. Correct the cause and rerun:

```sh
devbox provision
```

For DNS failures, configure Colima's DNS rather than editing guest resolver
files. For disk failures, check free space on macOS and in the guest before
increasing `DEVBOX_DISK`.

## Provisioning fails with `No space left on device`

The guest root disk is a fixed-size image disk (~20 GiB), separate from the
Colima data disk that `DEVBOX_DISK` sizes. The `devbox` home is bind-mounted
from the data disk so toolchains and caches use it; provisioning fails rather
than leave the home on the root disk. If provisioning still runs out of space:

- Confirm the bind mount with `devbox exec df -h /home/devbox` (it should show
  the larger data disk, not `/dev/root`), or inspect it with
  `devbox exec findmnt -T /home/devbox`.
- Back up anything you need first: `devbox destroy` deletes the entire VM disk,
  including the guest workspace `/home/devbox/workspace`, installed toolchains
  and caches, service data, and credentials. For example:
  `devbox exec tar -C /home/devbox -czf - workspace > workspace.tgz`
- Set `DEVBOX_DISK` in `.env` to a value larger than the current one, then
  `devbox destroy` and `devbox start` (resizing the data disk requires
  recreating it).
- Clear a failed build before retrying. `devbox exec` arguments reach the
  guest verbatim — no guest-side glob or shell expansion — so select the
  paths with a guest-side `find` instead of a glob:
  `devbox exec find /tmp -maxdepth 1 -name 'python-build.*' -delete`.

## Services

Valkey listens on `127.0.0.1:16379`, a guest-only port that is not published
to the host. The full service contract is in
[architecture.md](architecture.md#services).

To change the PostgreSQL port, edit `~/.config/devbox/config` inside the guest
(`devbox connect`, or `devbox exec` with a command) and run `devbox provision`.
Use a port from 1–65535. The guest copy is authoritative after the first
provision, so `POSTGRES_PORT` changes in `.env` are ignored; deleting
`~/.config/devbox/config` makes the next provision re-seed it from `.env`.

## Checkout moved or renamed

The VM profile is keyed by name and carries no host path, so moving or renaming
the checkout is safe. Run `devbox init` again from the new location (press Enter
to keep the current values) to refresh the `devbox` symlink on your `PATH`.

## Upgrading devbox

An existing VM converges in place on the next `devbox start`. `devbox destroy`
followed by `devbox start` remains the clean path when you want a fresh guest,
and is required for a VM whose home still lives on the root disk.
