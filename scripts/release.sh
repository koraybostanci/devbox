#!/usr/bin/env bash
# Build, verify, and install versioned devbox release archives.
#
#   scripts/release.sh build <version>
#   scripts/release.sh verify <archive.tar.gz>
#   scripts/release.sh install <archive.tar.gz> [--force]
#   scripts/release.sh list
#
# Releases are checksummed and carry a manifest; archives are extracted with
# path-traversal protection before anything is installed. Signing and
# signature verification are intentionally not wired up yet (Phase 6 hard
# prerequisite: a release-signing key decision).

set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Avoid AppleDouble/xattr sidecars when staging files on macOS.
export COPYFILE_DISABLE=1

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

hash_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

release_paths() {
    printf '%s\n' devbox README.md colima.yaml colima-v2.yaml
    find lib provision docs -type f | LC_ALL=C sort
}

validate_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
        die "invalid version: $1 (expected MAJOR.MINOR.PATCH)"
}

build_release() {
    local version="$1" dist staging payload path
    validate_version "$version"
    dist="$ROOT/dist"
    staging="$(mktemp -d)"
    payload="$staging/devbox-$version"
    mkdir -p "$payload"

    while IFS= read -r path; do
        [ -f "$path" ] || die "missing release file: $path"
        mkdir -p "$payload/$(dirname "$path")"
        cp "$path" "$payload/$path"
    done < <(release_paths)

    (
        cd "$payload"
        find . -type f ! -name MANIFEST -print | LC_ALL=C sort |
            while IFS= read -r entry; do
                printf '%s\t%s\n' "$(hash_of "$entry")" "${entry#./}"
            done
    ) >"$payload/MANIFEST"

    # Normalize mtimes so repeated builds of the same tree match.
    find "$payload" -exec touch -t 200001010000.00 {} +

    mkdir -p "$dist"
    (
        cd "$staging"
        find "devbox-$version" -type f -print | LC_ALL=C sort >"$staging/list"
        if tar --version 2>/dev/null | grep -qi gnu; then
            tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
                -cf - -T "$staging/list" | gzip -n >"$dist/devbox-$version.tar.gz"
        elif tar --help 2>&1 | grep -q -- '--no-mac-metadata'; then
            tar --no-mac-metadata -cf - -T "$staging/list" |
                gzip -n >"$dist/devbox-$version.tar.gz"
        else
            tar -cf - -T "$staging/list" | gzip -n >"$dist/devbox-$version.tar.gz"
        fi
    )
    printf '%s  %s\n' "$(hash_of "$dist/devbox-$version.tar.gz")" \
        "devbox-$version.tar.gz" >"$dist/SHA256SUMS"
    rm -rf "$staging"
    printf 'Built %s\n' "$dist/devbox-$version.tar.gz"
}

# Read archive entries safely: reject absolute paths, parent traversal, and
# anything outside a single devbox-<version> top-level directory.
check_archive_paths() {
    local archive="$1" entry top=
    while IFS= read -r entry; do
        case "$entry" in
            /* | *..* | "") die "unsafe archive path: '$entry'" ;;
        esac
        case "$entry" in
            devbox-*/ | devbox-*/*) ;;
            *) die "archive entry outside the release directory: '$entry'" ;;
        esac
        top="${entry%%/*}"
    done < <(tar -tzf "$archive")
    [ "$top" != "$archive" ] || die "archive is empty"
    printf '%s\n' "$top"
}

verify_release() {
    local archive="$1" dir file sums expected actual top
    [ -f "$archive" ] || die "archive not found: $archive"
    dir="$(cd "$(dirname "$archive")" && pwd)"
    file="$(basename "$archive")"
    sums="$dir/SHA256SUMS"
    [ -f "$sums" ] || die "missing SHA256SUMS next to $file"
    expected="$(awk -v f="$file" '$2 == f {print $1}' "$sums" | head -n 1)"
    [ -n "$expected" ] || die "SHA256SUMS has no entry for $file"
    actual="$(hash_of "$archive")"
    [ "$expected" = "$actual" ] || die "checksum mismatch for $file"

    top="$(check_archive_paths "$archive")"

    local extract
    extract="$(mktemp -d)"
    tar -xzf "$archive" -C "$extract"
    local manifest="$extract/$top/MANIFEST"
    [ -f "$manifest" ] || die "archive has no MANIFEST"
    while IFS=$'\t' read -r checksum path; do
        [ -n "$path" ] || continue
        [ -f "$extract/$top/$path" ] || die "manifest lists a missing file: $path"
        [ "$(hash_of "$extract/$top/$path")" = "$checksum" ] ||
            die "manifest checksum mismatch: $path"
    done <"$manifest"
    rm -rf "$extract"
    printf '%s\n' "$top"
}

install_release() {
    local archive="$1" force="${2:-false}" top version releases target current staging
    top="$(verify_release "$archive")"
    version="${top#devbox-}"
    releases="${XDG_DATA_HOME:-$HOME/.local/share}/devbox/releases"
    target="$releases/$version"
    current="$(dirname "$releases")/current"
    mkdir -p "$releases"
    [ ! -e "$target" ] || [ "$force" = true ] ||
        die "$target already exists (use --force to replace)"
    staging="$(mktemp -d "$releases/.install.XXXXXX")"
    tar -xzf "$archive" -C "$staging"
    rm -rf "$target"
    mv "$staging/$top" "$target"
    rm -rf "$staging"
    ln -sfn "$target" "$current"
    printf 'Installed %s\nActivated %s\n' "$target" "$current"
}

list_releases() {
    local releases="${XDG_DATA_HOME:-$HOME/.local/share}/devbox/releases"
    if [ -d "$releases" ]; then
        ls -1 "$releases"
    fi
}

case "${1:-}" in
    build)
        [ $# -eq 2 ] || die "Usage: scripts/release.sh build <version>"
        build_release "$2"
        ;;
    verify)
        [ $# -eq 2 ] || die "Usage: scripts/release.sh verify <archive.tar.gz>"
        top="$(verify_release "$2")"
        printf 'Verified %s (%s)\n' "$2" "$top"
        ;;
    install)
        [ $# -ge 2 ] && [ $# -le 3 ] || die "Usage: scripts/release.sh install <archive.tar.gz> [--force]"
        force=false
        [ "${3:-}" = "--force" ] && force=true
        install_release "$2" "$force"
        ;;
    list)
        [ $# -eq 1 ] || die "Usage: scripts/release.sh list"
        list_releases
        ;;
    *)
        die "Usage: scripts/release.sh <build|verify|install|list> ..."
        ;;
esac
