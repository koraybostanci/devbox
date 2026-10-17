#!/bin/bash

stage() {
    printf '\n--- %s\n' "$1"
}

download_verified() {
    local url="$1" sha256="$2" destination="$3"

    # Stalled-transfer hardening applies to every verified download: abort on
    # a 10s connect failure or a transfer stalled below 1 KiB/s for 30s.
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        --connect-timeout 10 --speed-limit 1024 --speed-time 30 \
        --retry 3 --retry-connrefused --retry-all-errors "$url" -o "$destination"
    if ! printf '%s  %s\n' "$sha256" "$destination" | sha256sum -c - >/dev/null; then
        printf 'ERROR: checksum verification failed for %s\n' "$url" >&2
        return 1
    fi
}

# One copy of the mktemp/download_verified/run/rm ceremony. With no runner
# arguments the artifact is only downloaded and hash-verified; otherwise the
# arguments (a runner plus its flags, e.g. `sh <installer-flags>` or
# `unzip -d "$dir"`) are executed with the verified file appended as the
# final argument, and the temporary file is removed afterwards.
run_pinned_installer() {
    local url="$1" sha256="$2" file run_status=0
    shift 2
    file="$(mktemp)"
    # `|| run_status=1` keeps the failure explicit even inside an `if`
    # condition, where `set -e` is suspended and `rm` below would mask it.
    download_verified "$url" "$sha256" "$file" || run_status=1
    if [ "$run_status" = 0 ] && [ "$#" -gt 0 ]; then
        "$@" "$file" || run_status=1
    fi
    rm -f "$file"
    return "$run_status"
}

atomic_copy() {
    local source_file="$1" destination="$2" mode="${3:-600}"
    local temporary

    mkdir -p "$(dirname "$destination")"
    temporary="$(mktemp "$(dirname "$destination")/.deploy.XXXXXX")"
    cp "$source_file" "$temporary"
    chmod "$mode" "$temporary"
    mv "$temporary" "$destination"
}
