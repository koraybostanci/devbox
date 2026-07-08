# devbox

Personal dev environment as code. Clone → fill in secrets → one command → fully configured VM.

Everything (tool versions, configs, MCP registrations, skills) lives in this repo. The VM is disposable — `limactl factory-reset koray-dev` rebuilds it from scratch.

---

## Prerequisites

One-time setup per host machine (~2 min):

```sh
brew install lima
softwareupdate --install-rosetta   # Apple Silicon; skip if already installed
```

---

## First-time setup

```sh
git clone git@github.com:<your-username>/devbox.git
cd devbox

cp .env.example .env
# Edit .env — fill in your API keys, git identity, Databricks credentials

source .env && ./start.sh
```

Provisioning takes ~15–20 min on first boot (downloads runtimes).  
Subsequent starts (no reprovision needed) take ~30 sec.

---

## Daily workflow

```sh
limactl start koray-dev    # start VM
limactl shell koray-dev    # SSH into VM (opens zsh)
limactl stop koray-dev     # shut down
```

No need to `source .env` on a normal start — only required when reprovisioning.

---

## Inside the VM

Tools available immediately after first provision:

| Tool | Version |
|---|---|
| Node.js | 20.19.0 (via nvm) |
| Python | 3.12.4 (via pyenv) + uv |
| Java | 21.0.3-tem (via sdkman) |
| Go | 1.22.4 |
| Claude Code | latest |
| opencode | latest |
| Databricks CLI | latest |
| zsh + oh-my-zsh | latest |

Clone your personal repos under `~/projects/` inside the VM.

---

## IDE access

### VS Code Remote SSH

Add to `~/.ssh/config` on your Mac (one-time):
```
Include ~/.lima/*/ssh.config
```

Lima writes `~/.lima/koray-dev/ssh.config` automatically on every start. In VS Code, Remote Explorer → connect to `lima-koray-dev`.

### JetBrains Gateway

Get the SSH port:
```sh
limactl list --format '{{ .SSHLocalPort }}' koray-dev
```

Gateway → New Connection → SSH → `127.0.0.1:<port>`, username = your macOS username.  
Select the IDE version and project path on the VM — the backend installs there.

---

## SSH agent

Private keys stay on your Mac — never copied to the VM. Git operations inside the VM use your host SSH agent automatically.

If `git clone git@github.com:...` fails inside the VM:
```sh
# Check agent is forwarded
echo $SSH_AUTH_SOCK   # should be /run/host-services/ssh-auth.sock
ssh-add -l            # should list your keys
```

If the socket is missing, restart the VM: `limactl stop koray-dev && limactl start koray-dev`.

---

## Reprovisioning

To re-run all provisioners (after changing `tools.sh` or config files):

```sh
source .env && limactl stop koray-dev && ./start.sh
```

---

## Adding MCPs or skills

**MCP server**: add it to both `provision/config/mcp.json` (Claude Code) and `provision/config/opencode/opencode.json` (opencode), then reprovision.

**Skill**: add a file at `provision/config/claude/skills/<name>/SKILL.md`. Both Claude Code and opencode discover skills from `~/.claude/skills/`. Reprovision to deploy.

---

## Changing tool versions

Edit the version pins at the top of `provision/tools.sh`:

```sh
GO_VERSION="1.22.4"
NODE_VERSION="20.19.0"
PYTHON_VERSION="3.12.4"
JAVA_VERSION="21.0.3-tem"
UV_VERSION="0.4.18"
```

Then reprovision.

---

## Full rebuild

Wipes the VM and re-provisions from scratch:

```sh
source .env && limactl factory-reset koray-dev
```

No manual steps — everything is declared in this repo.

---

## Host isolation guarantee

- No personal `.gitconfig` on the host
- No personal API keys in host shell config files (`.env` is gitignored)
- SSH private keys never written to VM disk — agent-forwarded only
- All personal tools install inside the VM only
- VM state lives in `~/.lima/koray-dev/` — separate from everything else on the host
