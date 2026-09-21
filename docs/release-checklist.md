# Release Checklist

Run this on supported and current macOS, both on Apple Silicon.

## Static gate

- Run `scripts/check.sh`; confirm all checks pass.
- Confirm CI passes on the proposed revision.

## Host baseline

Record before setup:

```sh
git config --global --list
ssh-add -l
ssh -G github.com
```

## Clean install

On an account without devbox state:

```sh
./devbox init
# edit .env, then run init again
./devbox start
./devbox status
./devbox connect        # workspace at /home/devbox/workspace
./devbox exec id -un    # devbox
./devbox services status
./devbox stop
```

Confirm the host has no devbox mounts and that `devbox` on the guest cannot
run Docker or read `/var/lib/devbox/services/env`.

## Acceptance

Confirm on macOS:

- `scripts/check.sh` passes and CI is green.
- `devbox start`, `devbox status`, `devbox connect`, `devbox services status`
  work from a clean account with only Colima/OpenSSH/macOS built-ins.
- `devbox auth status` and `devbox db info` report correctly.
- `devbox destroy` removes the VM and its runtime data.

## Release artifacts

`VERSION` is the source of truth for the tagged revision; bump it, commit it,
then tag `v<version>` or dispatch the `Release` workflow with the same
version.

```sh
scripts/release.sh build
scripts/release.sh verify "dist/devbox-<version>/devbox-<version>.tar.gz"
```

Confirm the `Release` workflow refuses a tag or dispatch version that does not
match `VERSION`, signs with the `RELEASE_SIGNING_KEY` secret, verifies against
the committed public key, and publishes the archive, `SHA256SUMS`, and
`SHA256SUMS.sig`.

## Published-release round trip

On a clean account, download a published release, check the checksum and the
signature against the committed public key (fetched out of band), then install
it:

```sh
shasum -a 256 -c SHA256SUMS
openssl dgst -sha256 -verify release-signing-key.pub.pem \
    -signature SHA256SUMS.sig SHA256SUMS
DEVBOX_RELEASE_PUBKEY=release-signing-key.pub.pem \
    ./devbox-<version>/scripts/release.sh install devbox-<version>.tar.gz
```

Confirm:

- `~/.local/share/devbox/current/scripts/release.sh list` marks the installed
  version active and `~/.local/share/devbox/current` points at it.
- The download-directory invocation works with relative arguments: the shipped
  `scripts/release.sh` resolves the archive and `DEVBOX_RELEASE_PUBKEY` against
  the directory it was invoked from.
- `devbox init` creates `~/.config/devbox/env` (mode 0600) from the archive's
  `.env.example`; edit it and rerun.
- `devbox start` claims the VM; if the VM predates the release, `devbox stop`
  then `devbox install --adopt` claims the existing profile.
- Installing the next release keeps `~/.config/devbox/env` and does not
  invalidate the Colima profile.

## Destructive recovery

`devbox destroy` removes the VM and its container runtime data. Back up
anything on the guest disk you still need first; host files are untouched
(devbox has no host mounts).
