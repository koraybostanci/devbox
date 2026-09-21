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
- Increase `DEVBOX_DISK` in `.env` (for example `60`), then `devbox destroy`
  and `devbox start` (resizing the data disk requires recreating it).
- Clear a failed build before retrying:
  `devbox exec rm -rf '/tmp/python-build.*'`.

## Services

PostgreSQL and Valkey are root-managed and bound to `127.0.0.1` only. Check
them with `devbox services status`. Credentials live in
`~/.config/devbox/secrets` inside the guest. To change the PostgreSQL port,
update `POSTGRES_PORT` in `.env` and run `devbox provision`.

## Release installation

`scripts/release.sh verify` fails closed: it requires `SHA256SUMS.sig` and a
valid signature against the committed public key (`DEVBOX_RELEASE_PUBKEY`
overrides the default), plus a single `devbox-<version>` top-level directory,
regular-file/directory entry types, and a MANIFEST that matches every archived
file. Unsigned archives are accepted only with `DEVBOX_ALLOW_UNSIGNED=1`, for
local builds; never install an archive that does not verify.

`scripts/release.sh install` verifies the archive before extracting it into
the install root, then installs below
`~/.local/share/devbox/releases/<version>` and activates
`~/.local/share/devbox/current`. Repeat installs of the same version are
idempotent; a failed install leaves `current` pointing at the previous
release. Other releases are left in place, so `use` can switch back; `--force`
replaces an existing version directory even when it still matches its
MANIFEST.

Release installs keep host configuration at `~/.config/devbox/env` (mode
0600). A `.env` left inside a versioned release directory is ignored with a
warning, and `scripts/release.sh install` copies it to the stable path once if
the stable file does not exist yet, before the tree that carries it is
replaced.

Installed releases accumulate under `~/.local/share/devbox/releases`. Bound the
tree with `scripts/release.sh prune [--keep N]`, which removes non-active
releases, keeps the active release plus the `N` most recently modified
non-active releases (default 0), and removes staging directories older than 24
hours. The active release is never removed; version-named symlinks are skipped
and a releases directory that is itself a symlink is refused.

A `Release` workflow that fails after the tag exists is recovered by
dispatching it again from `main` with the version already in `VERSION` (the
input must match); recovery rebuilds the commit that last changed `VERSION` and
uploads the missing assets in place. A complete published release is never
replaced, so bump `VERSION` to release again. Once `VERSION` has moved on, an
older incomplete release can no longer be recovered by dispatch.

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
