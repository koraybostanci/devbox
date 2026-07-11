# Troubleshooting

Start with:

```sh
devbox doctor
```

Diagnostics redact secret values and check the host platform, required commands, `.env` mode, isolated VM state, SSH, guest readiness, mounts, tools, Docker, and GitHub authentication.

## Missing Prerequisites

Run the exact Homebrew command printed by `devbox init` or `devbox doctor`. Runtime setup never installs host packages automatically.

If Docker exists but Compose does not:

```sh
brew install docker-compose
```

## Environment Rejected

`.env` must contain only supported uppercase assignments with JSON-compatible double-quoted string values and have mode 0600:

```sh
chmod 600 .env
bash -n .env
```

Set `DATABRICKS_HOST` to a workspace URL, then run `devbox databricks login`. `DATABRICKS_TOKEN` is deprecated and ignored. GitHub tokens are not accepted.

## Legacy Mount Layout

If start reports a legacy layout, recreate the guest once:

```sh
devbox rebuild
```

This preserves Mac-backed projects/data and Docker named volumes. Rebuild does not prompt for authentication; run `devbox github login` and `devbox databricks login` afterward as needed.

## VM State or SSH

Check isolated state without relying on host Colima defaults:

```sh
devbox status
devbox ide
devbox doctor
```

The generated IDE host is `devbox`. Colima assigns its localhost port dynamically. In JetBrains Gateway, create a new SSH configuration, set Host to `devbox`, select **OpenSSH config and authentication agent**, enable **Parse config file `~/.ssh/config`**, and do not override the port or identity. Do not enter a guessed port such as `2222`; run `devbox ide` for verified manual fallback values.

If Gateway still shows `localhost`, an old port, or `agent` authentication after rebuild, delete that saved profile and create it again from `devbox`. Restart Gateway once if needed to reload `~/.ssh/config`. `devbox start` atomically refreshes the marked direct block for IDEs that do not follow SSH `Include` directives.

Effective settings should show agent forwarding disabled:

```sh
ssh -G devbox | grep -i forwardagent
```

If Colima is transitioning, wait for it to settle and retry. Use `devbox stop --force` only when graceful shutdown cannot complete.

## Provisioning Failure

Provisioning errors name the failing stage and preserve the running VM for diagnosis. Correct the cause and rerun:

```sh
devbox provision
```

For DNS failures, configure Colima's supported DNS setting rather than editing guest resolver or netplan files. For disk failures, inspect free space in both macOS and the guest before increasing `DEVBOX_DISK` and rebuilding.

## GitHub

Unauthenticated GitHub is a warning, not a provisioning failure:

```sh
devbox github login
devbox github status
```

Login opens GitHub's device page in the macOS browser. Enter the one-time code shown in the terminal. A plaintext-storage warning is expected in the headless guest because it has no desktop keychain; the mode-0600 credential file remains inside the VM. `devbox github status` validates the credential with an authenticated API request rather than trusting older `gh auth status` exit behavior.

Use HTTPS remotes. Host SSH aliases and keys are intentionally unavailable in the guest.

## Port Conflict

Change `POSTGRES_PORT` in `.env`, then apply it without restarting the VM:

```sh
devbox rotate
devbox containers postgres up
```

PostgreSQL binds to loopback only.

## Mount Collision

Provisioning will not replace an existing `~/projects` or `~/data` file/directory. Move the conflicting path aside yourself, verify its contents, and rerun `devbox provision`.

## Destructive Recovery

`rebuild` preserves Docker volumes and Mac-backed data. `destroy` removes Docker runtime data but still preserves Mac-backed data. Use `pg_dump` before destructive operations when database recovery matters.
