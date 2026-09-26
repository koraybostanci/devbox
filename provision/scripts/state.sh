#!/bin/bash
# Guest state for devbox. Runs as root from lib/devbox.sh with the host seed
# (GIT_NAME, GIT_EMAIL, POSTGRES_*) on stdin. Guest-writable files are parsed
# as data; this root phase never sources them.
#
#   config  - non-secret defaults; seeded once, then the guest is authoritative.
#   secrets - service secrets; always generated inside the guest, never seeded
#             from the host.
#   services - root-owned definition and credentials for PostgreSQL and Valkey;
#             the containers stay stopped until `devbox services start`.

set -Eeuo pipefail
trap 'printf "ERROR: devbox state setup failed at line %s\n" "$LINENO" >&2' ERR

export DEVBOX_PROVISION_ROOT="${DEVBOX_PROVISION_ROOT:-/var/lib/devbox/provision}"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/state.sh"

config_root=/home/devbox/.config
directory="$config_root/devbox"
services=/var/lib/devbox/services
config="$directory/config"
secrets="$directory/secrets"

[ -d /home/devbox ] && [ ! -L /home/devbox ] || {
    printf 'ERROR: devbox guest home is invalid\n' >&2
    exit 1
}
[ ! -L "$config_root" ] && { [ ! -e "$config_root" ] || [ -d "$config_root" ]; } || {
    printf 'ERROR: devbox XDG configuration root is invalid\n' >&2
    exit 1
}
[ ! -L "$directory" ] && { [ ! -e "$directory" ] || [ -d "$directory" ]; } || {
    printf 'ERROR: devbox configuration directory is invalid\n' >&2
    exit 1
}

# The guest user owns its editable config and secrets. Keep privileged writes
# out of that directory; root reads the resulting values only as validated
# literal data below.
sudo -u devbox -- env HOME=/home/devbox /bin/bash -c '
    set -Eeuo pipefail
    source "$1"
    devbox_seed_guest_state "$2"
' _ "$DEVBOX_PROVISION_ROOT/scripts/lib/state.sh" "$directory" || {
    printf 'ERROR: devbox guest config or secrets could not be safely seeded\n' >&2
    exit 1
}

devbox_state_directory_is_safe "$config_root" devbox devbox 700 &&
    devbox_state_directory_is_safe "$directory" devbox devbox 700 || {
    printf 'ERROR: devbox configuration directory permissions are invalid\n' >&2
    exit 1
}

unset POSTGRES_USER POSTGRES_DB POSTGRES_PORT VALKEY_PORT POSTGRES_PASSWORD VALKEY_PASSWORD
devbox_state_file_is_safe "$config" devbox devbox 600 || {
    printf 'ERROR: guest config must be a regular devbox-owned mode-0600 file\n' >&2
    exit 1
}
devbox_parse_state_file "$config" config
devbox_state_config_is_complete || {
    printf 'ERROR: guest config is missing required PostgreSQL settings\n' >&2
    exit 1
}
VALKEY_PORT="${VALKEY_PORT:-16379}"

devbox_state_file_is_safe "$secrets" devbox devbox 600 || {
    printf 'ERROR: guest secrets must be a regular devbox-owned mode-0600 file\n' >&2
    exit 1
}
devbox_parse_state_file "$secrets" secrets || {
    printf 'ERROR: guest service secrets are invalid\n' >&2
    exit 1
}
[ -n "${POSTGRES_PASSWORD:-}" ] && [ -n "${VALKEY_PASSWORD:-}" ] || {
    printf 'ERROR: guest service secrets are missing\n' >&2
    exit 1
}

compose_source="$DEVBOX_PROVISION_ROOT/config/services/compose.yaml"
[ -d "$DEVBOX_PROVISION_ROOT" ] && [ ! -L "$DEVBOX_PROVISION_ROOT" ] || {
    printf 'ERROR: devbox provisioning input is unavailable\n' >&2
    exit 1
}
[ -f "$compose_source" ] && [ ! -L "$compose_source" ] || {
    printf 'ERROR: devbox service definition is unavailable\n' >&2
    exit 1
}
mkdir -p "$services/data/postgres" "$services/data/valkey"
chmod 700 "$services"

envfile="$services/env"
temporary="$(mktemp "$services/.env.XXXXXX")"
{
    printf 'POSTGRES_USER=%s\n' "$POSTGRES_USER"
    printf 'POSTGRES_DB=%s\n' "$POSTGRES_DB"
    printf 'POSTGRES_PORT=%s\n' "$POSTGRES_PORT"
    printf 'POSTGRES_PASSWORD=%s\n' "$POSTGRES_PASSWORD"
    printf 'VALKEY_PORT=%s\n' "$VALKEY_PORT"
    printf 'VALKEY_PASSWORD=%s\n' "$VALKEY_PASSWORD"
} >"$temporary"
chmod 600 "$temporary"
mv "$temporary" "$envfile"
compose="$services/compose.yaml"
temporary="$(mktemp "$services/.compose.XXXXXX")"
cat "$compose_source" >"$temporary"
chmod 600 "$temporary"
mv "$temporary" "$compose"

[ -f "$envfile" ] && [ -f "$compose" ] &&
    [ "$(stat -c '%a' "$envfile")" = 600 ] &&
    [ "$(stat -c '%a' "$compose")" = 600 ] || {
    printf 'ERROR: devbox service definition could not be staged\n' >&2
    exit 1
}
