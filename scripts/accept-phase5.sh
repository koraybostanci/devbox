#!/usr/bin/env bash
# Phase 5 acceptance: root-managed PostgreSQL and Valkey.
#
# Run on the macOS host from the devbox repository root:
#     bash scripts/accept-phase5.sh
#
# Provisions, then verifies that both services are root-managed, healthy, bound
# to loopback only, and not controllable by the `devbox` user. Remote commands
# keep simple arguments; matching happens locally.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

pass=0
fail=0
warn=0

ok()   { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }
note() { printf 'WARN: %s\n' "$1"; warn=$((warn + 1)); }

check() {
    local desc="$1" out
    shift
    if out="$("$@" 2>&1)"; then
        ok "$desc"
    else
        no "$desc"
        if [ -n "$out" ]; then printf '      %s\n' "$out" >&2; fi
    fi
}

refute() {
    local desc="$1" out
    shift
    if out="$("$@" 2>&1)"; then
        no "$desc"
        if [ -n "$out" ]; then printf '      %s\n' "$out" >&2; fi
    else
        ok "$desc"
    fi
}

echo "== provisioning v2 =="
if ! ./devbox provision; then
    echo "FATAL: './devbox provision' failed; capture the output above." >&2
    exit 1
fi

if ! ./devbox exec true >/dev/null 2>&1; then
    echo "FATAL: the v2 exec channel is unusable; cannot verify Phase 5." >&2
    exit 1
fi

echo
echo "== root-managed services =="
services_status="$(./devbox services status 2>&1)"
if [ -n "$services_status" ]; then
    printf '%s\n' "$services_status"
else
    no "devbox services status produced no output"
fi

printf '%s\n' "$services_status" | grep -qi 'postgres' &&
    ok "PostgreSQL service is present" ||
    no "PostgreSQL service is present"
printf '%s\n' "$services_status" | grep -qi 'valkey' &&
    ok "Valkey service is present" ||
    no "Valkey service is present"

healthy="$(printf '%s\n' "$services_status" | grep -ci 'healthy')"
[ "${healthy:-0}" -ge 2 ] &&
    ok "both services report healthy" ||
    no "both services report healthy (found ${healthy:-0} healthy rows)"

printf '%s\n' "$services_status" | grep -q '127.0.0.1' &&
    ok "services are bound to loopback" ||
    no "services are bound to loopback"

echo
echo "== isolation =="
refute "devbox cannot control Docker" ./devbox exec docker ps
refute "devbox cannot read the service credentials file" \
    ./devbox exec test -r /var/lib/devbox-v2/services/env

echo
printf 'Phase 5 acceptance: %d passed, %d failed, %d warning(s)\n' "$pass" "$fail" "$warn"
[ "$fail" -eq 0 ]
