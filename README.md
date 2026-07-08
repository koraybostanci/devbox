# devbox

Personal dev environment as code. Clone → fill in secrets → one command → fully configured VM.

Everything (tool versions, configs, MCP registrations, skills) lives in this repo. The VM is disposable — rebuild it from scratch anytime without losing anything that matters.

---

## Prerequisites

One-time setup per host machine (~2 min):

```sh
brew install lima
softwareupdate --install-rosetta   # Apple Silicon; skip if already installed
```

Add the `devbox` alias to your Mac's `~/.zshrc`:

```sh
alias devbox='limactl shell koray-dev zsh'
```

---

## First-time setup

```sh
git clone git@github.com:koraybostanci/devbox.git
cd devbox

cp .env.example .env
# Edit .env — fill in your API keys, git identity, Databricks credentials

source .env && ./start.sh
```

Provisioning takes ~15–20 min on first boot (downloads runtimes). Subsequent starts take ~30 sec.

---

## Daily workflow

```sh
limactl start koray-dev   # start VM
devbox                    # SSH in (opens zsh with all tools on PATH)
limactl stop koray-dev    # shut down
```

No need to `source .env` for a normal start — only required when reprovisioning.

---

## Inside the VM

| Tool | Version |
|---|---|
| Python | 3.12.4 (pyenv) + uv |
| Node.js | 20.19.0 (nvm) |
| Java | 21.0.3-tem (sdkman) |
| Go | 1.22.4 |
| Claude Code | latest |
| opencode | latest |
| Databricks CLI | latest |
| zsh + oh-my-zsh | latest |

Clone your personal repos under `~/projects/` inside the VM.

---

## Reprovisioning

After changing `tools.sh` or any config file under `provision/config/`:

```sh
source .env && limactl stop koray-dev && ./start.sh
```

This re-runs all provisioners. Your code in `~/projects/` and VM disk data are untouched.

---

## Full rebuild

Wipes the VM disk and re-provisions from scratch (~15–20 min):

```sh
limactl delete koray-dev
source .env && ./start.sh
```

No manual steps — everything is declared in this repo.

---

## Adding MCPs or skills

**MCP server**: add it to both `provision/config/mcp.json` (Claude Code) and `provision/config/opencode/opencode.json` (opencode), then reprovision.

**Skill**: add `provision/config/claude/skills/<name>/SKILL.md`. Both Claude Code and opencode read from `~/.claude/skills/`. Reprovision to deploy.

---

## Changing tool versions

Edit the pins at the top of `provision/tools.sh`:

```sh
GO_VERSION="1.22.4"
NODE_VERSION="20.19.0"
PYTHON_VERSION="3.12.4"
JAVA_VERSION="21.0.3-tem"
UV_VERSION="0.4.18"
```

Then reprovision.

---

## IDE access

### VS Code Remote SSH

Add to `~/.ssh/config` on your Mac (one-time):

```
Include ~/.lima/*/ssh.config
```

Lima writes `~/.lima/koray-dev/ssh.config` on every start. In VS Code → Remote Explorer → connect to `lima-koray-dev`.

### JetBrains Gateway

```sh
limactl list --format '{{ .SSHLocalPort }}' koray-dev
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

If the socket is missing: `limactl stop koray-dev && limactl start koray-dev`.

---

## Host isolation

- No personal `.gitconfig` on the host
- No API keys in host shell config (`.env` is gitignored)
- SSH private keys never written to VM disk — agent-forwarded only
- All personal tools install inside the VM only
- VM state lives in `~/.lima/koray-dev/` — isolated from host tools
