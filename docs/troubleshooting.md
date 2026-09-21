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
(single or double quotes are stripped):

```sh
chmod 600 .env
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
onto the data disk so toolchains and caches use it. If provisioning still runs
out of space:

- Confirm the bind mount with `devbox exec df -h /home/devbox` (it should show
  the larger data disk, not `/dev/root`).
- Increase `DEVBOX_DISK` in `.env` (for example `60`), then `devbox destroy`
  and `devbox start`.
- Clear a failed build before retrying:
  `devbox exec rm -rf '/tmp/python-build.*'`.

## Services

PostgreSQL and Valkey are root-managed and bound to `127.0.0.1` only. Check
them with `devbox services status`. Credentials live in
`~/.config/devbox/secrets` inside the guest. To change the PostgreSQL port,
update `POSTGRES_PORT` in `.env` and run `devbox provision`.

## Release installation

A failed `scripts/release.sh verify` means the archive, checksum, manifest, or
signature did not validate; do not install it. Verification fails closed when a
signed archive has no committed public key.

## Checkout moved or renamed

The Colima profile records the checkout path in an ownership marker. Stop the VM
before moving the repository, then inspect the error and update the marker
deliberately from the new path:

```sh
devbox stop
cat "$HOME/.colima/devbox/.devbox-owner"
```

Do not rewrite the marker to claim a profile created by another checkout.
