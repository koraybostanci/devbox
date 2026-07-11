# Troubleshooting

Start with:

```sh
devbox doctor
```

Diagnostics redact secret values and check the host platform, required commands, `.env` mode, the named VM profile, SSH, guest readiness, mounts, tools, Docker, and GitHub authentication.

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

## Legacy Private Colima Home

Devbox now uses the normal `devbox` Colima profile. If an earlier version created `${XDG_DATA_HOME:-$HOME/.local/share}/devbox/colima/devbox`, commands stop before touching either profile. Back up required data before removing that legacy VM. `COLIMA_HOME` is accepted only when it points to this exact legacy home; unset any other override.

For the bundled PostgreSQL service:

```sh
legacy_home="${XDG_DATA_HOME:-$HOME/.local/share}/devbox/colima"
backup="$HOME/devbox-postgres.dump"

COLIMA_HOME="$legacy_home" devbox start
COLIMA_HOME="$legacy_home" devbox containers postgres up
COLIMA_HOME="$legacy_home" devbox exec \
	docker exec devbox-postgres-1 sh -c \
	'pg_dump -Fc -U "$POSTGRES_USER" "$POSTGRES_DB"' >"$backup"
COLIMA_HOME="$legacy_home" devbox containers postgres down
COLIMA_HOME="$legacy_home" devbox stop
```

After verifying the dump is nonempty, remove the legacy VM and create the standard profile:

```sh
COLIMA_HOME="$legacy_home" colima delete --data --force devbox
devbox start
devbox containers postgres up
devbox exec docker exec -i devbox-postgres-1 sh -c \
	'pg_restore --clean --if-exists --no-owner -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
	<"$backup"
```

Run `colima list` before migration. If a standard-home `devbox` profile already exists, inspect and back it up independently. The profile name is reserved for this repository; deliberately remove the conflicting profile only after deciding which data to retain, then create the replacement with `devbox start`.

## Checkout Moved or Renamed

Profile ownership and the `/provision` mount are bound to the checkout's absolute path. Stop the VM before moving or renaming the repository:

```sh
devbox stop
```

After the move, verify that the path reported by the ownership error was this checkout's former location and no longer exists. From the new repository root, deliberately transfer ownership and rebuild the guest:

```sh
owner="$HOME/.colima/devbox/.devbox-owner"
temporary="$(mktemp "$HOME/.colima/devbox/.devbox-owner.XXXXXX")"
checkout="$(pwd -P)"
printf 'devbox-profile-v1\n%s\n' "$checkout" >"$temporary"
chmod 600 "$temporary"
mv "$temporary" "$owner"
devbox rebuild
```

`rebuild` refreshes the host mount path while preserving named Docker volumes and Mac-backed projects/data. Do not rewrite the marker to claim a profile created by another checkout.

## VM State or SSH

Check the named profile through the wrapper:

```sh
devbox status
devbox ide
devbox doctor
colima list
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
