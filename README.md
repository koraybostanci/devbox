# devbox

Personal dev environment as code. Clone → fill in secrets → one command → fully configured VM.

Everything (tool versions, configs, MCP registrations, skills, plugins) lives in this repo. The VM is disposable — rebuild it from scratch anytime without losing anything that matters.

---

## Prerequisites

One-time setup per host machine (~2 min):

```sh
brew install colima
```

If you already have Colima running for Docker/containers, `devbox` runs as a separate named profile (`colima-devbox`) — completely isolated from your default Colima instance.

---

## First-time setup

```sh
git clone git@github.com:<your-github-username>/devbox.git
cd devbox

cp .env.example .env
# Edit .env — fill in your API keys and git identity
# Databricks vars are optional — leave blank if not used

./devbox start   # installs `devbox` to /usr/local/bin on first run
```

Provisioning takes ~15–20 min on first boot (downloads runtimes). Subsequent starts take ~30 sec.

---

## Daily workflow

```sh
devbox start          # start VM (sources .env automatically)
devbox connect        # SSH in (opens zsh with all tools on PATH)
devbox exec <cmd>     # run a command inside the VM and return
devbox stop           # shut down
```

---

## Inside the VM

| Tool | Version |
|---|---|
| Python | 3.12.4 (pyenv) + uv 0.7.13 |
| Node.js | 24.15.0 (nvm) |
| Java | 21.0.3-tem (sdkman) |
| Go | 1.24.4 |
| Rust | stable (rustup) |
| Claude Code | latest |
| opencode | latest |
| Databricks CLI | 1.6.0 |
| zsh + oh-my-zsh | latest |

**Shell extras**: fzf, bat, delta, gh, yq, zsh-autosuggestions, zsh-syntax-highlighting

Your `~/projects/` and `~/data/` directories inside the VM are mounts of `../projects/` and `../data/` on the Mac (siblings of this repo). Both persist across `devbox rebuild` and are accessible from Finder, git, and backup tools on the Mac.

---

## Reprovisioning

Colima provision scripts run on every VM start, but are idempotent. After changing any file under `provision/`, a full rebuild applies changes cleanly:

```sh
devbox rebuild
```

This wipes the VM disk and re-provisions from scratch (~15–20 min). `~/projects/` and `~/data/` are Mac-side mounts and are **not** deleted by rebuild.

**Rotating credentials**: Lima re-injects `--env` vars into `/etc/environment` on every VM start. To update an API key or token, edit `.env` then:

```sh
devbox rotate
```

---

## Containers

The VM runs Docker (managed by Colima). Use `docker` and `docker compose` inside the VM as normal.

A Postgres compose file is included. Manage containers from the Mac:

```sh
devbox containers up             # start all containers
devbox containers postgres up    # start only postgres
devbox containers down           # stop all containers
devbox containers ps             # list all containers (including stopped)
devbox containers logs           # follow logs for all containers

# Connect from the Mac
psql -h localhost -p 15432 -U dev   # password: devpass
```

Postgres data is stored in `~/data/postgres/` (Mac-side: `../data/postgres/`).

**Data lifecycle:**
- `down` + `up` — safe restart, data survives (bind mount, not a named volume)
- `devbox stop` + `devbox start` — containers restart automatically (`restart: unless-stopped`), data survives
- `devbox rebuild` / `devbox delete` — VM disk wiped, `../data/` on Mac is untouched, data survives
- Data is only lost if you manually delete `../data/` on the Mac

To add more services (Valkey, nginx, etc.), create `provision/config/containers/<name>/docker-compose.yml`. Bind the host port at +10000 offset (e.g., `"127.0.0.1:16379:6379"` for Valkey) — Colima auto-forwards the port to the same number on the Mac. The `devbox containers` command picks up new services automatically.

---

## Adding MCPs

Add the server to both config files, then reprovision:

- `provision/config/mcp.json` — Claude Code
- `provision/config/opencode/opencode.json` — opencode

---

## Adding skills

**File-based skills** (a markdown file is all that's needed): add `provision/config/skills/<name>/SKILL.md`. Both Claude Code and opencode read from `~/.claude/skills/`. Reprovision to deploy.

**Skills with an install command**: add a line to `provision/config/install-skills.txt`:

```
skill-name|<install command>
```

The install command runs once per VM lifetime (idempotent via a sentinel file).

---

## Adding Claude Code plugins

Add a line to `provision/config/install-plugins.txt`:

```
plugin-name@marketplace
```

---

## Updating Claude Code and opencode

```sh
npm update -g @anthropic-ai/claude-code   # Claude Code
curl -fsSL https://opencode.ai/install | bash   # opencode
```

After updating, pin the new versions in `provision/versions.env` and commit so rebuilds stay consistent.

---

## Changing tool versions

Edit `provision/versions.env`:

```sh
GO_VERSION="1.24.4"
NODE_VERSION="24.15.0"
PYTHON_VERSION="3.12.4"
JAVA_VERSION="21.0.3-tem"
UV_VERSION="0.7.13"
DATABRICKS_VERSION="1.6.0"
YQ_VERSION="v4.44.3"
```

Then reprovision.

---

## IDE access

### VS Code Remote SSH

`devbox start` configures `~/.ssh/config` with a `Host colima-devbox` entry (written by Colima). In VS Code → Remote Explorer → connect to `colima-devbox`.

### JetBrains Gateway

Gateway → New Connection → SSH → host `colima-devbox`, username = your macOS username. No port or private key entry needed — Colima writes the SSH config automatically on `devbox start`. Select the IDE version and project path on the VM.

---

## SSH agent

Private keys stay on your Mac — never copied to the VM. Git operations inside the VM use your host SSH agent automatically.

If `git clone git@github.com:...` fails inside the VM:

```sh
echo $SSH_AUTH_SOCK   # should be /run/host-services/ssh-auth.sock
ssh-add -l            # should list your keys
```

If the socket is missing: `devbox stop && devbox start`.

---

## Host isolation

- No personal `.gitconfig` on the host
- No API keys in host shell config (`.env` is gitignored; secrets passed at start time only)
- SSH private keys never written to VM disk — agent-forwarded only
- All personal tools install inside the VM only
- VM state lives in `~/.colima/devbox/` — isolated from host tools and from the default Colima instance
