#!/bin/bash
# Guest state for devbox. Runs as root from lib/devbox.sh with the host seed
# (GIT_NAME, GIT_EMAIL, POSTGRES_*) on stdin.
#
#   config   - non-secret defaults; seeded once, then the guest is authoritative.
#   secrets  - service secrets; always generated inside the guest, never seeded
#              from the host.
#   services - root-owned definition and credentials for PostgreSQL and Valkey;
#              the containers stay stopped until `devbox services start`.
#
# The guest user owns config and secrets, so it seeds them itself; root only
# reads them back through that user, as validated literal data.

set -Eeuo pipefail
trap 'printf "ERROR: devbox state setup failed at line %s\n" "$LINENO" >&2' ERR
cd /

export DEVBOX_PROVISION_ROOT="${DEVBOX_PROVISION_ROOT:-/var/lib/devbox/provision}"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/state.sh"

directory=/home/devbox/.config/devbox
services=/var/lib/devbox/services

sudo -u devbox -- env HOME=/home/devbox /bin/bash -c '
    set -Eeuo pipefail
    source "$1"
    devbox_seed_guest_state "$2"
' _ "$DEVBOX_PROVISION_ROOT/scripts/lib/state.sh" "$directory" || {
    printf 'ERROR: devbox guest config or secrets could not be safely seeded\n' >&2
    exit 1
}

read_guest_state() {
    local content

    content="$(sudo -u devbox cat "$directory/$1")" || return 1
    devbox_parse_state_file "$directory/$1" "$1" <<<"$content"
}

unset POSTGRES_USER POSTGRES_DB POSTGRES_PORT VALKEY_PORT POSTGRES_PASSWORD VALKEY_PASSWORD
read_guest_state config && devbox_state_config_is_complete || {
    printf 'ERROR: guest config is invalid or missing required PostgreSQL settings\n' >&2
    exit 1
}
read_guest_state secrets && [ -n "${POSTGRES_PASSWORD:-}" ] && [ -n "${VALKEY_PASSWORD:-}" ] || {
    printf 'ERROR: guest service secrets are invalid or missing\n' >&2
    exit 1
}
VALKEY_PORT="${VALKEY_PORT:-16379}"

mkdir -p "$services/data/postgres" "$services/data/valkey"
chmod 700 "$services"
umask 077
printf '%s\n' \
    "POSTGRES_USER=$POSTGRES_USER" \
    "POSTGRES_DB=$POSTGRES_DB" \
    "POSTGRES_PORT=$POSTGRES_PORT" \
    "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    "VALKEY_PORT=$VALKEY_PORT" \
    "VALKEY_PASSWORD=$VALKEY_PASSWORD" >"$services/env"
install -m 600 "$DEVBOX_PROVISION_ROOT/config/services/compose.yaml" "$services/compose.yaml"
