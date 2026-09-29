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
pinned versions; `gh`, `jq`, rootless Docker prerequisites, and snapd come from
Ubuntu packages. The guest also has a per-user rootless Docker daemon and native
ARM64 Chromium from Ubuntu's stable snap.

Use `vim <file>` to edit files in the guest terminal; `$EDITOR` and `$VISUAL`
are set to `vim` by default.

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
export DEVBOX_USE_HOST_PROXY="false"
```

The identity and PostgreSQL keys are seeded into the guest on first provision
and maintained in the guest at `~/.config/devbox/config` afterwards.
`POSTGRES_USER` and `POSTGRES_DB` accept 1–63 ASCII letters, digits, dots,
dashes, or underscores; `POSTGRES_PORT` must be in the range 1–65535. The
`DEVBOX_CPU`, `DEVBOX_MEMORY`, and `DEVBOX_DISK` keys size the VM; changing them
requires recreating it. Host proxy variables are cleared from Colima by default.
Set `DEVBOX_USE_HOST_PROXY="true"` only when the guest needs the proxy exported
by the current host process. Proxy changes apply at the next VM start; run
`devbox stop` then `devbox start` to apply them. See
[docs/troubleshooting.md](docs/troubleshooting.md).

Service secrets are generated in the guest and are not placed in the host
`.env` or repository. They persist on the VM disk, which is stored on the host
under Colima storage.

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

Add `Include ~/.ssh/devbox.conf` at the top of `~/.ssh/config` once. The
`devbox start` command updates that managed file with the VM's current SSH
endpoint. Point editors, `git`, and other tools at host `devbox` to work with
guest files over SSH. `devbox destroy` removes the managed file; the Include
line can stay.

## Services

PostgreSQL and Valkey are provisioned inside the guest as root-managed
containers but stay stopped until you start them:

```sh
devbox services start
devbox services status
devbox services stop
```

The `devbox services` helper always runs Compose as root against the rootful
`/var/run/docker.sock`; it does not follow the user's Docker context. These
containers are bound to `127.0.0.1` only. The unprivileged `devbox` user cannot
control this rootful daemon or access its socket; it reaches the services over
loopback using credentials in `~/.config/devbox/secrets`. Data lives below
`/var/lib/devbox/services/data` and survives stop/start; `devbox services start`
after a VM restart brings the containers back.

### Rootless Docker and Chromium

Direct `docker` commands in the guest run against a separate Docker daemon
owned by `devbox`, using `unix:///run/user/<uid>/docker.sock` and the `rootless`
Docker context. Its images and containers are user-owned; this does not replace
or upgrade Colima's rootful Engine, which remains reserved for `devbox services`.

Ubuntu's actual ARM64 Chromium snap is available at `/snap/bin/chromium` and is
the Puppeteer runtime default in the guest. Devbox's managed `.zshenv` block
sets `PUPPETEER_EXECUTABLE_PATH` to that path only when it is unset or empty, so
a non-empty value inherited before zsh starts wins. The managed block runs
before pre-existing `.zshenv` content, so a later user/project setting there
also wins. A project command can override the default for one invocation:

```sh
PUPPETEER_EXECUTABLE_PATH=/path/to/chromium npm test
env -u PUPPETEER_EXECUTABLE_PATH npm ci
env -u PUPPETEER_EXECUTABLE_PATH npm test
```

The first command selects a different executable; the latter two leave
Puppeteer free to use the browser bundled with that project. Keep any
`PUPPETEER_SKIP_DOWNLOAD=true` choice project-local as well (for example, set it
only on that project's `npm ci` command when using a system browser); Devbox
does not set it globally. Existing `.zshenv` content is preserved and remains
after the managed block, so its later settings can override Devbox defaults.

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

- The profile explicitly disables host filesystem mounts and does not reuse the
  host SSH agent. The VM disk (including workspaces, provider credentials, and
  service secrets) resides on the host under Colima storage, normally below
  `~/.colima`; protect that storage and host backups accordingly.
- The guest retains ordinary network access, including reachability to the
  host gateway and any host services listening there, unless separately
  restricted. Disabling mounts is not network isolation.
- The daily identity is the unprivileged `devbox` account (no sudo, no Docker
  group, and no access to the rootful Docker socket). Its separate rootless
  daemon runs as `devbox`. Guest agents run as that same account and can access
  its workspace, credentials, and rootless containers; there is no per-agent
  guest-user sandbox.
- Agent instructions forbid using host mounts, the host gateway, SSH,
  forwarding, or other channels to access the host. This is policy guidance,
  not technical network enforcement; ordinary external network use remains
  allowed.
- Host proxy settings are cleared from Colima invocations by default. The
  explicit `DEVBOX_USE_HOST_PROXY=true` opt-in propagates the host's exported
  proxy variables into the guest and Colima-managed rootful Docker daemon on VM
  start. Proxy URLs (including embedded credentials) persist on the VM disk.
- Provisioning scripts are streamed over SSH, checksum-verified inside the
  guest, and run from a root-owned read-only copy; direct SSH is only
  authorized after the guest passes its readiness checks.
