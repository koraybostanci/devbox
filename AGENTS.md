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
- `provision/` — guest provisioning bundle: `versions.env` (pinned versions),
  `scripts/` (system/tools/verify plus shared libs),
  `config/services/compose.yaml`, and the
  `config/{zsh,claude,opencode,skills,guest}` trees.
- `colima.yaml` — the Colima profile template.
- `scripts/check.sh` — static checks plus stubbed unit tests, no live VM
  (the CI gate); it sources the two subcheckers `scripts/check-host-config.sh`
  and `scripts/check-guest-state.sh`.

Commands are in [README.md](README.md); host/guest internals are in
[docs/architecture.md](docs/architecture.md).

## Host boundary for agents

Agents must not attempt to use host mounts, the host gateway or host services,
SSH, agent/port forwarding, or any other channel to read, write, or execute
anything on the host. Ordinary external network use is allowed. This is agent
policy guidance, not technical network enforcement.

## CI gate

`bash scripts/check.sh` must end `All checks passed.`; run it before proposing
a change. The gate is static checks plus stubbed unit tests (no live VM).
GitHub Actions is disabled at the repository level, so this is the
only gate; `.github/workflows/check.yml` runs it on Linux when re-enabled.

## Version policy

Bump `VERSION` on any user-visible launcher or companion behavior change;
`devbox version` is the support surface.

## Publication

- Never push directly to `main`; every change lands through a branch and a
  pull request.
- Open pull requests as drafts unless the user asks otherwise.
- Do not merge a pull request without explicit approval.
- Confirm before committing, pushing, creating a pull request, force-pushing,
  rebasing, hard-resetting, or deleting branches.
