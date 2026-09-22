#!/usr/bin/env bash
# Build, verify, and install versioned devbox release archives.
#
#   scripts/release.sh build [version]   # VERSION is the source of truth
#   scripts/release.sh sign <archive.tar.gz> --key <private.pem>
#   scripts/release.sh verify <archive.tar.gz>
#   scripts/release.sh install <archive.tar.gz> [--force]
#   scripts/release.sh use <version>
#   scripts/release.sh list
#   scripts/release.sh prune [--keep N]
#
# Invariants:
# - Verification fails closed: an archive needs a SHA256SUMS.sig signed by the
#   committed public key (DEVBOX_RELEASE_PUBKEY overrides it); unsigned
#   archives are accepted only for local testing with DEVBOX_ALLOW_UNSIGNED=1.
# - Installations live under the canonical data root's releases/ and activate
#   through its current symlink (${XDG_DATA_HOME:-$HOME/.local/share}/devbox).
# - prune never removes the active release.
#
# Internals: docs/architecture.md. Operations: docs/release-checklist.md.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# User-supplied archive and key paths are relative to the caller's working
# directory, not to this script's tree; capture it before changing directories.
INVOCATION_DIR="$(pwd)"
cd "$ROOT"
source "$ROOT/lib/common.sh"

# Avoid AppleDouble/xattr sidecars when staging files on macOS.
export COPYFILE_DISABLE=1

# Temporary directories are registered here and removed on every exit path.
CLEANUP_PATHS=()
cleanup_paths() {
    local path
    if [ "${#CLEANUP_PATHS[@]}" -gt 0 ]; then
        for path in "${CLEANUP_PATHS[@]}"; do
            [ -n "$path" ] || continue
            command rm -rf "$path"
        done
    fi
}
trap cleanup_paths EXIT

hash_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

# Resolve a user-supplied path against the invocation directory; absolute
# paths are unchanged.
resolve_user_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "$INVOCATION_DIR/$1" ;;
    esac
}

release_paths() {
    printf '%s\n' VERSION .env.example devbox README.md colima.yaml scripts/release.sh
    find lib provision docs -type f | LC_ALL=C sort
}

validate_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
        die "invalid version: $1 (expected MAJOR.MINOR.PATCH)"
}

release_version() {
    local version

    [ -f "$ROOT/VERSION" ] || die "missing $ROOT/VERSION"
    version="$(cat "$ROOT/VERSION")"
    validate_version "$version"
    printf '%s\n' "$version"
}

build_release() {
    local requested="${1:-}" version dist staging payload path
    local DEVBOX_DIST_ROOT="${DEVBOX_DIST_ROOT:-$ROOT/dist}"
    version="$(release_version)"
    if [ -n "$requested" ] && [ "$requested" != "$version" ]; then
        die "requested version $requested does not match VERSION ($version); bump VERSION before tagging"
    fi
    dist="$DEVBOX_DIST_ROOT/devbox-$version"
    staging="$(mktemp -d)"
    CLEANUP_PATHS+=("$staging")
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
    # A fresh build is unsigned; drop any signature for a previous build.
    command rm -f "$dist/SHA256SUMS.sig"
    command rm -rf "$staging"
    printf 'Built %s\n' "$dist/devbox-$version.tar.gz"
}

# Reject archive entries that are neither regular files nor directories, using
# the verbose mode field before anything is extracted.
archive_entry_types() {
    local archive="$1" line mode

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        mode="${line%%[[:space:]]*}"
        case "$mode" in
            -*) ;;
            d*) ;;
            *) die "archive contains an unsupported entry type: $line" ;;
        esac
    done < <(tar -tvzf "$archive")
}

# Return the single devbox-<version> top-level directory of the archive,
# rejecting absolute paths, parent traversal, and empty entries.
archive_top_dir() {
    local archive="$1" entry top=

    while IFS= read -r entry; do
        [ -n "$entry" ] || die "archive contains an empty entry name"
        case "$entry" in
            /*) die "unsafe archive path: '$entry'" ;;
            *..*) die "unsafe archive path: '$entry'" ;;
        esac
        entry="${entry#./}"
        case "$entry" in
            devbox-*/ | devbox-*/* | devbox-*) ;;
            *) die "archive entry outside the release directory: '$entry'" ;;
        esac
        [ -z "$top" ] || [ "$top" = "${entry%%/*}" ] ||
            die "archive contains multiple top-level directories: '$top' and '${entry%%/*}'"
        top="${entry%%/*}"
    done < <(tar -tzf "$archive")

    [ -n "$top" ] || die "archive is empty"
    printf '%s\n' "$top"
}

archive_version() {
    local top="$1" version

    version="${top#devbox-}"
    validate_version "$version"
    printf '%s\n' "$version"
}

# Validate an extracted release tree against its MANIFEST. Runs in a subshell
# with its own temporary directory so callers that only need a yes/no answer can
# suppress its diagnostics without leaking temporary files. Dies on failure.
# VERSION is optional (legacy archives such as v0.0.1-rc1 predate it) but is
# checked against the release version whenever it is present.
validate_release_tree() (
    set -Eeuo pipefail
    local tree="$1" version="$2" temporary manifest paths_file files_file archive_files
    local line line_number=0 checksum path rest duplicate entry unexpected

    manifest="$tree/MANIFEST"
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || die "release tree has no MANIFEST"
    unexpected="$(find "$tree" ! -type f ! -type d -print -quit)"
    [ -z "$unexpected" ] ||
        die "archive contains an unsupported entry: ${unexpected#"$tree"/}"
    temporary="$(mktemp -d)"
    trap 'command rm -rf "$temporary"' EXIT
    paths_file="$temporary/paths"
    files_file="$temporary/files.sorted"
    archive_files="$temporary/files"
    : >"$paths_file"

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        checksum="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        [ "$rest" != "$line" ] || die "MANIFEST:$line_number is not <sha256><TAB><path>"
        path="$rest"
        [ -n "$path" ] || die "MANIFEST:$line_number has an empty path"
        [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] ||
            die "MANIFEST:$line_number has an invalid checksum"
        case "$path" in
            /*) die "MANIFEST:$line_number has an absolute path: $path" ;;
            MANIFEST) die "MANIFEST:$line_number lists MANIFEST itself" ;;
        esac
        # A `..` path component, not a substring: names such as lib/a..b are
        # legitimate, while lib/../etc/passwd escapes the release tree.
        case "/$path/" in
            */../*) die "MANIFEST:$line_number has a parent path: $path" ;;
        esac
        [ -f "$tree/$path" ] && [ ! -L "$tree/$path" ] ||
            die "manifest lists a missing file: $path"
        [ "$(hash_of "$tree/$path")" = "$checksum" ] ||
            die "manifest checksum mismatch: $path"
        printf '%s\n' "$path" >>"$paths_file"
    done <"$manifest"

    [ -s "$paths_file" ] || die "MANIFEST lists no files"
    duplicate="$(awk -F'\t' '{ if (seen[$2]++) { print $2; exit } }' "$manifest")"
    [ -z "$duplicate" ] || die "MANIFEST lists a path more than once: $duplicate"

    (
        cd "$tree"
        find . -type f ! -path './MANIFEST' -print | LC_ALL=C sort |
            while IFS= read -r entry; do
                printf '%s\n' "${entry#./}"
            done
    ) >"$archive_files"
    LC_ALL=C sort "$paths_file" >"$files_file"
    cmp -s "$files_file" "$archive_files" ||
        die "MANIFEST does not match the archived files"

    if [ -f "$tree/VERSION" ]; then
        [ "$(cat "$tree/VERSION")" = "$version" ] ||
            die "VERSION in the release tree does not match version $version"
    fi
)

# Quietly return 0 when an installed release tree still matches its MANIFEST.
installed_release_is_valid() {
    ( validate_release_tree "$1" "$2" ) >/dev/null 2>&1
}

release_public_key() {
    if [ -n "${DEVBOX_RELEASE_PUBKEY:-}" ]; then
        resolve_user_path "$DEVBOX_RELEASE_PUBKEY"
    else
        printf '%s\n' "$ROOT/release-signing-key.pub.pem"
    fi
}

# Print the checksum that $2 has in the SHA256SUMS file $1. The optional prefix
# contextualizes the failure for the caller (sign/verify).
sums_entry_for() {
    local sums="$1" file="$2" prefix="${3:-}" expected

    expected="$(awk -v f="$file" '$2 == f {print $1; exit}' "$sums")"
    [ -n "$expected" ] || die "${prefix}SHA256SUMS has no entry for $file"
    printf '%s\n' "$expected"
}

sign_release() {
    local archive="$1" key="$2" dir sums file expected
    archive="$(resolve_user_path "$archive")"
    key="$(resolve_user_path "$key")"
    [ -f "$archive" ] || die "archive not found: $archive"
    [ -f "$key" ] || die "signing key not found: $key"
    dir="$(cd "$(dirname "$archive")" && pwd)"
    file="$(basename "$archive")"
    sums="$dir/SHA256SUMS"
    [ -f "$sums" ] || die "missing SHA256SUMS next to $file"
    # Sign only checksums that actually cover this archive and its current
    # bytes, so a stray or stale SHA256SUMS can never produce a valid signature.
    expected="$(sums_entry_for "$sums" "$file" "refusing to sign: ")"
    [ "$expected" = "$(hash_of "$archive")" ] ||
        die "refusing to sign: checksum mismatch for $file"
    openssl dgst -sha256 -sign "$key" -out "$sums.sig" "$sums" ||
        die "signing failed"
    printf 'Signed %s\n' "$sums.sig"
}

verify_release() {
    local archive="$1" dir file sums expected actual top signature public_key version
    local extract tree

    archive="$(resolve_user_path "$archive")"
    [ -f "$archive" ] || die "archive not found: $archive"
    dir="$(cd "$(dirname "$archive")" && pwd)"
    file="$(basename "$archive")"
    sums="$dir/SHA256SUMS"
    [ -f "$sums" ] || die "missing SHA256SUMS next to $file"
    expected="$(sums_entry_for "$sums" "$file")"
    actual="$(hash_of "$archive")"
    [ "$expected" = "$actual" ] || die "checksum mismatch for $file"

    signature="$dir/SHA256SUMS.sig"
    public_key="$(release_public_key)"
    if [ -f "$signature" ]; then
        [ -f "$public_key" ] ||
            die "release is signed but no public key was found at $public_key (set DEVBOX_RELEASE_PUBKEY)"
        openssl dgst -sha256 -verify "$public_key" -signature "$signature" "$sums" \
            >/dev/null 2>&1 || die "release signature verification failed for $file"
    elif [ "${DEVBOX_ALLOW_UNSIGNED:-0}" = "1" ]; then
        warn "verifying $file without a signature because DEVBOX_ALLOW_UNSIGNED=1"
    else
        die "missing SHA256SUMS.sig next to $file (set DEVBOX_ALLOW_UNSIGNED=1 to override)"
    fi

    archive_entry_types "$archive"
    top="$(archive_top_dir "$archive")"
    version="$(archive_version "$top")"

    extract="$(mktemp -d)"
    CLEANUP_PATHS+=("$extract")
    tar -xzf "$archive" -C "$extract"
    tree="$extract/$top"
    [ -d "$tree" ] && [ ! -L "$tree" ] || die "archive has no $top directory"
    validate_release_tree "$tree" "$version"
    VERIFY_TOP="$top"
    # install_release extracts the archive a second time; record the hash of the
    # bytes that were verified so it can re-check them before that extraction.
    VERIFY_ARCHIVE_SHA256="$actual"
}

# Before switching releases, keep a legacy in-tree .env (from an install that
# predates the stable host configuration) at the stable host configuration
# path. The source is the versioned release directory itself; the activation
# symlink is never consulted.
migrate_release_env() {
    local source_dir="$1" stable config_root legacy

    stable="$(devbox_host_env_file)"
    legacy="$source_dir/.env"
    [ -f "$legacy" ] && [ ! -L "$legacy" ] || return 0
    if [ -e "$stable" ] || [ -L "$stable" ]; then
        return 0
    fi
    config_root="$(dirname "$stable")"
    if [ ! -d "$config_root" ]; then
        mkdir -p "$config_root"
        chmod 700 "$config_root"
    fi
    # Create the copy with mode 0600 from the start instead of a brief window
    # at the caller's umask.
    (
        umask 077
        cp "$legacy" "$stable"
    ) || die "could not preserve $legacy at $stable"
    chmod 600 "$stable"
    log "Kept host configuration at $stable"
}

# Point <data root>/current at a release without leaving it dangling, then
# refresh the devbox command on PATH. Legacy .env migration is install-only;
# `use` must not resurrect an old in-tree configuration.
activate_release() {
    local root="$1" target="$2" current="$1/current" temporary previous

    [ -d "$root" ] && [ ! -L "$root" ] || die "invalid release root: $root"
    if [ -e "$current" ] && [ ! -L "$current" ]; then
        die "$current is not a symlink; remove it and rerun the install"
    fi
    temporary="$(mktemp -d "$root/.activate.XXXXXX")"
    CLEANUP_PATHS+=("$temporary")
    ln -s "$target" "$temporary/current" ||
        die "could not stage the activation symlink in $root"
    # mv treats a symlink-to-directory destination as a directory, so move the
    # previous activation aside first and rename the staged link into place.
    previous="$temporary/previous"
    if [ -L "$current" ]; then
        mv "$current" "$previous" ||
            die "could not move aside the previous activation"
    fi
    if ! mv "$temporary/current" "$current"; then
        [ ! -L "$previous" ] || mv "$previous" "$current" 2>/dev/null || true
        die "could not activate $target"
    fi
    command rm -f "$previous"
    rmdir "$temporary"
    install_cli "$current/devbox"
}

install_release() {
    local archive="$1" force="${2:-false}"
    local top version root releases target current staging old previous reuse=false

    archive="$(resolve_user_path "$archive")"
    verify_release "$archive"
    top="$VERIFY_TOP"
    version="${top#devbox-}"
    root="$(devbox_data_root)"
    releases="$root/releases"
    target="$releases/$version"
    current="$root/current"

    mkdir -p "$releases"
    [ -d "$releases" ] && [ ! -L "$releases" ] || die "invalid release directory: $releases"

    if { [ -e "$target" ] || [ -L "$target" ]; } && [ "$force" != true ]; then
        if installed_release_is_valid "$target" "$version"; then
            reuse=true
        else
            warn "$target does not match its MANIFEST; replacing it"
        fi
    fi
    if [ "$reuse" = true ]; then
        log "Release $version is already installed."
        activate_release "$root" "$target"
        printf 'Activated %s\n' "$current"
        return
    fi

    staging="$(mktemp -d "$releases/.install.XXXXXX")"
    CLEANUP_PATHS+=("$staging")
    # verify_release validated an earlier extraction and recorded the archive
    # hash; re-check the bytes now so the staged tree comes from exactly the
    # verified archive.
    [ "$(hash_of "$archive")" = "$VERIFY_ARCHIVE_SHA256" ] ||
        die "refusing to install: archive changed after verification: $(basename "$archive")"
    tar -xzf "$archive" -C "$staging"
    [ -d "$staging/$top" ] && [ ! -L "$staging/$top" ] || die "archive has no $top directory"
    # The staged tree is re-validated here and the archive bytes were re-checked
    # above, so the installed tree is the tree verify_release checked.
    validate_release_tree "$staging/$top" "$version"

    # Keep a legacy in-tree .env at the stable host configuration path before
    # the target is moved aside and removed. Prefer the release being replaced;
    # otherwise preserve the configuration of the release it supersedes.
    if [ -e "$target" ] || [ -L "$target" ]; then
        migrate_release_env "$target"
    fi
    if [ -L "$current" ]; then
        previous="$(canonicalize_path "$current" 2>/dev/null || true)"
        [ -n "$previous" ] && migrate_release_env "$previous"
    fi

    if [ -e "$target" ] || [ -L "$target" ]; then
        old="$(mktemp -d "$releases/.replace.XXXXXX")"
        rmdir "$old" || die "could not stage the replacement of $target"
        mv "$target" "$old" || die "could not move the existing release aside: $target"
        if ! mv "$staging/$top" "$target"; then
            mv "$old" "$target" ||
                die "release replacement failed; the previous release is preserved at $old"
            die "could not install $target"
        fi
        command rm -rf "$old"
    else
        # Re-check right before the move so a target that appeared concurrently
        # cannot be nested into or silently overwritten.
        if [ -e "$target" ] || [ -L "$target" ]; then
            die "$target appeared during installation; rerun with --force to replace it"
        fi
        mv "$staging/$top" "$target" || die "could not install $target"
    fi
    command rm -rf "$staging"
    activate_release "$root" "$target"
    printf 'Installed %s\nActivated %s\n' "$target" "$current"
}

use_release() {
    local version="$1" root releases target

    validate_version "$version"
    root="$(devbox_data_root)"
    releases="$root/releases"
    target="$releases/$version"
    [ -d "$target" ] && [ ! -L "$target" ] || die "release $version is not installed"
    installed_release_is_valid "$target" "$version" ||
        die "release $version is installed but no longer matches its MANIFEST; reinstall it"
    activate_release "$root" "$target"
    printf 'Activated %s\n' "$target"
}

list_releases() {
    local root releases active entry name suffix

    root="$(devbox_data_root)"
    releases="$root/releases"
    [ -d "$releases" ] || return 0
    active=""
    if [ -L "$root/current" ]; then
        # The activation target and the release entries must be compared
        # canonically; a logical $HOME on macOS would otherwise never match the
        # physically resolved target.
        active="$(canonicalize_path "$root/current" 2>/dev/null || true)"
    fi
    for entry in "$releases"/*; do
        [ -d "$entry" ] || continue
        name="$(basename "$entry")"
        case "$name" in .*) continue ;; esac
        suffix=""
        if [ -n "$active" ] && [ "$(canonicalize_path "$entry")" = "$active" ]; then
            suffix=" (active)"
        fi
        printf '%s%s\n' "$name" "$suffix"
    done
}

# Remove non-active installed releases, keeping the active release plus the N
# most recently modified non-active releases (N defaults to 0), and remove
# staging directories older than 24 hours. Candidates are selected by
# directory mtime with portable tools; the active release is never removed.
# Version-named symlinks are never candidates, and a releases directory that is
# itself a symlink is refused before anything is removed.
prune_releases() {
    local keep="$1" root releases active entry name
    local removed=0 non_active_kept=0 stale_removed=0

    root="$(devbox_data_root)"
    releases="$root/releases"
    active=""
    if [ -L "$root/current" ]; then
        active="$(canonicalize_path "$root/current" 2>/dev/null || true)"
    fi

    # Never prune through a symlinked releases directory: the removal loop
    # would delete the entries of its target. Install rejects the same layout.
    if [ -e "$releases" ] || [ -L "$releases" ]; then
        [ -d "$releases" ] && [ ! -L "$releases" ] ||
            die "invalid release directory: $releases"
    fi

    if [ -d "$releases" ]; then
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            [ -d "$entry" ] || continue
            # `-d` follows symlinks; a version-named symlink is not a release
            # directory and removing it would follow it to its target.
            [ -L "$entry" ] && continue
            name="$(basename "$entry")"
            case "$name" in
                .*) continue ;;
            esac
            # Only well-formed release directories are candidates.
            [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || continue
            if [ -n "$active" ] && [ "$(canonicalize_path "$entry")" = "$active" ]; then
                continue
            fi
            if [ "$non_active_kept" -lt "$keep" ]; then
                non_active_kept=$((non_active_kept + 1))
                printf 'Kept %s\n' "$entry"
                continue
            fi
            command rm -rf "$entry"
            printf 'Removed release %s\n' "$entry"
            removed=$((removed + 1))
        done < <(command ls -td "$releases"/* 2>/dev/null || true)
    fi

    for entry in "$releases"/.install.* "$releases"/.replace.* "$root"/.activate.*; do
        [ -e "$entry" ] || continue
        [ -n "$(find "$entry" -maxdepth 0 -mmin +1440 -print 2>/dev/null)" ] || continue
        command rm -rf "$entry"
        printf 'Removed stale staging directory %s\n' "$entry"
        stale_removed=$((stale_removed + 1))
    done

    printf 'Prune complete: removed %d release(s) and %d stale staging dir(s); kept the active release plus %d non-active release(s).\n' \
        "$removed" "$stale_removed" "$non_active_kept"
}

case "${1:-}" in
    build)
        [ $# -le 2 ] || die "Usage: scripts/release.sh build [version]"
        build_release "${2:-}"
        ;;
    sign)
        [ $# -eq 4 ] && [ "$3" = "--key" ] ||
            die "Usage: scripts/release.sh sign <archive.tar.gz> --key <private.pem>"
        sign_release "$2" "$4"
        ;;
    verify)
        [ $# -eq 2 ] || die "Usage: scripts/release.sh verify <archive.tar.gz>"
        verify_release "$2"
        printf 'Verified %s (%s)\n' "$2" "$VERIFY_TOP"
        ;;
    install)
        [ $# -ge 2 ] && [ $# -le 3 ] ||
            die "Usage: scripts/release.sh install <archive.tar.gz> [--force]"
        force=false
        if [ "${3:-}" = "--force" ]; then
            force=true
        elif [ -n "${3:-}" ]; then
            die "Usage: scripts/release.sh install <archive.tar.gz> [--force]"
        fi
        install_release "$2" "$force"
        ;;
    use)
        [ $# -eq 2 ] || die "Usage: scripts/release.sh use <version>"
        use_release "$2"
        ;;
    list)
        [ $# -eq 1 ] || die "Usage: scripts/release.sh list"
        list_releases
        ;;
    prune)
        keep=0
        case "$#" in
            1) ;;
            3)
                [ "$2" = "--keep" ] ||
                    die "Usage: scripts/release.sh prune [--keep N]"
                keep="$3"
                ;;
            *) die "Usage: scripts/release.sh prune [--keep N]" ;;
        esac
        case "$keep" in
            '' | *[!0-9]*) die "invalid --keep value: $keep (expected a non-negative integer)" ;;
        esac
        prune_releases "$keep"
        ;;
    *)
        die "Usage: scripts/release.sh <build|sign|verify|install|use|list|prune> ..."
        ;;
esac
