# Release Checklist

Run this checklist on the oldest supported macOS and current macOS, both on Apple Silicon.

## Static Gate

- Run `scripts/check.sh`.
- Confirm Bash, YAML, JSON, Compose, manifest, and prohibited-pattern checks pass.
- Confirm CI passes on the proposed revision.

## Host Baseline

Record before setup:

```sh
git config --global --list
docker context show
ssh-add -l
ssh -G github.com
```

## Fresh Setup

- Clone into a normal path and a path containing spaces.
- Run `devbox init`; verify it creates only `.env` and dedicated local directories.
- Verify `.env` mode enforcement and malformed/unknown-key rejection.
- Run `devbox install`; verify a user-local symlink and no sudo prompt.
- Run first `devbox start`; verify exact guest versions and readiness.
- Run second `devbox start`; verify provisioning is skipped.
- Confirm `colima list` shows the `devbox` profile with the Docker runtime.
- Confirm a second checkout cannot operate on the owned profile.
- Confirm host Docker context is unchanged.
- Confirm host SSH changes are limited to the documented managed block and backup.
- Confirm `~/.ssh/config` contains the current dynamic port and dedicated Colima identity directly, without requiring an `Include` directive.

## Isolation

- Confirm the named `devbox` profile remains independent from the default Colima profile.
- Confirm `SSH_AUTH_SOCK` is absent in the guest.
- Confirm personal/work host SSH aliases and private keys are unavailable in the guest.
- Run `devbox github login`; confirm the device page opens in the macOS browser and select the intended account.
- Confirm an invalid or expired GitHub credential makes `devbox github status` return nonzero while `devbox doctor` reports only a warning.
- Verify `gh repo clone`, Git fetch, and Git push use HTTPS.
- Run `devbox ide` and confirm its direct fallback connects with the host agent disabled.
- Connect from VS Code Remote SSH using host `devbox`.
- In JetBrains Gateway, create a fresh OpenSSH-config connection for host `devbox` without overriding its port or identity, and connect to `~/projects`.
- After a rebuild changes the port, confirm a newly opened Gateway connection resolves the refreshed direct `Host devbox` block rather than a stale saved port.

## Persistence

- Write marker files under `~/projects` and `~/data`.
- Start PostgreSQL and write a marker row.
- Run `devbox rebuild`.
- Confirm no skill installer or authentication prompt appears after the rebuild confirmation.
- Confirm project/data markers and the PostgreSQL row survive.
- Confirm guest GitHub and Databricks logins must be repeated explicitly.
- Run `devbox destroy`.
- Confirm Docker runtime data is removed and Mac-backed marker files remain.

## Operations

- Rotate `.env` credentials and run `devbox rotate`; confirm VM start time and GitHub account do not change.
- Edit a provisioning input; confirm one `start` converges and the next skips.
- Force `devbox provision` and confirm no user data is removed.
- Verify graceful stop and explicit forced stop.
- Start concurrent mutating commands and confirm one is rejected.
- Interrupt a download/provision and confirm a later run recovers cleanly.

## Failure Evidence

Induce and verify actionable diagnostics for:

- Missing host dependency
- Malformed or insecure `.env`
- DNS failure
- Occupied PostgreSQL port
- Unwritable mount
- Low disk space
- Corrupt generated YAML/JSON
- Unauthenticated GitHub CLI
- Legacy mount layout
- Legacy private Colima home
- Moved checkout ownership mismatch
- Stale lifecycle lock
