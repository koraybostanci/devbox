# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-as-code for a personal dev VM (Colima named profile `devbox`) running Ubuntu 24.04 on Apple Silicon. Clone → fill `.env` → `./devbox start` → fully provisioned dev environment. The VM is disposable; everything that matters lives here.

## Commands

```sh
./devbox init     # validate host prerequisites and initialize mode-0600 .env
./devbox install  # install a user-local CLI symlink without sudo
devbox uninstall  # remove only a symlink owned by this checkout
devbox start      # start the VM and converge changed provisioning inputs
devbox provision  # force non-destructive guest provisioning
devbox connect    # open a guest zsh shell
devbox exec <cmd> # run a command inside the guest and return
devbox status     # show named VM profile state and resources
devbox ide        # verify and print current IDE SSH settings
devbox doctor     # run host and guest readiness diagnostics
devbox stop       # graceful shutdown; --force is explicit
devbox rotate     # update .env-managed guest credentials without restarting
devbox rebuild    # recreate guest OS/tools while preserving volumes and mounts
devbox destroy    # remove VM/runtime data after strong confirmation
devbox github [login|status|logout]
devbox databricks [login|status|logout]
devbox containers [service] [up|down|ps|logs]  # manage containers from the Mac
```

`devbox install` creates a symlink in a writable user-local directory already on `PATH`; it never writes `/usr/local/bin` with `sudo`.

## Architecture

Provisioning runs in three sequential guest stages:

1. **`provision/scripts/system.sh`** (root) - apt packages and system dependencies
2. **`provision/scripts/tools.sh`** (user) - runtimes, applications, configuration, and optional add-ons
3. **`provision/scripts/verify.sh`** (user) - versions, mounts, Docker, isolation, and readiness

The host parses an allowlisted `.env` and streams guest values over stdin into mode-0600 files under `~/.config/devbox`. Secrets never appear in Colima arguments or `/etc/environment`.

`colima.yaml` mounts `provision/` read-only at `/provision`, projects at `/mnt/devbox/projects`, and data at `/mnt/devbox/data`; safe guest-home symlinks expose the latter two as `~/projects` and `~/data`. Template values are rendered into the standard `devbox` Colima profile before start. A content digest of `colima.yaml` and `provision/` controls convergence.

The launcher maintains a marked `Host devbox` block directly in `~/.ssh/config` because JetBrains may not follow `Include` directives. The block is refreshed after every start/rebuild with Colima's dynamic port and dedicated key. Host SSH-agent forwarding is disabled.

## Key files

| File | Purpose |
|---|---|
| `provision/versions.env` | Version pins for all tools |
| `provision/scripts/tools.sh` | User-level provisioning orchestrator |
| `provision/scripts/lib/runtimes.sh` | Installs Node.js, Python, uv, Java, Go, and Rust |
| `provision/scripts/lib/apps.sh` | Installs Claude Code, opencode, Databricks CLI, yq, and oh-my-zsh |
| `provision/scripts/lib/configure.sh` | Sets up mounts, git identity, MCP/opencode JSON, Claude files, and zsh |
| `provision/scripts/lib/addons.sh` | Optional plugin and safe argv-based skill installers |
| `provision/scripts/system.sh` | apt packages (root-level, idempotent) |
| `provision/scripts/verify.sh` | Guest readiness checks |
| `provision/config/containers/postgres/docker-compose.yml` | PostgreSQL service with a named Docker volume |
| `provision/config/mcp.json` | MCP servers for Claude Code (deployed to `~/.mcp.json`) |
| `provision/config/opencode/opencode.json` | MCP servers for opencode |
| `provision/config/claude/CLAUDE.md` | Claude Code user preferences deployed to `~/.claude/CLAUDE.md` |
| `provision/config/claude/settings.json` | Claude Code settings deployed to `~/.claude/settings.json` |
| `provision/config/skills/` | Repository-owned skills copied to `~/.claude/skills/` |
| `provision/config/install-skills.txt` | Skills requiring an install command (sentinel-guarded) |
| `provision/config/install-plugins.txt` | Claude Code plugins to install at provisioning time |

## Idempotency pattern

All provisioning scripts are designed to be re-run safely. Tools check whether they are already installed at the requested version before downloading. Skill commands are tokenized into argv without `eval`, must include installer-level `-y` or `--yes`, and are guarded by a SHA-256 sentinel derived from the full command.

## Adding MCPs

Edit both `provision/config/mcp.json` (Claude Code) and `provision/config/opencode/opencode.json` (opencode), then reprovision. At deploy time, the `npx` command is replaced with the versioned absolute path and the projects argument is set to `$HOME/projects`.

## Adding skills / plugins

**File-based skills**: add `provision/config/skills/<name>/SKILL.md` — deployed to `~/.claude/skills/` (read by both Claude Code and opencode).

**Skills with install commands**: add a line to `provision/config/install-skills.txt`:
```
npx <package> <installer arguments including -y or --yes>
```

Commands are whitespace-separated; quoting and shell syntax are intentionally unsupported. Keep browser-based or approval-requiring installers outside provisioning.

**Claude Code plugins**: add a line to `provision/config/install-plugins.txt`:
```
plugin-name@marketplace
```

## Updating tool versions

Edit `provision/versions.env`, then run `devbox rebuild` to reprovision.

## Changing VM resources

Set `DEVBOX_CPU`, `DEVBOX_MEMORY`, and `DEVBOX_DISK` in `.env`, then rebuild. Defaults: 4 CPUs, 4 GiB RAM, 60 GiB disk. Reduce memory to 2 on 8 GB machines.

## SSH agent

Host SSH agents and private keys are intentionally unavailable in the guest. GitHub access uses guest-local `gh` authentication over HTTPS; run `devbox github login` after rebuilding. The IDE transport uses only Colima's dedicated key and explicit `ForwardAgent no`.
