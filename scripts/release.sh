#!/bin/bash
# Build a release (dist/) and, unless --build-only, create a draft GitHub
# release for tag v<VERSION>. Maintainer tool; run on a clean main.
# Usage: scripts/release.sh [--build-only]

set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/lib/common.sh"

build_only=0
case "${1:-}" in
    '') ;;
    --build-only) build_only=1 ;;
    *) die "Usage: scripts/release.sh [--build-only]" ;;
esac

read -r version <VERSION || true
case "$version" in
    '' | *[!0-9.]*) die "VERSION must be X.Y.Z, got '$version'" ;;
esac
name="devbox-$version"
dist="$ROOT/dist"

if [ "$build_only" = 0 ]; then
    [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "release from main"
    [ -z "$(git status --porcelain)" ] || die "working tree is not clean"
    if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
        die "tag v$version already exists; bump VERSION"
    fi
    bash scripts/check.sh
fi

stage="$(mktemp -d)"
trap 'command rm -rf "$stage"' EXIT
mkdir -p "$stage/$name"
cp -pR devbox lib provision colima.yaml VERSION "$stage/$name/"
printf 'release\n' >"$stage/$name/RELEASE"
find "$stage" -exec touch -h -t 200001010000 {} +
(cd "$stage" && find "$name" -print | LC_ALL=C sort >list)

command rm -rf "$dist"
mkdir -p "$dist"
if tar --version 2>/dev/null | grep -q GNU; then
    owner_flags=(--owner=0 --group=0 --numeric-owner)
else
    owner_flags=(--uid 0 --gid 0 --numeric-owner)
fi
if [ "$(uname -s)" = Darwin ]; then
    export COPYFILE_DISABLE=1
    owner_flags+=(--no-mac-metadata)
fi
(cd "$stage" && tar -cf - --no-recursion "${owner_flags[@]}" -T list) | gzip -n >"$dist/$name.tar.gz"
if command -v shasum >/dev/null 2>&1; then
    (cd "$dist" && shasum -a 256 "$name.tar.gz" >"$name.tar.gz.sha256")
else
    (cd "$dist" && sha256sum "$name.tar.gz" >"$name.tar.gz.sha256")
fi
printf '%s\n' "$version" >"$dist/LATEST"
cp install.sh "$dist/install.sh"
log "Built $dist/$name.tar.gz"

if [ "$build_only" = 1 ]; then
    exit 0
fi
gh release create "v$version" --draft --generate-notes --title "devbox $version" \
    "$dist/$name.tar.gz" "$dist/$name.tar.gz.sha256" "$dist/install.sh"
log "Draft release v$version created; review and publish it on GitHub."
