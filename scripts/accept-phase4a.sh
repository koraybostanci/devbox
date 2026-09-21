#!/usr/bin/env bash
# Phase 4a acceptance: guest-local v2 configuration and generated secrets.
#
# Run on the macOS host from the devbox repository root:
#     bash scripts/accept-phase4a.sh
#
# Provisions, then verifies that the v2 guest stores non-secret defaults and
# generated secrets guest-locally, seeds configuration once, and never takes
# the service secret from the host. Exits non-zero if any check fails.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

V2_CONFIG="/home/devbox/.config/devbox-v2/config"
V2_SECRETS="/home/devbox/.config/devbox-v2/secrets"

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

equal() {
    local desc="$1" expected="$2" actual
    shift 2
    actual="$("$@" 2>/dev/null | tr -d '\r')"
    if [ "$actual" = "$expected" ]; then
        ok "$desc"
    else
        no "$desc (expected '$expected', got '$actual')"
    fi
}

echo "== provisioning v2 =="
if ! ./devbox v2 provision; then
    echo "FATAL: './devbox v2 provision' failed; capture the output above." >&2
    exit 1
fi

# Positive control: without a working exec channel, negative checks would pass
# vacuously.
if ! ./devbox v2 exec true >/dev/null 2>&1; then
    echo "FATAL: the v2 exec channel is unusable; cannot verify Phase 4a." >&2
    exit 1
fi

echo
echo "== guest-local layout =="
check "config exists" ./devbox v2 exec test -f "$V2_CONFIG"
check "secrets exists" ./devbox v2 exec test -f "$V2_SECRETS"
equal "config mode is 600" 600 ./devbox v2 exec stat -c %a "$V2_CONFIG"
equal "secrets mode is 600" 600 ./devbox v2 exec stat -c %a "$V2_SECRETS"
refute "superseded env file is gone" ./devbox v2 exec test -e /home/devbox/.config/devbox-v2/env

echo
echo "== generated secret =="
check "POSTGRES_PASSWORD is a generated 48-hex value" bash -c \
    "./devbox v2 exec grep -Eq '^export POSTGRES_PASSWORD=[0-9a-f]{48}\$' '$V2_SECRETS'"
refute "POSTGRES_PASSWORD is not the legacy default" bash -c \
    "./devbox v2 exec grep -q 'devpass' '$V2_SECRETS'"
check "config carries non-secret PostgreSQL defaults" bash -c \
    "./devbox v2 exec grep -q '^export POSTGRES_USER=' '$V2_CONFIG'"

echo
echo "== configuration is seed-once and guest-authoritative =="
config_before="$(./devbox v2 exec sha256sum "$V2_CONFIG" 2>/dev/null | cut -d' ' -f1)"
secrets_before="$(./devbox v2 exec sha256sum "$V2_SECRETS" 2>/dev/null | cut -d' ' -f1)"
if ./devbox v2 provision >/dev/null 2>&1; then
    config_after="$(./devbox v2 exec sha256sum "$V2_CONFIG" 2>/dev/null | cut -d' ' -f1)"
    secrets_after="$(./devbox v2 exec sha256sum "$V2_SECRETS" 2>/dev/null | cut -d' ' -f1)"
    [ -n "$config_before" ] && [ "$config_before" = "$config_after" ] &&
        ok "config is preserved across re-provision" ||
        no "config changed across re-provision"
    [ -n "$secrets_before" ] && [ "$secrets_before" = "$secrets_after" ] &&
        ok "generated secret is stable across re-provision" ||
        no "generated secret changed across re-provision"
else
    no "second provision failed"
fi

./devbox v2 exec bash -c 'printf "%s\n" "# accept-phase4a marker" >>"$HOME/.config/devbox-v2/config"'
if ./devbox v2 provision >/dev/null 2>&1; then
    if ./devbox v2 exec grep -qF '# accept-phase4a marker' "$V2_CONFIG" >/dev/null 2>&1; then
        ok "guest edits to config survive re-provision"
    else
        no "guest edits to config were overwritten"
    fi
else
    no "third provision failed"
fi
./devbox v2 exec sed -i '/# accept-phase4a marker/d' "$V2_CONFIG"

echo
printf 'Phase 4a acceptance: %d passed, %d failed, %d warning(s)\n' "$pass" "$fail" "$warn"
[ "$fail" -eq 0 ]
