# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-as-code for a personal dev VM (Colima named profile `devbox`) running Ubuntu 24.04 on Apple Silicon. Clone → fill `.env` → `./devbox start` → fully provisioned dev environment. The VM is disposable; everything that matters lives here.

## Commands

```sh
./devbox start    # start VM (auto-sources .env if env vars missing)
devbox connect    # SSH into VM (zsh with all tools on PATH)
devbox exec <cmd> # run a command inside the VM and return
devbox stop       # graceful shutdown
devbox status     # show VM state and resource usage
devbox rotate     # update secrets in /etc/environment without full rebuild
devbox rebuild    # wipe disk and reprovision (~15–20 min)
devbox delete     # delete VM disk (projects/data on Mac are NOT lost — prompts for confirmation)
devbox containers [service] [up|down|ps|logs]  # manage containers from the Mac
```

`./devbox` self-installs a symlink to `/usr/local/bin/devbox` on first run. After that, `devbox` works from anywhere.

## Architecture

Provisioning runs in two sequential stages defined in `colima.yaml`:

1. **`scripts/system.sh`** (root) — apt packages, system-level deps
2. **`scripts/tools.sh`** (user) — all user-level installs: nvm/Node, pyenv/Python, sdkman/Java, Go, Rust, uv, Claude Code, opencode, Databricks CLI, zsh plugins, MCP config, skills

Secrets (API keys, git identity) are passed as `--env` flags at `colima start` time. Lima injects them into `/etc/environment` (under a `#LIMA-START...#LIMA-END` block) on every start — no sentinel needed.

`colima.yaml` mounts `provision/` read-only at `/provision`, `../projects/` writably at `~/projects/`, and `../data/` writably at `~/data/` (all Mac-side siblings of this repo). `{{DEVBOX_DIR}}`, `{{PROJECTS_DIR}}`, and `{{DATA_DIR}}` in `colima.yaml` are substituted at runtime by `devbox start` via `write_colima_config()` before writing to `~/.colima/devbox/colima.yaml`. Secrets are passed as `--env` flags at `colima start` time and are never stored in the repo or config files.

## Key files

| File | Purpose |
|---|---|
| `provision/versions.env` | Version pins for all tools |
| `provision/scripts/tools.sh` | `CLAUDE_PLUGINS` and `SKILL_INSTALLS` arrays; user-level install logic |
| `provision/scripts/system.sh` | apt packages (root-level, idempotent) |
| `provision/config/containers/postgres/docker-compose.yml` | Postgres service; data stored in `~/data/postgres/` (Mac: `../data/postgres/`) |
| `provision/config/mcp.json` | MCP servers for Claude Code (deployed to `~/.mcp.json`) |
| `provision/config/opencode/opencode.json` | MCP servers for opencode |
| `provision/config/claude/CLAUDE.md` | Claude Code user preferences deployed to `~/.claude/CLAUDE.md` |
| `provision/config/claude/settings.json` | Claude Code settings deployed to `~/.claude/settings.json` |
| `provision/config/skills/` | File-based skills deployed to `~/.claude/skills/` (Claude Code + opencode) |
| `provision/config/install-skills.txt` | Skills requiring an install command (sentinel-guarded) |
| `provision/config/install-plugins.txt` | Claude Code plugins to install at provisioning time |

## Idempotency pattern

All provisioning scripts are designed to be re-run safely. Tools check whether they're already installed at the correct version before downloading. Skills install commands are guarded by sentinel files in `~/.claude/skills/.installed-<name>`.

## Adding MCPs

Edit both `provision/config/mcp.json` (Claude Code) and `provision/config/opencode/opencode.json` (opencode), then reprovision. `$USER` and `"npx"` in these files are substituted at deploy time.

## Adding skills / plugins

**File-based skills**: add `provision/config/skills/<name>/SKILL.md` — deployed to `~/.claude/skills/` (read by both Claude Code and opencode).

**Skills with install commands**: add a line to `provision/config/install-skills.txt`:
```
sentinel-name|<install command>
```

**Claude Code plugins**: add a line to `provision/config/install-plugins.txt`:
```
plugin-name@marketplace
```

## Updating tool versions

Edit `provision/versions.env`, then run `devbox rebuild` to reprovision.

## Changing VM resources

Edit `cpu`, `memory`, and `disk` in `colima.yaml`. Defaults: 4 CPUs, 4 GiB RAM, 60 GiB disk. Reduce memory to 2 on 8 GB machines.

## SSH agent

Private keys stay on the Mac — agent-forwarded via `/run/host-services/ssh-auth.sock`. If `git clone` fails inside the VM, check `echo $SSH_AUTH_SOCK` and `ssh-add -l`, then `devbox stop && devbox start` if the socket is missing.
