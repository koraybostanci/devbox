#!/bin/bash
# Guest state for devbox. Runs as root from lib/devbox.sh with the host seed
# (GIT_NAME, GIT_EMAIL, POSTGRES_*) on stdin.
#
#   config  - non-secret defaults; seeded once, then the guest is authoritative.
#   secrets - service secrets; always generated inside the guest, never seeded
#             from the host.
#   services - root-owned definition and credentials for PostgreSQL and Valkey;
#             the containers stay stopped until `devbox services start`.

set -Eeuo pipefail
trap 'printf "ERROR: devbox state setup failed at line %s\n" "$LINENO" >&2' ERR

export DEVBOX_PROVISION_ROOT="${DEVBOX_PROVISION_ROOT:-/var/lib/devbox/provision}"

directory=/home/devbox/.config/devbox
services=/var/lib/devbox/services
config="$directory/config"
secrets="$directory/secrets"

[ -d /home/devbox ] && [ ! -L /home/devbox ] || {
    printf 'ERROR: devbox guest home is invalid\n' >&2
    exit 1
}
[ ! -L "$directory" ] || {
    printf 'ERROR: devbox configuration directory is invalid\n' >&2
    exit 1
}
install -d -o devbox -g devbox -m 700 "$directory"
umask 077

# Seed the configuration once; the guest copy is authoritative afterwards.
if [ ! -s "$config" ] || ! grep -q '^export POSTGRES_USER=' "$config" 2>/dev/null; then
    temporary="$(mktemp "$directory/.config.XXXXXX")"
    cat >"$temporary"
    chmod 600 "$temporary"
    chown devbox:devbox "$temporary"
    mv "$temporary" "$config"
else
    cat >/dev/null
fi

# Preserve existing secrets and generate any missing value.
temporary="$(mktemp "$directory/.secrets.XXXXXX")"
if [ -e "$secrets" ]; then
    cat "$secrets" >"$temporary"
fi
grep -q '^export POSTGRES_PASSWORD=' "$temporary" ||
    printf 'export POSTGRES_PASSWORD=%s\n' \
        "$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" >>"$temporary"
grep -q '^export VALKEY_PASSWORD=' "$temporary" ||
    printf 'export VALKEY_PASSWORD=%s\n' \
        "$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" >>"$temporary"
chmod 600 "$temporary"
chown devbox:devbox "$temporary"
mv "$temporary" "$secrets"

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
set -a
. "$config"
. "$secrets"
set +a
missing=
[ -n "${POSTGRES_USER:-}" ] || missing="$missing POSTGRES_USER"
[ -n "${POSTGRES_DB:-}" ] || missing="$missing POSTGRES_DB"
[ -n "${POSTGRES_PORT:-}" ] || missing="$missing POSTGRES_PORT"
[ -n "${POSTGRES_PASSWORD:-}" ] || missing="$missing POSTGRES_PASSWORD"
[ -n "${VALKEY_PASSWORD:-}" ] || missing="$missing VALKEY_PASSWORD"
[ -z "$missing" ] || {
    printf 'ERROR: devbox service credentials are missing:%s\n' "$missing" >&2
    exit 1
}
VALKEY_PORT="${VALKEY_PORT:-16379}"
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
