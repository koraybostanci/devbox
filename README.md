# devbox

A disposable, isolated Ubuntu development VM on macOS, powered by Colima.

Your editors and SSH clients run on macOS; the project files, shells,
compilers, CLIs, and project processes all live inside the VM, and the managed
PostgreSQL and Valkey containers run there under root. The guest is fully
self-contained — there are no host filesystem mounts — so you can rebuild or
destroy it without touching your Mac.

Design and internals are in [docs/architecture.md](docs/architecture.md).

## Requirements

- macOS 13+ on Apple Silicon
- [Colima](https://colima.run) 0.10.3 or newer
- The OpenSSH client (built in)

Nothing else: no Homebrew, `jq`, `yq`, Docker, or Docker Compose on the host.

## Quick start

```sh
./devbox init          # answer the prompts; installs the devbox command
devbox start           # create and provision the VM
devbox connect         # open a zsh shell in the guest
devbox stop
```

`devbox init` installs a `devbox` symlink into a writable directory on your
`PATH` (usually `~/.local/bin`), so every later command is just `devbox`.

### What's provisioned

Node.js and npm (via nvm), Python and pyenv, uv, Go, Rust, Java 21, Claude
Code, OpenCode, the Databricks CLI, `yq`, `gh`, `jq`, and zsh with oh-my-zsh.
[`provision/versions.env`](provision/versions.env) is the source of truth for
pinned versions; `gh` and `jq` come from Ubuntu packages.

### Configuration

`devbox init` asks for the settings and writes `.env` (mode 0600, gitignored);
rerun `devbox init` to change them. The defaults come from the host Git
identity and the built-in values shown in brackets:

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

The identity and PostgreSQL keys are seeded into the guest on first provision
and maintained in the guest at `~/.config/devbox/config` afterwards; the
`DEVBOX_*` resource keys size the VM and changing them requires recreating it.
See [docs/troubleshooting.md](docs/troubleshooting.md) to change either group.

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
(`~/.ssh/config`) and authorizes your Colima SSH key for the unprivileged
`devbox` guest account. Point editors, `git`, and other tools at host `devbox`
to work with the guest files directly over SSH; `devbox destroy` removes the
entry.

## Services

PostgreSQL and Valkey are provisioned inside the guest as root-managed
containers but stay stopped until you start them:

```sh
devbox services start
devbox services status
devbox services stop
```

They are bound to `127.0.0.1` only. The unprivileged `devbox` user cannot
control Docker; it reaches the services over loopback using credentials in
`~/.config/devbox/secrets`. Data lives below `/var/lib/devbox/services/data`
and survives stop/start; `devbox services start` after a VM restart brings the
containers back.

## Authentication (optional)

Provider sign-in is optional and happens entirely inside the guest; no host
credentials are used or stored.

```sh
devbox auth status                 # github, claude, opencode, databricks
devbox auth login github           # starts `gh auth login` inside the guest
devbox auth login opencode         # starts `opencode auth login` in the guest
devbox auth login claude           # prints the steps to finish Claude login
devbox auth login databricks       # prints the databricks login command
devbox db info                     # PostgreSQL connection settings
```

`claude` and `databricks` cannot be scripted from the companion, so those
commands print the next step instead of starting a login.

Credentials are written inside the guest and survive stop/start; they are
removed only by `devbox destroy`.

## Maintenance

```sh
devbox provision             # force non-destructive provisioning
devbox destroy               # remove the VM and its container runtime data
devbox uninstall             # remove the devbox symlink
```

## Security

- The guest has no host filesystem mounts and does not reuse the host SSH agent.
- The daily identity is the unprivileged `devbox` account (no sudo, no Docker
  group, no Docker socket).
- Service secrets are generated in the guest and never stored on the host.
- Provisioning scripts are streamed over SSH, checksum-verified inside the
  guest, and run from a root-owned read-only copy; direct SSH is only
  authorized after the guest passes its readiness checks.
