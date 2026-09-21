# devbox

A disposable, isolated Ubuntu development VM on macOS, powered by Colima.

Your editors and project files stay on macOS; shells, compilers, CLIs, Docker,
and project processes run inside the VM. The guest is fully self-contained —
there are no host filesystem mounts — so you can rebuild or destroy it without
touching your Mac.

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

Signed releases install without a checkout:

```sh
scripts/release.sh build <version>     # dist/devbox-<version>.tar.gz
scripts/release.sh verify <archive>    # checksum, manifest, signature
scripts/release.sh install <archive>   # ~/.local/share/devbox/releases
```

`install` activates `~/.local/share/devbox/current`.

## Security

- The guest has no host filesystem mounts and does not reuse the host SSH agent.
- The daily identity is the unprivileged `devbox` account (no sudo, no Docker
  group, no Docker socket).
- Service secrets are generated in the guest and never stored on the host.
- Releases are signed; verification fails closed.
