# AGENTS.md

Guidance for agents working in this repository.

## What this repo is

Infrastructure-as-code for a personal dev VM (Colima profile `devbox`)
running Ubuntu 24.04 on Apple Silicon. Clone → `./devbox init` → edit `.env` →
`./devbox start` → fully provisioned dev environment with no host mounts. The
VM is disposable; everything that matters lives in the guest.

## Commands

```sh
./devbox init              # create/validate mode-0600 .env
./devbox install           # install a user-local CLI symlink
./devbox start             # start and converge the VM
./devbox connect           # open a guest zsh shell
./devbox exec <cmd>        # run a command in the guest
./devbox status            # VM state and resources
./devbox services status   # managed PostgreSQL and Valkey
./devbox provision         # force non-destructive provisioning
./devbox stop [--force]
./devbox destroy
```

## Layout

- `devbox` — the launcher.
- `lib/common.sh` — logging, locking, CLI install helpers.
- `lib/config.sh` — host platform check, `.env` parsing.
- `lib/devbox.sh` — VM lifecycle, provisioning, identity, SSH, services.
- `provision/` — guest provisioning bundle (system/tools/verify scripts and
  `config/services/compose.yaml`).
- `colima.yaml` — the Colima profile template.
- `scripts/check.sh` — static checks (the CI gate).
- `scripts/release.sh` — build/verify/install signed releases.

## Notes

- The guest generates its own secrets; `.env` holds only non-secret defaults.
- The `devbox` guest user is unprivileged (no sudo, no Docker socket).
- Services run as a root-owned Compose project inside the guest, loopback only.
- Work only within this repository.

## Publication

- Never push directly to `main`; every change lands through a branch and a
  pull request.
- Open pull requests as drafts unless the user asks otherwise.
- Do not merge a pull request without explicit approval.
- Confirm before force-pushing, rebasing, hard-resetting, deleting branches,
  or pushing tags.
