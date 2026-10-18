# devbox

A disposable, isolated Ubuntu development VM on macOS, powered by Colima.

Your editors and SSH clients run on macOS; the project files, shells,
compilers, CLIs, and project processes all live inside the VM, and the managed
PostgreSQL and Valkey containers run there under root. There are no host
filesystem mounts into the guest. The VM's virtual disk is still stored on the
host under Colima storage, so destroying the VM deletes that guest data from
the Mac as well as from the guest.

Design and internals are in [docs/architecture.md](docs/architecture.md).

## Requirements

- macOS 13+ on Apple Silicon
- [Colima](https://colima.run) 0.10.3 or newer
- The OpenSSH client (built in)

Nothing else: no Homebrew, `jq`, `yq`, Docker, or Docker Compose on the host.

## Quick start

Before the first `devbox connect`, add `Include ~/.ssh/devbox.conf` at the top
of `~/.ssh/config`; see [Remote access](#remote-access).

```sh
./devbox init          # answer the prompts; installs the devbox command
# If init prints a PATH instruction, follow it or keep using ./devbox.
devbox start           # create and provision the VM
devbox connect         # open a zsh shell in the guest
devbox stop
```

`devbox init` installs a `devbox` symlink into `~/.local/bin`. If that
directory is not on your `PATH`, add `export PATH="$HOME/.local/bin:$PATH"`
to your shell configuration and open a new shell. Until then, use `./devbox`
from the checkout. `devbox uninstall` removes the symlink.

### What's provisioned

Node.js and npm (via nvm), Python and pyenv, uv, Go, Rust, Java 21, Claude
Code, OpenCode, the Databricks CLI, `yq`, `gh`, `jq`, Vim, and zsh with oh-my-zsh.
[`provision/versions.env`](provision/versions.env) is the source of truth for
pinned versions. `gh`, `jq`, and snapd come from Ubuntu packages; the rootless
Docker prerequisites (`docker-ce-rootless-extras`) come from Colima's Docker
APT source, not from Ubuntu's. The guest also has a per-user rootless Docker
daemon and native ARM64 Chromium from Ubuntu's stable snap.

Use `vim <file>` to edit files in the guest terminal; `$EDITOR` and `$VISUAL`
are set to `vim` by default.

### Configuration

`devbox init` asks for the settings and writes `.env` (mode 0600, gitignored);
rerun `devbox init` to change them. To keep the configuration somewhere other
than the checkout's `.env` — for example a dotfiles symlink — run any devbox
command with `DEVBOX_ENV_FILE=/path/to/env` in the environment (that is a
process variable, not a key inside `.env`). Prompts default to the current
value, the host Git identity, or the built-in value in brackets. A written
file looks like:

```sh
export GIT_NAME="Your Name"
export GIT_EMAIL="you@personal.com"
export POSTGRES_USER="dev"
export POSTGRES_DB="dev"
export POSTGRES_PORT="15432"
export DEVBOX_CPU="4"
export DEVBOX_MEMORY="4"
export DEVBOX_DISK="60"
export DEVBOX_USE_HOST_PROXY="false"
```

The identity and PostgreSQL keys are seeded into the guest on first provision
and maintained in the guest at `~/.config/devbox/config` afterwards. The key
set and the value rules (supported names, quote handling, PostgreSQL user/db
and port limits) are pinned in
[docs/troubleshooting.md](docs/troubleshooting.md).
The `DEVBOX_CPU`, `DEVBOX_MEMORY`, and `DEVBOX_DISK` keys size the VM; changing
them requires recreating it. Host proxy variables are cleared from Colima by
default. Set `DEVBOX_USE_HOST_PROXY="true"` only when the guest needs the proxy
exported by the current host process; with it set, the proxy URLs — including
any embedded credentials — persist on the VM disk. Proxy changes apply at the
next VM start; run `devbox stop` then `devbox start` to apply them. See
[docs/troubleshooting.md](docs/troubleshooting.md) and
[docs/architecture.md](docs/architecture.md#host--guest-boundary) for the
mechanism.

Service secrets are generated in the guest and are not placed in the host
`.env` or repository. They persist on the VM disk, which is stored on the host
under Colima storage.

## Daily workflow

```sh
devbox start                 # start and converge the VM
devbox connect               # shell in the guest
devbox exec <command>        # run one command in the guest
devbox status                # VM state and resources
devbox version               # the devbox version
devbox help                  # command list and usage
devbox stop [--force]
```

Your code lives on the guest disk at `/home/devbox/workspace`; it survives
stop/start and is removed only by `devbox destroy`.

### Remote access

Add `Include ~/.ssh/devbox.conf` at the top of `~/.ssh/config` once. `devbox
start` and `devbox provision` update that managed file with the VM's current
SSH endpoint and re-authorize the host key for the guest account. Point
editors, `git`, and other tools at host `devbox` to work with guest files over
SSH. `devbox destroy` removes the managed file; the Include line can stay.

## Services

PostgreSQL and Valkey are staged root-managed in the guest but stay stopped
until you start them:

```sh
devbox services start
devbox services status
devbox services stop
```

The service contract — the rootful Docker socket, loopback-only bindings,
credential locations, and data paths — is in
[docs/architecture.md](docs/architecture.md#services).

### Rootless Docker and Chromium

Direct `docker` commands in the guest run against a separate Docker daemon
owned by `devbox` at `unix:///run/user/<uid>/docker.sock` (`rootless` Docker
context); this does not replace or upgrade Colima's rootful Engine, which
remains reserved for `devbox services`. The full rootless Docker and Puppeteer
policy is in
[docs/architecture.md](docs/architecture.md#rootless-docker-and-chromium).

## Authentication (optional)

Provider sign-in is optional and happens inside the guest; host provider CLI
credentials are not imported.

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

There are no host filesystem mounts and the host SSH agent is not forwarded;
agent host-boundary instructions are policy, not network enforcement. See
[docs/architecture.md](docs/architecture.md#host--guest-boundary) for the full
boundary, including that the VM disk (workspace, credentials, service secrets)
lives on the host under Colima storage and that the guest keeps ordinary
network access, including to the host gateway.

Direct SSH is keyed, not staged: every `devbox start` and `devbox provision`
wholesale-replaces the guest's `/home/devbox/.ssh/authorized_keys` with the
host key, removing user-added guest keys by design, and that replacement stays
fail-closed — a failed provisioning run removes the managed alias rather than
leaving partial access. Provisioning is checksum-verified inside the guest.
