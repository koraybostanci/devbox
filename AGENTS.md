# AGENTS.md

Guidance for agents working in this repository.

## What this repo is

Infrastructure-as-code for a personal dev VM (Colima profile `devbox`) running
Ubuntu 24.04 on Apple Silicon. The VM is disposable; everything that matters
lives in the guest.

## Layout

- `devbox` — the launcher.
- `lib/common.sh` — logging, locking, CLI install helpers.
- `lib/config.sh` — host platform check, `.env` parsing.
- `lib/devbox.sh` — VM lifecycle, provisioning, SSH alias, services.
- `provision/` — guest provisioning bundle (system/tools/verify scripts and
  `config/services/compose.yaml`).
- `colima.yaml` — the Colima profile template.
- `scripts/check.sh` — static checks (the CI gate).

Commands are in [README.md](README.md); host/guest internals are in
[docs/architecture.md](docs/architecture.md).

## CI gate

`bash scripts/check.sh` must end `All checks passed.`; CI runs it on macOS for
every push and pull request. Run it before proposing a change.

## Publication

- Never push directly to `main`; every change lands through a branch and a
  pull request.
- Open pull requests as drafts unless the user asks otherwise.
- Do not merge a pull request without explicit approval.
- Confirm before committing, pushing, creating a pull request, force-pushing,
  rebasing, hard-resetting, or deleting branches.
