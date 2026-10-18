#!/bin/bash
# Guest state for devbox. Runs as root from lib/devbox.sh with the host seed
# (GIT_NAME, GIT_EMAIL, POSTGRES_*) on stdin.
#
#   config   - non-secret defaults; seeded once by the guest, then the guest
#              is authoritative.
#   secrets  - service secrets; always generated inside the guest, never seeded
#              from the host.
#   services - root-owned definition and credentials for PostgreSQL and Valkey;
#              the containers stay stopped until `devbox services start`.
#
# The guest user owns config and secrets, so it seeds them itself. That single
# guest run emits its canonical, already-validated service assignments as
# `KEY=value` data on stdout, and root stages services/env from the captured
# pass — the second parse of the same guest files was removed.

set -Eeuo pipefail
trap 'printf "ERROR: devbox state setup failed at line %s\n" "$LINENO" >&2' ERR
cd /

export DEVBOX_PROVISION_ROOT="${DEVBOX_PROVISION_ROOT:-/var/lib/devbox/provision}"
# The state helper resolves within the staged provisioning tree, which is not
# a statically followable path.
# shellcheck disable=SC1091
source "$DEVBOX_PROVISION_ROOT/scripts/lib/state.sh"

directory=/home/devbox/.config/devbox
services=/var/lib/devbox/services

# The guest seeds its own config and secrets; the host seed (state.sh's stdin)
# still reaches the guest function, and the seed's stdout is the canonical
# KEY=value pass consumed below. Nothing executes a captured line.
state_data="$(sudo -u devbox -- env HOME=/home/devbox /bin/bash -c '
    set -Eeuo pipefail
    source "$1"
    devbox_seed_guest_state "$2"
' _ "$DEVBOX_PROVISION_ROOT/scripts/lib/state.sh" "$directory")" || {
    printf 'ERROR: devbox guest config or secrets could not be safely seeded\n' >&2
    exit 1
}

umask 077
mkdir -p "$services/data/postgres" "$services/data/valkey"
chmod 700 "$services" "$services/data" "$services/data/postgres" "$services/data/valkey"

# The pass was already validated inside devbox_seed_guest_state, so root only
# maps its allowlisted lines into services/env as data. The assignment regexp
# below is kept identical to devbox_parse_state_file's; values are re-emitted
# verbatim, never evaluated as shell code.
temporary="$(mktemp "$services/.env.XXXXXX")"
while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)= ]] || {
        printf 'ERROR: invalid assignment in the captured guest state pass\n' >&2
        rm -f -- "$temporary"
        exit 1
    }
    key="${BASH_REMATCH[2]}"
    case "$key" in
        POSTGRES_USER | POSTGRES_DB | POSTGRES_PORT | POSTGRES_PASSWORD | \
            VALKEY_PORT | VALKEY_PASSWORD)
            printf '%s=%s\n' "$key" "${line#*=}" >>"$temporary"
            ;;
    esac
done <<<"$state_data"
# Not a second parser: each of the six required assignments only gets a
# presence test, backed by the seed function's guarantee, so a missing key
# fails loudly instead of surfacing later as a compose interpolation error.
for key in POSTGRES_USER POSTGRES_DB POSTGRES_PORT POSTGRES_PASSWORD \
    VALKEY_PORT VALKEY_PASSWORD; do
    if ! grep -qx "^$key=.*" "$temporary"; then
        printf 'ERROR: the guest state pass is missing %s\n' "$key" >&2
        rm -f -- "$temporary"
        exit 1
    fi
done
mv -f -- "$temporary" "$services/env"
install -m 600 "$DEVBOX_PROVISION_ROOT/config/services/compose.yaml" "$services/compose.yaml"
