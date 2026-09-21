#!/bin/bash
# Versioned release build, signing, verification, and installation.
#
# Sourced by the `devbox` launcher (and by scripts/release.sh, kept as a thin
# wrapper). Releases are checksummed, carry a manifest, and are signed with the
# release signing key. Archives are extracted with path-traversal protection
# before anything is installed. Verification checks the signature against the
# committed public key (override with DEVBOX_RELEASE_PUBKEY).

# Avoid AppleDouble/xattr sidecars when staging files on macOS.
export COPYFILE_DISABLE=1

DEVBOX_RELEASE_ROOT="${DEVBOX_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

release_usage() {
    cat <<'EOF'
Usage: devbox release <command> [options]

    build <version>               Build dist/devbox-<version>.tar.gz
    sign <archive> --key <key>    Sign the archive's SHA256SUMS
    verify <archive>              Verify checksum, manifest, and signature
    install <archive> [--force]   Install and activate a release
    list                          List installed releases
EOF
}

release_hash_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

release_paths() {
    printf '%s\n' devbox README.md colima.yaml release-signing-key.pub.pem
    find lib provision docs -type f | LC_ALL=C sort
}

release_validate_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
        die "invalid version: $1 (expected MAJOR.MINOR.PATCH)"
}

build_release() {
    local version="$1" dist staging payload path
    release_validate_version "$version"
    cd "$DEVBOX_RELEASE_ROOT" || die "cannot enter $DEVBOX_RELEASE_ROOT"
    dist="$DEVBOX_RELEASE_ROOT/dist"
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
                printf '%s\t%s\n' "$(release_hash_of "$entry")" "${entry#./}"
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
    printf '%s  %s\n' "$(release_hash_of "$dist/devbox-$version.tar.gz")" \
        "devbox-$version.tar.gz" >"$dist/SHA256SUMS"
    # A fresh build is unsigned; drop any signature for a previous build.
    rm -f "$dist/SHA256SUMS.sig"
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

release_public_key() {
    printf '%s\n' "${DEVBOX_RELEASE_PUBKEY:-$DEVBOX_RELEASE_ROOT/release-signing-key.pub.pem}"
}

sign_release() {
    local archive="$1" key="$2" dir sums
    [ -f "$archive" ] || die "archive not found: $archive"
    [ -f "$key" ] || die "signing key not found: $key"
    dir="$(cd "$(dirname "$archive")" && pwd)"
    sums="$dir/SHA256SUMS"
    [ -f "$sums" ] || die "missing SHA256SUMS next to $(basename "$archive")"
    openssl dgst -sha256 -sign "$key" -out "$sums.sig" "$sums" ||
        die "signing failed"
    printf 'Signed %s\n' "$sums.sig"
}

verify_release() {
    local archive="$1" dir file sums expected actual top signature public_key
    [ -f "$archive" ] || die "archive not found: $archive"
    dir="$(cd "$(dirname "$archive")" && pwd)"
    file="$(basename "$archive")"
    sums="$dir/SHA256SUMS"
    [ -f "$sums" ] || die "missing SHA256SUMS next to $file"
    expected="$(awk -v f="$file" '$2 == f {print $1}' "$sums" | head -n 1)"
    [ -n "$expected" ] || die "SHA256SUMS has no entry for $file"
    actual="$(release_hash_of "$archive")"
    [ "$expected" = "$actual" ] || die "checksum mismatch for $file"

    signature="$dir/SHA256SUMS.sig"
    public_key="$(release_public_key)"
    if [ -f "$signature" ]; then
        [ -f "$public_key" ] ||
            die "archive is signed but no public key found at $public_key"
        openssl dgst -sha256 -verify "$public_key" -signature "$signature" "$sums" \
            >/dev/null 2>&1 || die "release signature verification failed for $file"
    elif [ -f "$public_key" ]; then
        printf 'WARN: %s has no signature (SHA256SUMS.sig)\n' "$file" >&2
    fi

    top="$(check_archive_paths "$archive")"

    local extract
    extract="$(mktemp -d)"
    tar -xzf "$archive" -C "$extract"
    local manifest="$extract/$top/MANIFEST"
    [ -f "$manifest" ] || die "archive has no MANIFEST"
    while IFS=$'\t' read -r checksum path; do
        [ -n "$path" ] || continue
        [ -f "$extract/$top/$path" ] || die "manifest lists a missing file: $path"
        [ "$(release_hash_of "$extract/$top/$path")" = "$checksum" ] ||
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

run_devbox_release() (
    cd "$DEVBOX_RELEASE_ROOT" || exit 1
    case "${1:-}" in
        build)
            [ $# -eq 2 ] || die "Usage: devbox release build <version>"
            build_release "$2"
            ;;
        sign)
            [ $# -eq 4 ] && [ "$3" = "--key" ] ||
                die "Usage: devbox release sign <archive.tar.gz> --key <private.pem>"
            sign_release "$2" "$4"
            ;;
        verify)
            [ $# -eq 2 ] || die "Usage: devbox release verify <archive.tar.gz>"
            top="$(verify_release "$2")"
            printf 'Verified %s (%s)\n' "$2" "$top"
            ;;
        install)
            [ $# -ge 2 ] && [ $# -le 3 ] ||
                die "Usage: devbox release install <archive.tar.gz> [--force]"
            force=false
            [ "${3:-}" = "--force" ] && force=true
            install_release "$2" "$force"
            ;;
        list)
            [ $# -eq 1 ] || die "Usage: devbox release list"
            list_releases
            ;;
        help | --help | -h)
            release_usage
            ;;
        '')
            release_usage
            exit 1
            ;;
        *)
            release_usage >&2
            die "Unknown release command: $1"
            ;;
    esac
)
