#!/usr/bin/env bash
# Phase 3 acceptance for the devbox v2 guest identity and workspace.
#
# Run on the macOS host from the devbox repository root:
#     bash scripts/accept-phase3.sh
#
# The script provisions (or resumes) the v2 profile, then verifies the Phase 3
# acceptance conditions. It exits non-zero if any check fails.
#
# Invoke it from the repository (e.g. `bash scripts/accept-phase3.sh` or
# `./scripts/accept-phase3.sh`), not via PATH.
#
# The legacy section checks configuration, not reachability: a stopped legacy
# VM is reported as a warning, never a Phase 3 failure.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

pass=0
fail=0
warn=0

ok()   { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }
note() { printf 'WARN: %s\n' "$1"; warn=$((warn + 1)); }

# check DESC CMD [ARGS...]  -> PASS when CMD succeeds; failures print output.
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

# refute DESC CMD [ARGS...] -> PASS when CMD fails.
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

# equal DESC EXPECTED CMD [ARGS...] -> PASS when output equals EXPECTED.
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

# Positive control. Without this, a broken exec channel would make every
# negative check below pass vacuously.
if ! ./devbox v2 exec true >/dev/null 2>&1; then
    echo "FATAL: the v2 exec channel is unusable; cannot verify Phase 3." >&2
    exit 1
fi

echo
echo "== identity and workspace =="
equal "./devbox v2 exec id -un is devbox" devbox ./devbox v2 exec id -un
equal "./devbox v2 exec pwd is /home/devbox" /home/devbox ./devbox v2 exec pwd
equal "ssh devbox-v2 id -un is devbox" devbox ssh -o BatchMode=yes -o ConnectTimeout=10 devbox-v2 id -un
equal "ssh devbox-v2 pwd is /home/devbox" /home/devbox ssh -o BatchMode=yes -o ConnectTimeout=10 devbox-v2 pwd
check "workspace /home/devbox/workspace is writable" ./devbox v2 exec test -w /home/devbox/workspace

echo
echo "== privilege boundary =="
refute "devbox is not in a privileged group" bash -c \
    './devbox v2 exec id -nG | tr " " "\n" | grep -Eq "^(sudo|wheel|admin|adm)$"'
check "sudo reports devbox is not allowed to run sudo" bash -c \
    './devbox v2 exec env LC_ALL=C sudo -n -l 2>&1 | grep -q "is not allowed to run sudo on"'
refute "devbox cannot execute passwordless sudo" ./devbox v2 exec sudo -n true
check "devbox cannot write the Docker socket" bash -c \
    '! ./devbox v2 exec test -S /var/run/docker.sock || ! ./devbox v2 exec test -w /var/run/docker.sock'
check "root bundle state exists and is unreadable" bash -c \
    './devbox v2 exec test -d /var/lib/devbox-v2/bundles &&
        ! ./devbox v2 exec test -r /var/lib/devbox-v2/bundles'

echo
echo "== no legacy mounts in v2 =="
refute "no /mnt/devbox/projects in v2" ./devbox v2 exec test -e /mnt/devbox/projects
refute "no /mnt/devbox/data in v2" ./devbox v2 exec test -e /mnt/devbox/data

echo
echo "== legacy profile unchanged =="
check "legacy devbox SSH alias is still managed" bash -c \
    'grep -q "^Host devbox$" "$HOME/.ssh/config.d/devbox"'
check "legacy devbox Colima profile still exists" bash -c \
    'colima list 2>/dev/null | grep -qE "^devbox[[:space:]]"'
if ssh -o BatchMode=yes -o ConnectTimeout=5 devbox true >/dev/null 2>&1; then
    ok "legacy devbox VM is reachable"
else
    note "legacy devbox VM is not running; reachability not verified (alias and profile are intact)"
fi

echo
printf 'Phase 3 acceptance: %d passed, %d failed, %d warning(s)\n' "$pass" "$fail" "$warn"
[ "$fail" -eq 0 ]
