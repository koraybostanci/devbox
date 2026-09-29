#!/bin/bash

stage() {
    printf '\n--- %s\n' "$1"
}

download_verified() {
    local url="$1" sha256="$2" destination="$3"

    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        --retry 3 --retry-connrefused --retry-all-errors "$url" -o "$destination"
    if ! printf '%s  %s\n' "$sha256" "$destination" | sha256sum -c - >/dev/null; then
        printf 'ERROR: checksum verification failed for %s\n' "$url" >&2
        return 1
    fi
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
