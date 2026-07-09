# devbox

Personal dev environment as code. Clone → fill in secrets → one command → fully configured VM.

Everything (tool versions, configs, MCP registrations, skills, plugins) lives in this repo. The VM is disposable — rebuild it from scratch anytime without losing anything that matters.

---

## Prerequisites

One-time setup per host machine (~2 min):

```sh
brew install lima
```

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
devbox start     # start VM (sources .env automatically)
devbox connect   # SSH in (opens zsh with all tools on PATH)
devbox stop      # shut down
```

---

## Inside the VM

| Tool | Version |
|---|---|
| Python | 3.12.4 (pyenv) + uv |
| Node.js | 24.3.0 (nvm) |
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

Lima provisioners only run at VM creation time. After changing any file under `provision/`, you need a full rebuild to apply changes:

```sh
devbox rebuild
```

This wipes the VM disk and re-provisions from scratch (~15–20 min). `~/projects/` and `~/data/` are Mac-side mounts and are **not** deleted by rebuild.

**Rotating credentials**: secrets are written to `/etc/environment` only once (guarded by a sentinel). To update an API key or token, edit `.env` then:

```sh
devbox rotate
```

---

## Containers

The VM runs rootless containerd with nerdctl. `docker` and `docker-compose` are aliased to `nerdctl` and `nerdctl compose`.

A Postgres compose file is included. Manage containers from the Mac:

```sh
devbox containers up             # start all containers
devbox containers postgres up    # start only postgres
devbox containers down           # stop all containers
devbox containers ps             # list running containers
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

To add more services (Valkey, nginx, etc.), create `provision/config/containers/<name>/docker-compose.yml` and add the port forward to `lima.yaml` using the +10000 offset pattern (e.g., guest 6379 → host 16379). The `devbox containers` command picks up new services automatically. Ports below 1024 cannot be bound by rootless containers — use 8080 for nginx, not 80.

---

## Adding MCPs

Add the server to both config files, then reprovision:

- `provision/config/mcp.json` — Claude Code
- `provision/config/opencode/opencode.json` — opencode

---

## Adding skills

**File-based skills** (a markdown file is all that's needed): add `provision/config/claude/skills/<name>/SKILL.md`. Both Claude Code and opencode read from `~/.claude/skills/`. Reprovision to deploy.

**Skills with an install command**: add an entry to `SKILL_INSTALLS` at the top of `provision/scripts/tools.sh`:

```sh
SKILL_INSTALLS=(
    "skill-name|<install command>"
)
```

The install command runs once per VM lifetime (idempotent via a sentinel file).

---

## Adding Claude Code plugins

Add plugin names to `CLAUDE_PLUGINS` at the top of `provision/scripts/tools.sh`:

```sh
CLAUDE_PLUGINS=(
    "plugin-name@marketplace"
)
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
NODE_VERSION="24.3.0"
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

`devbox start` automatically writes a `Host devbox` entry to `~/.ssh/config` with the current port. In VS Code → Remote Explorer → connect to `devbox`.

### JetBrains Gateway

`devbox start` automatically configures `~/.ssh/config` with the Lima include and a `devbox` host alias. No manual setup needed.

Gateway → New Connection → SSH → host `devbox`, username = your macOS username, no port or private key needed. Select IDE version and project path on the VM.

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
- No API keys in host shell config (`.env` is gitignored)
- SSH private keys never written to VM disk — agent-forwarded only
- All personal tools install inside the VM only
- VM state lives in `~/.lima/devbox/` — isolated from host tools
