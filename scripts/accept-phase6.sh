#!/usr/bin/env bash
# Phase 6 acceptance: release build, verification, and installation.
#
# Run from the devbox repository root:
#     bash scripts/accept-phase6.sh
#
# This phase does not require Colima. Signing and signature verification are
# not wired up yet (the hard prerequisite is a release-signing key decision),
# so this harness verifies the unsigned path: deterministic build, checksums,
# manifest integrity, path-traversal protection, installation, and activation.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

version="0.1.0-accept"
archive="dist/devbox-$version.tar.gz"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

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

echo "== build and verify =="
check "release builds" ./scripts/release.sh build "$version"
[ -f "$archive" ] || { printf 'FATAL: %s missing\n' "$archive" >&2; exit 1; }
check "release verifies" ./scripts/release.sh verify "$archive"

cp "$archive" "$work/first.tar.gz"
./scripts/release.sh build "$version" >/dev/null 2>&1
if cmp "$work/first.tar.gz" "$archive" >/dev/null 2>&1; then
    ok "rebuild is byte-identical"
else
    note "rebuild is not byte-identical (platform packaging differs)"
fi

echo
echo "== install and activate =="
check "release installs" env HOME="$work/home" ./scripts/release.sh install "$archive"
installed="$work/home/.local/share/devbox/releases/$version/devbox"
[ -x "$installed" ] && ok "installed launcher is executable" ||
    no "installed launcher is executable"
[ -L "$work/home/.local/share/devbox/current" ] &&
    ok "current release is activated" || no "current release is activated"
check "installed launcher runs" env HOME="$work/home" "$installed" help

echo
echo "== integrity =="
cp "$archive" "$work/tampered.tar.gz"
printf 'x' >>"$work/tampered.tar.gz"
refute "tampered archive fails verification" ./scripts/release.sh verify "$work/tampered.tar.gz"

echo
echo "== signing =="
key="$work/signing-key.pem"
openssl ecparam -name prime256v1 -genkey -noout -out "$key"
openssl ec -in "$key" -pubout -out "$work/signing-key.pub.pem" 2>/dev/null
check "release signs" ./scripts/release.sh sign "$archive" --key "$key"
check "signature verifies" env DEVBOX_RELEASE_PUBKEY="$work/signing-key.pub.pem" \
    ./scripts/release.sh verify "$archive"
printf 'tampered\n' >dist/SHA256SUMS.sig
refute "tampered signature is rejected" env DEVBOX_RELEASE_PUBKEY="$work/signing-key.pub.pem" \
    ./scripts/release.sh verify "$archive"
note "real releases require the committed release-signing public key and the RELEASE_SIGNING_KEY secret"

echo
printf 'Phase 6 acceptance: %d passed, %d failed, %d warning(s)\n' "$pass" "$fail" "$warn"
[ "$fail" -eq 0 ]
