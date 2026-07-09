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
git clone git@github-personal:<your-github-username>/devbox.git
cd devbox

cp .env.example .env
# Edit .env — fill in your API keys and git identity
# Databricks vars are optional — leave blank if not used

source .env && ./start.sh
```

Provisioning takes ~15–20 min on first boot (downloads runtimes). Subsequent starts take ~30 sec.

---

## Daily workflow

```sh
limactl start devbox   # start VM
./connect.sh           # SSH in (opens zsh with all tools on PATH)
limactl stop devbox    # shut down
```

No need to `source .env` for a normal start — only required when reprovisioning.

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

Clone your personal repos under `~/projects/` inside the VM.

---

## Reprovisioning

After changing `tools.sh` or any config file under `provision/config/`:

```sh
source .env && limactl stop devbox && ./start.sh
```

This re-runs all provisioners. Your code in `~/projects/` and VM disk data are untouched.

**Rotating credentials**: secrets are written to `/etc/environment` only once (guarded by a sentinel). To update an API key or token without a full rebuild:

```sh
limactl shell devbox -- sudo rm /etc/devbox-env-written
source .env && limactl stop devbox && ./start.sh
```

---

## Full rebuild

Wipes the VM disk and re-provisions from scratch (~15–20 min):

```sh
limactl delete devbox
source .env && ./start.sh
```

No manual steps — everything is declared in this repo.

---

## Adding MCPs

Add the server to both config files, then reprovision:

- `provision/config/mcp.json` — Claude Code
- `provision/config/opencode/opencode.json` — opencode

---

## Adding skills

**File-based skills** (a markdown file is all that's needed): add `provision/config/claude/skills/<name>/SKILL.md`. Both Claude Code and opencode read from `~/.claude/skills/`. Reprovision to deploy.

**Skills with an install command**: add an entry to `SKILL_INSTALLS` at the top of `provision/tools.sh`:

```sh
SKILL_INSTALLS=(
    "skill-name|<install command>"
)
```

The install command runs once per VM lifetime (idempotent via a sentinel file).

---

## Adding Claude Code plugins

Add plugin names to `CLAUDE_PLUGINS` at the top of `provision/tools.sh`:

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

After updating, pin the new versions in `tools.sh` and commit so rebuilds stay consistent.

---

## Changing tool versions

Edit the pins at the top of `provision/tools.sh`:

```sh
GO_VERSION="1.24.4"
NODE_VERSION="24.3.0"
PYTHON_VERSION="3.12.4"
JAVA_VERSION="21.0.3-tem"
UV_VERSION="0.7.13"
```

Then reprovision.

---

## IDE access

### VS Code Remote SSH

Add to `~/.ssh/config` on your Mac (one-time):

```
Include ~/.lima/*/ssh.config
```

Lima writes `~/.lima/devbox/ssh.config` on every start. In VS Code → Remote Explorer → connect to `lima-devbox`.

### JetBrains Gateway

```sh
limactl list --format '{{ .SSHLocalPort }}' devbox
```

Gateway → New Connection → SSH → `127.0.0.1:<port>`, username = your macOS username. Select IDE version and project path on the VM.

---

## SSH agent

Private keys stay on your Mac — never copied to the VM. Git operations inside the VM use your host SSH agent automatically.

If `git clone git@github.com:...` fails inside the VM:

```sh
echo $SSH_AUTH_SOCK   # should be /run/host-services/ssh-auth.sock
ssh-add -l            # should list your keys
```

If the socket is missing: `limactl stop devbox && limactl start devbox`.

---

## Host isolation

- No personal `.gitconfig` on the host
- No API keys in host shell config (`.env` is gitignored)
- SSH private keys never written to VM disk — agent-forwarded only
- All personal tools install inside the VM only
- VM state lives in `~/.lima/devbox/` — isolated from host tools
