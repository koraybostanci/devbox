# Release Checklist

Run this on current macOS; Apple Silicon (arm64) is the only supported
platform.

## Static gate

- Run `scripts/check.sh`; confirm all checks pass.
- Confirm CI passes on the proposed revision.

## Clean install

On an account without devbox state:

```sh
./devbox init
# edit .env, then run init again
./devbox start
./devbox status
./devbox connect        # workspace at /home/devbox/workspace
./devbox exec id -un    # devbox
./devbox auth status
./devbox db info
./devbox services status
./devbox stop
```

Confirm the host has no devbox mounts and that `devbox` on the guest cannot
run Docker or read `/var/lib/devbox/services/env`.

## Release artifacts

`VERSION` is the source of truth for the released revision. Merge a commit that
bumps `VERSION` into `main`; the `Release` workflow runs the `Check` workflow,
then checks out the commit that last changed `VERSION`, builds the archive from
it, signs it with the `RELEASE_SIGNING_KEY` secret, verifies it against the
committed public key, and creates a draft release targeting that commit with the
archive, `SHA256SUMS`, and `SHA256SUMS.sig` plus generated release notes.
Suffixed versions such as `0.1.0-rc1` are drafted as prereleases. The
`v<version>` tag is created when the draft is published, so do not push tags by
hand.

Review the draft on the Releases page (the notes and all three assets), then
click **Publish release**. The workflow never publishes on its own. After
publishing, bump `VERSION` for the next release.

If a draft run fails before all assets are uploaded, rerun it from `main` with
`workflow_dispatch` using the version already in `VERSION` (the input must
match); recovery rebuilds the commit that last changed `VERSION` and re-uploads
the missing assets into the draft, which still needs manual publishing.
Recovery requires the draft to target the release commit: a tagged draft needs
its tag at that commit, and an untagged draft (the normal state while it is
still a draft) needs its target commit to match it. A draft whose tag is at
another commit, or whose target commit does not match, cannot be recovered. A
published release is never overwritten; bump `VERSION` for the next release
instead. After `VERSION` has moved on, an older incomplete draft cannot be
recovered by dispatch; release a new version.

Mirror the build locally. `build` writes the archive and its `SHA256SUMS` and
leaves signing to a separate command:

```sh
scripts/release.sh build
scripts/release.sh sign "dist/devbox-<version>/devbox-<version>.tar.gz" \
    --key <private-key.pem>
DEVBOX_RELEASE_PUBKEY=<public-key.pem> \
    scripts/release.sh verify "dist/devbox-<version>/devbox-<version>.tar.gz"
```

`DEVBOX_ALLOW_UNSIGNED=1` skips the signature check for local-only builds; never
install or publish an archive that does not verify.

Old installs accumulate under
`${XDG_DATA_HOME:-$HOME/.local/share}/devbox/releases`; prune them while keeping
the active release:

```sh
data_root="${XDG_DATA_HOME:-$HOME/.local/share}/devbox"
"$data_root/current/scripts/release.sh" prune --keep 1
```

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

- `${XDG_DATA_HOME:-$HOME/.local/share}/devbox/current/scripts/release.sh list`
  marks the installed version active and `current` points at it.
- The download-directory invocation works with relative arguments: the shipped
  `scripts/release.sh` resolves the archive and `DEVBOX_RELEASE_PUBKEY` against
  the directory it was invoked from.
- `devbox init` creates `~/.config/devbox/env` (mode 0600) from the archive's
  `.env.example`; edit it and rerun.
- `devbox start` claims the VM; if the VM predates the release, `devbox stop`
  then `devbox install --adopt` claims the existing profile.
- Installing the next release keeps `~/.config/devbox/env` and does not
  invalidate the Colima profile.

## Teardown

`devbox destroy` removes the VM, its container runtime data, and the managed
SSH configuration. Back up anything on the guest disk you still need first;
host files are untouched (devbox has no host mounts).
