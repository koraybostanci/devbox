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

`.env` must be mode 0600 and contain only supported `KEY=value` assignments
(single or double quotes are stripped). Release installs keep this file at
`~/.config/devbox/env` instead of the versioned release directory:

```sh
chmod 600 .env            # checkout
chmod 600 ~/.config/devbox/env   # release install
```

Supported keys: `GIT_NAME`, `GIT_EMAIL`, `POSTGRES_USER`, `POSTGRES_DB`,
`POSTGRES_PORT`, `DEVBOX_CPU`, `DEVBOX_MEMORY`, `DEVBOX_DISK`. Unsupported keys
are ignored with a warning. `POSTGRES_PASSWORD` is generated inside the guest
and is never read from the host.

## VM state or SSH

```sh
devbox status
colima list
ssh devbox true
```

The IDE/CLI host is `devbox`; Colima assigns its localhost port dynamically.
`devbox start` refreshes the managed SSH configuration. Agent forwarding is
disabled by design:

```sh
ssh -G devbox | grep -i forwardagent
```

If provisioning fails before direct SSH is authorized, `devbox connect` is
unavailable; inspect the VM with `colima ssh -p devbox`, which uses Colima's
generated administrative account.

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
onto the data disk so toolchains and caches use it. The first converge on an
existing VM moves the current home contents onto the data disk (and clears the
root-disk copy) before mounting, so it can be applied with a plain
`devbox start`. If provisioning still runs out of space:

- Confirm the bind mount with `devbox exec df -h /home/devbox` (it should show
  the larger data disk, not `/dev/root`).
- Back up anything you need first: `devbox destroy` deletes the entire VM disk,
  including the guest workspace `/home/devbox/workspace`, installed toolchains
  and caches, service data, and credentials. For example:
  `devbox exec tar -C /home/devbox -czf - workspace > workspace.tgz`
- Set `DEVBOX_DISK` in `.env` to a value larger than the current one, then
  `devbox destroy` and `devbox start` (resizing the data disk requires
  recreating it).
- Clear a failed build before retrying:
  `devbox exec rm -rf '/tmp/python-build.*'`.

## Services

PostgreSQL and Valkey are root-managed and bound to `127.0.0.1` only. Check
them with `devbox services status`. Credentials live in
`~/.config/devbox/secrets` inside the guest. Valkey listens on
`127.0.0.1:16379`, a guest-only port that is not published to the host.

To change the PostgreSQL port, edit `~/.config/devbox/config` inside the guest
(`devbox connect`, or `devbox exec` with a command) and run `devbox provision`.
The guest copy is authoritative after the first provision, so `POSTGRES_PORT`
changes in `.env` are ignored; deleting `~/.config/devbox/config` makes the
next provision re-seed it from `.env`.

## Release installation

`scripts/release.sh verify` fails closed: it requires `SHA256SUMS.sig` and a
valid signature against the committed public key (`DEVBOX_RELEASE_PUBKEY`
overrides the default), plus a single `devbox-<version>` top-level directory
and a MANIFEST that matches every archived file. Unsigned archives are accepted
only with `DEVBOX_ALLOW_UNSIGNED=1`, for local builds; never install an archive
that does not verify.

A failed install leaves the previous release active, and `--force` replaces an
existing version directory. Installed releases live below
`${XDG_DATA_HOME:-$HOME/.local/share}/devbox`, are activated through `current`,
and are managed with the shipped `list`, `use`, and `prune` commands. Release
installs keep host configuration at `~/.config/devbox/env` (mode 0600), so a
`.env` inside an installed release tree is ignored with a warning.

See [docs/release-checklist.md](release-checklist.md) for release operations
and [docs/architecture.md](architecture.md) for installer and prune internals.

## Checkout moved or renamed

The Colima profile records its install root in an ownership marker
(`~/.colima/devbox/.devbox-owner`): the checkout directory for a checkout, or
the data root for release installs, so release upgrades keep the profile.
Stop the VM before moving a checkout, then claim the existing profile from the
new path:

```sh
devbox stop
devbox install --adopt
```

`devbox install --adopt` never adopts a running VM. Do not rewrite the marker
to claim a profile created by another installation.
