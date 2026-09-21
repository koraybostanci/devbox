# devbox

A disposable, isolated Ubuntu development VM on macOS, powered by Colima.

Your editors and SSH clients run on macOS; the project files, shells,
compilers, CLIs, Docker, and project processes all live inside the VM. The
guest is fully self-contained — there are no host filesystem mounts — so you
can rebuild or destroy it without touching your Mac.

## Requirements

- macOS 13+ on Apple Silicon
- [Colima](https://colima.run) 0.10.3 or newer
- The OpenSSH client (built in)

Nothing else: no Homebrew, `jq`, `yq`, Docker, or Docker Compose on the host.

## Quick start

```sh
./devbox init          # create .env, then edit it and run init again
./devbox start         # create and provision the VM
./devbox connect       # open a zsh shell in the guest
./devbox stop
```

`./devbox install` puts `devbox` on your `PATH` (a symlink to this checkout).

### Configuration

`.env` (mode 0600, gitignored) holds only non-secret defaults:

```sh
export GIT_NAME="Your Name"
export GIT_EMAIL="you@personal.com"
export POSTGRES_USER="dev"
export POSTGRES_DB="dev"
export POSTGRES_PORT="15432"
export DEVBOX_CPU="4"
export DEVBOX_MEMORY="4"
export DEVBOX_DISK="60"
```

Secrets are never taken from the host: the guest generates its own service
credentials.

## Daily workflow

```sh
devbox start                 # start and converge the VM
devbox connect               # shell in the guest
devbox exec <command>        # run one command in the guest
devbox status                # VM state and resources
devbox stop [--force]
```

Your code lives on the guest disk at `/home/devbox/workspace`; it survives
stop/start and is removed only by `devbox destroy`.

### Remote access

`devbox start` adds a marked `Host devbox` entry to your OpenSSH config
(`~/.ssh/config`, plus a copy under `~/.ssh/config.d/devbox`). Point editors,
`git`, and other tools at host `devbox` to work with the guest files directly
over SSH; `devbox destroy` removes the entry.

## Services

PostgreSQL and Valkey run as root-managed containers inside the guest, bound to
`127.0.0.1` only. The unprivileged `devbox` user cannot control Docker; it
reaches the services over loopback using credentials in
`~/.config/devbox/secrets`.

```sh
devbox services status
```

## Authentication (optional)

Provider sign-in is optional and happens entirely inside the guest; no host
credentials are used or stored.

```sh
devbox auth status                 # github, claude, opencode, databricks
devbox auth login github           # also: claude, opencode, databricks
devbox db info                     # PostgreSQL connection settings
```

Credentials are written inside the guest and survive stop/start; they are
removed only by `devbox destroy`.

## Maintenance

```sh
devbox provision             # force non-destructive provisioning
devbox destroy               # remove the VM and its container runtime data
devbox uninstall             # remove the devbox symlink
```

## Releases

### Install a published release

Releases are published on the [Releases page](https://github.com/koraybostanci/devbox/releases)
as `devbox-<version>.tar.gz`, `SHA256SUMS`, and `SHA256SUMS.sig`. Download
them with an authenticated `gh`, fetch the committed public key out of band
(from the repository, not from the release assets), and verify the checksum
and signature before the archive is extracted into the install root:

```sh
gh release download --repo koraybostanci/devbox --pattern '*'
shasum -a 256 -c SHA256SUMS
gh api -H 'Accept: application/vnd.github.raw' \
    repos/koraybostanci/devbox/contents/release-signing-key.pub.pem > release-signing-key.pub.pem
openssl dgst -sha256 -verify release-signing-key.pub.pem \
    -signature SHA256SUMS.sig SHA256SUMS
tar -xzf devbox-<version>.tar.gz
DEVBOX_RELEASE_PUBKEY=release-signing-key.pub.pem \
    ./devbox-<version>/scripts/release.sh install devbox-<version>.tar.gz [--force]
```

`scripts/release.sh install` resolves the archive and key paths against the
directory you invoke it from, verifies the checksum, signature, layout, and
per-file `MANIFEST` (extracting into a private temporary directory) before
extracting into the install root, then installs below
`~/.local/share/devbox/releases/<version>`, activates
`~/.local/share/devbox/current`, and puts `devbox` on your `PATH`. A missing
`SHA256SUMS.sig` is a hard failure unless `DEVBOX_ALLOW_UNSIGNED=1` is set for
local testing. Reinstalling a version whose tree still matches its `MANIFEST`
is idempotent; a tree that no longer matches is replaced, and `--force`
replaces an existing version directory even when it is intact.

Upgrades install a new release alongside the old one and leave the other
versions in place, so `use` can switch back. The installed tree carries the
same tooling:

```sh
~/.local/share/devbox/current/scripts/release.sh list   # active is marked
~/.local/share/devbox/current/scripts/release.sh use <version>
~/.local/share/devbox/current/scripts/release.sh prune [--keep N]  # drop old installs
```

Release installs keep host configuration at `~/.config/devbox/env` (mode
0600), so upgrades keep your settings; a legacy in-tree `.env` is copied there
once, before its release tree is replaced. Run `devbox init` to create it from
the archive's `.env.example`, edit it, then run `devbox init` again.

If the existing VM was created by a checkout or by an earlier release, claim
it from the new installation while the VM is stopped:

```sh
devbox stop
devbox install --adopt
```

### Publish a release (maintainer)

`VERSION` is the source of truth. Merge a commit that bumps `VERSION` to `main`
and the `Release` workflow runs: it runs the `Check` workflow, waits for
approval on the protected `release` environment, then checks out the commit
that last changed `VERSION`, builds the archive from it, signs it with the
`RELEASE_SIGNING_KEY` environment secret, verifies it against the committed
public key, creates the `v<version>` tag at that commit, and publishes the
archive, `SHA256SUMS`, and `SHA256SUMS.sig` with automatically generated
release notes. Suffixed versions such as `0.1.0-rc1` are published as
prereleases. The workflow creates the tag; do not push tags by hand.

`workflow_dispatch` is recovery-only: dispatch it on `main` with the version
already in `VERSION` (the input must match it). Recovery resolves the current
`VERSION` to the commit that last changed it, rebuilds that commit, and
re-uploads the missing assets in place instead of recreating the release; a run
that finds a complete published release fails, so bump `VERSION` for a new
release instead of rerunning an old one. Because recovery always rebuilds the
commit that last changed `VERSION`, an older incomplete release cannot be
recovered after `VERSION` moves on; release a new version instead.

The local tooling mirrors the workflow:

```sh
scripts/release.sh build                                        # dist/devbox-<version>
scripts/release.sh sign dist/devbox-<version>/devbox-<version>.tar.gz --key <key>
scripts/release.sh verify dist/devbox-<version>/devbox-<version>.tar.gz
scripts/release.sh install dist/devbox-<version>/devbox-<version>.tar.gz
scripts/release.sh list
scripts/release.sh use <version>
scripts/release.sh prune [--keep N]
```

`build` with no argument uses `VERSION` and writes
`dist/devbox-<version>/devbox-<version>.tar.gz` with sibling `SHA256SUMS` and
(when signed) `SHA256SUMS.sig`. `verify` fails closed and checks the signature
against the committed public key (override with `DEVBOX_RELEASE_PUBKEY`).
`prune` bounds the installed `releases/` tree: it removes non-active releases,
keeping the active release plus the `N` most recently modified non-active
releases (default 0), and removes staging directories older than 24 hours; the
active release is never removed.

## Security

- The guest has no host filesystem mounts and does not reuse the host SSH agent.
- The daily identity is the unprivileged `devbox` account (no sudo, no Docker
  group, no Docker socket).
- Service secrets are generated in the guest and never stored on the host.
- Releases are signed; verification fails closed.
