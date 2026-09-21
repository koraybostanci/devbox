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

Releases are on the [Releases page](https://github.com/koraybostanci/devbox/releases).
Download the assets, verify the checksum and signature against the committed
key, then install (requires an authenticated `gh`):

```sh
gh release download --repo koraybostanci/devbox --pattern '*'
shasum -a 256 -c SHA256SUMS
gh api -H 'Accept: application/vnd.github.raw' \
    repos/koraybostanci/devbox/contents/release-signing-key.pub.pem > release-signing-key.pub.pem
openssl dgst -sha256 -verify release-signing-key.pub.pem \
    -signature SHA256SUMS.sig SHA256SUMS
tar -xzf devbox-<version>.tar.gz
DEVBOX_RELEASE_PUBKEY=release-signing-key.pub.pem \
    ./devbox-<version>/scripts/release.sh install devbox-<version>.tar.gz
```

`install` verifies the archive before touching the install root, installs under
`~/.local/share/devbox/releases/<version>`, activates
`~/.local/share/devbox/current`, and links `devbox` onto your `PATH`. Release
installs keep host configuration at `~/.config/devbox/env` (mode 0600): run
`devbox init`, edit it, and run `devbox init` again.

Upgrades install alongside the old version and keep your configuration. If the
VM was created by a checkout or an earlier release, claim it while stopped:

```sh
devbox stop
devbox install --adopt
```

Manage installed versions with the shipped tooling:

```sh
~/.local/share/devbox/current/scripts/release.sh list
~/.local/share/devbox/current/scripts/release.sh use <version>
~/.local/share/devbox/current/scripts/release.sh prune [--keep N]
```

### Publish a release (maintainer)

`VERSION` is the source of truth. Bump it in a PR and merge to `main`; the
`Release` workflow runs the checks, builds and signs the archive from that
commit, and opens a **draft** release. Review the notes and assets, then click
**Publish release** — the workflow never publishes on its own. Bump `VERSION`
for the next release.

Details, recovery, and the local equivalents of the workflow are in
[docs/release-checklist.md](docs/release-checklist.md); installer behavior is in
[docs/troubleshooting.md](docs/troubleshooting.md).

## Security

- The guest has no host filesystem mounts and does not reuse the host SSH agent.
- The daily identity is the unprivileged `devbox` account (no sudo, no Docker
  group, no Docker socket).
- Service secrets are generated in the guest and never stored on the host.
- Releases are signed; verification fails closed.
