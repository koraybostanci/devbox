#!/usr/bin/env bash
# Phase 8 acceptance: explicit, opt-in migration (no default promotion).
#
# Run from the devbox repository root with a running v2 VM and a legacy
# profile present:
#     bash scripts/accept-phase8.sh
#
# This copies projects into the v2 guest workspace. It never modifies the
# legacy profile or its host mounts.

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

echo "== migration is explicit and non-destructive =="
refute "migrate requires an explicit subcommand" ./devbox v2 migrate

projects_dir="$(cd "$(dirname "$0")/.." && pwd)/../projects"
legacy_before=""
if [ -d "$projects_dir" ]; then
    legacy_before="$(find "$projects_dir" -type f | wc -l | tr -d ' ')"
fi

check "devbox v2 migrate projects" ./devbox v2 migrate projects --force
check "v2 workspace exists" ./devbox v2 exec test -d /home/devbox/workspace
check "v2 workspace is populated" bash -c '
    [ -n "$(./devbox v2 exec ls -A /home/devbox/workspace)" ]
'

# Confirm a real legacy project landed in the guest workspace.
sample=""
if [ -d "$projects_dir" ]; then
    sample="$(find "$projects_dir" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort | head -n 1)"
    sample="$(basename "$sample")"
fi
if [ -n "$sample" ]; then
    check "migrated project '$sample' is present in the v2 workspace" \
        ./devbox v2 exec test -d "/home/devbox/workspace/$sample"
else
    printf 'WARN: no legacy project directories found to confirm the copy\n' >&2
fi

if [ -n "$legacy_before" ]; then
    legacy_after="$(find "$projects_dir" -type f | wc -l | tr -d ' ')"
    [ "$legacy_before" = "$legacy_after" ] &&
        ok "legacy projects are unchanged" ||
        no "legacy projects changed ($legacy_before -> $legacy_after)"
else
    printf 'WARN: legacy projects directory not found; skipping non-destructiveness check\n' >&2
fi

echo
echo "== v2 is not the default =="
check "default profile is still the legacy devbox profile" grep -q '^PROFILE="devbox"$' devbox

echo
printf 'Phase 8 acceptance: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
