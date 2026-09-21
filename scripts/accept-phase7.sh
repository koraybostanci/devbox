#!/usr/bin/env bash
# Phase 7 acceptance: v2 has no host jq/yq/Docker requirement.
#
# Run from the devbox repository root (needs a running v2 VM for the lifecycle
# checks):
#     bash scripts/accept-phase7.sh

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

pass=0
fail=0

ok() { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }
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

echo "== v2 does not require host jq/yq =="
if grep -nE '(^|[^[:alnum:]_])(jq|yq)([^[:alnum:]_]|$)' lib/v2.sh; then
    no "lib/v2.sh references jq or yq"
else
    ok "lib/v2.sh references no jq or yq"
fi
check "Colima is the only declared external dependency" grep -q 'for command_name in colima ssh;' lib/v2.sh

echo
echo "== lifecycle works without jq/yq =="
check "devbox v2 status" ./devbox v2 status
check "devbox v2 services status" ./devbox v2 services status
check "devbox v2 exec works" ./devbox v2 exec true

printf 'Note: v2 needs only Colima, OpenSSH, and macOS built-ins; contributor\n' >&2
printf 'tooling (scripts/check.sh) still uses brew/jq/yq/docker.\n' >&2

echo
printf 'Phase 7 acceptance: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
