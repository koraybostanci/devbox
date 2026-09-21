#!/usr/bin/env bash
# Phase 4a acceptance: guest-local v2 configuration and generated secrets.
#
# Run on the macOS host from the devbox repository root:
#     bash scripts/accept-phase4a.sh
#
# `devbox exec` sends its arguments through plain ssh, which joins argv and
# lets the guest shell re-parse it. Remote arguments are therefore kept simple
# (single paths); all matching/parsing is done locally on captured output.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

V2_CONFIG="/home/devbox/.config/devbox-v2/config"
V2_SECRETS="/home/devbox/.config/devbox-v2/secrets"
MARKER="# accept-phase4a marker"

pass=0
fail=0
warn=0

ok()   { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }
note() { printf 'WARN: %s\n' "$1"; warn=$((warn + 1)); }

# check DESC [CMD...]            -> PASS when CMD succeeds
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

# refute DESC [CMD...]           -> PASS when CMD fails
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

guest_file() { ./devbox exec cat "$1" 2>/dev/null; }

echo "== provisioning v2 =="
if ! ./devbox provision; then
    echo "FATAL: './devbox provision' failed; capture the output above." >&2
    exit 1
fi

# Positive control: without a working exec channel, negative checks pass
# vacuously.
if ! ./devbox exec true >/dev/null 2>&1; then
    echo "FATAL: the v2 exec channel is unusable; cannot verify Phase 4a." >&2
    exit 1
fi

echo
echo "== guest-local layout =="
check "config exists" ./devbox exec test -f "$V2_CONFIG"
check "secrets exists" ./devbox exec test -f "$V2_SECRETS"
equal "config mode is 600" 600 ./devbox exec stat -c %a "$V2_CONFIG"
equal "secrets mode is 600" 600 ./devbox exec stat -c %a "$V2_SECRETS"
refute "superseded env file is gone" ./devbox exec test -e /home/devbox/.config/devbox-v2/env

echo
echo "== generated secret =="
secrets_content="$(guest_file "$V2_SECRETS")"
config_content="$(guest_file "$V2_CONFIG")"
printf '%s\n' "$secrets_content" | grep -Eq '^export POSTGRES_PASSWORD=[0-9a-f]{48}$' &&
    ok "POSTGRES_PASSWORD is a generated 48-hex value" ||
    no "POSTGRES_PASSWORD is a generated 48-hex value"
printf '%s\n' "$secrets_content" | grep -q 'devpass' &&
    no "POSTGRES_PASSWORD is not the legacy default" ||
    ok "POSTGRES_PASSWORD is not the legacy default"
printf '%s\n' "$config_content" | grep -q '^export POSTGRES_USER=' &&
    ok "config carries non-secret PostgreSQL defaults" ||
    no "config carries non-secret PostgreSQL defaults"
printf '%s\n' "$config_content" | grep -q 'POSTGRES_PASSWORD' &&
    no "config must not contain POSTGRES_PASSWORD" ||
    ok "config does not contain POSTGRES_PASSWORD"

echo
echo "== configuration is seed-once and guest-authoritative =="
config_before="$(./devbox exec sha256sum "$V2_CONFIG" 2>/dev/null | cut -d' ' -f1)"
secrets_before="$(./devbox exec sha256sum "$V2_SECRETS" 2>/dev/null | cut -d' ' -f1)"
if ./devbox provision >/dev/null 2>&1; then
    config_after="$(./devbox exec sha256sum "$V2_CONFIG" 2>/dev/null | cut -d' ' -f1)"
    secrets_after="$(./devbox exec sha256sum "$V2_SECRETS" 2>/dev/null | cut -d' ' -f1)"
    [ -n "$config_before" ] && [ "$config_before" = "$config_after" ] &&
        ok "config is preserved across re-provision" ||
        no "config changed across re-provision"
    [ -n "$secrets_before" ] && [ "$secrets_before" = "$secrets_after" ] &&
        ok "generated secret is stable across re-provision" ||
        no "generated secret changed across re-provision"
else
    no "second provision failed"
fi

# Guest edit: append a benign comment via stdin, re-provision, then remove it.
printf '%s\n' "$MARKER" | ./devbox exec tee -a "$V2_CONFIG" >/dev/null 2>&1
if ./devbox provision >/dev/null 2>&1; then
    if guest_file "$V2_CONFIG" | grep -qF "$MARKER"; then
        ok "guest edits to config survive re-provision"
    else
        no "guest edits to config were overwritten"
    fi
else
    no "third provision failed"
fi
guest_file "$V2_CONFIG" | grep -vF "$MARKER" | ./devbox exec tee "$V2_CONFIG" >/dev/null 2>&1

echo
printf 'Phase 4a acceptance: %d passed, %d failed, %d warning(s)\n' "$pass" "$fail" "$warn"
[ "$fail" -eq 0 ]
