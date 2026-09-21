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
run Docker or read `/var/lib/devbox-v2/services/env`.

## Acceptance

Run the harnesses and confirm they pass:

```sh
bash scripts/accept-phase3.sh
bash scripts/accept-phase4a.sh
bash scripts/accept-phase5.sh
bash scripts/accept-phase6.sh
bash scripts/accept-phase7.sh
```

## Release artifacts

```sh
scripts/release.sh build <version>
scripts/release.sh verify "dist/devbox-<version>.tar.gz"
```

Confirm the `Release` workflow signs with the `RELEASE_SIGNING_KEY` secret and
publishes the archive, `SHA256SUMS`, and `SHA256SUMS.sig`, and that a downloaded
artifact verifies against the committed public key.

## Destructive recovery

`devbox destroy` removes the VM and its container runtime data. Back up
anything on the guest disk you still need first; host files are untouched
(devbox has no host mounts).
